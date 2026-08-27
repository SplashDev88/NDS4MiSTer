-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS LCD timing (the gba_gpu_timing role): free-running dot cadence,
-- DISPSTAT/VCOUNT (one register set per CPU), IRQ pulses, and the
-- nds_gpu2d line-control cadence. Constants and event order follow
-- melonDS GPU.cpp / GBATEK:
--
--  * 6 clk per dot at 33.514 MHz; line = 355 dots = 2130 clk; frame =
--    263 lines (192 visible + 71 vblank). ce paces the dot clock so the
--    module can sit in a faster clock domain later ('1' at 33.5 MHz).
--  * scanline start (cycle 0): VCount updates (VCOUNT writes land here,
--    delayed like melonDS SetVCount; either CPU can write, last wins),
--    hblank flag clears, V-count match evaluates per CPU (+IRQ). The
--    vblank flag sets at VCount 192 (+IRQ +vblank_trigger: gpu2d
--    reloads affine refs and refills the ext-pal shadows) and clears at
--    VCount 262. refpoint_update steps the affine refs on lines 1..191,
--    after each drawn line (the drawers keep a per-line latched copy,
--    so an overrunning line is unaffected).
--  * render point (cycle 1584 = 48 lead + 256 dots, where hblank
--    begins): hblank flag + IRQ on every line; on visible lines the
--    gpu2d cadence fires hblank_trigger (merge config latch), then
--    line_trigger (affine per-line latch), then drawline. drawObj
--    pre-renders OBJ one line ahead into the parity buffer (line 262
--    pre-renders OBJ line 0 for the next frame, melonDS-style).
--
-- The cadence is keyed on the internal line counter; a written VCount
-- shifts the flag/match values (and can re-fire the vblank events, as
-- in melonDS) but does not move the render cadence or frame length.
-- Timing free-runs: a drawline landing while nds_gpu2d is still busy is
-- dropped there (bounded artifact - the affine/extended fetch budget is
-- the open line-server item, measured by the timed frame TB).
-- No savestates yet - that plumbing lands with the hardware milestone.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;
use work.pReg_nds_display.all;

entity nds_gpu_timing is
   port
   (
      clk               : in  std_logic;
      ce                : in  std_logic;   -- dot pace ('1' when clk is the 33.5 MHz domain)
      reset             : in  std_logic;

      -- register slices: ARM9 and ARM7 each own a DISPSTAT/VCOUNT set
      gb_bus9           : in  proc_bus_gb_type;
      wired_out9        : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done9       : out std_logic;
      gb_bus7           : in  proc_bus_gb_type;
      wired_out7        : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done7       : out std_logic;

      irq9_vblank       : out std_logic := '0';
      irq9_hblank       : out std_logic := '0';
      irq9_vcount       : out std_logic := '0';
      irq7_vblank       : out std_logic := '0';
      irq7_hblank       : out std_logic := '0';
      irq7_vcount       : out std_logic := '0';

      -- gpu2d line control (engine B shares the same cadence later)
      linecounter       : out integer range 0 to 191 := 0;
      drawline          : out std_logic := '0';
      linecounter_obj   : out integer range 0 to 191 := 0;
      drawObj           : out std_logic := '0';
      line_trigger      : out std_logic := '0';
      hblank_trigger    : out std_logic := '0';
      lcd_phase         : out std_logic := '0';
      vblank_trigger    : out std_logic := '0';
      refpoint_update   : out std_logic := '0';

      vcount_out        : out unsigned(8 downto 0);  -- live line, for compose/debug
      dbg_vbl_ena9      : out std_logic := '0'       -- diagnostic-only persistent ARM9 DISPSTAT bit 3
   );
end entity;

architecture arch of nds_gpu_timing is

   constant LINE_CYCLES  : integer := 355 * 6;
   constant RENDER_START : integer := 48 + 256 * 6;   -- hblank begins here

   signal cycles : integer range 0 to LINE_CYCLES - 1 := 0;
   signal line   : integer range 0 to 262 := 0;
   signal vcnt   : unsigned(8 downto 0) := (others => '0');

   signal vblank_flag : std_logic := '0';
   signal hblank_flag : std_logic := '0';

   -- delayed VCOUNT write (melonDS SetVCount: applied at next scanline start)
   signal vcnt_wr_pend : std_logic := '0';
   signal vcnt_wr_val  : unsigned(8 downto 0) := (others => '0');

   -- per-CPU register sets: 0 = ARM9, 1 = ARM7
   constant NREG : integer := 9;
   type t_busarr   is array (0 to 1) of proc_bus_gb_type;
   type t_worarr   is array (0 to 1, 0 to NREG - 1) of std_logic_vector(31 downto 0);
   type t_wdonearr is array (0 to 1) of unsigned(0 to NREG - 1);
   type t_slv1     is array (0 to 1) of std_logic_vector(0 downto 0);
   type t_slv8     is array (0 to 1) of std_logic_vector(7 downto 0);
   type t_slv16    is array (0 to 1) of std_logic_vector(31 downto 16);
   signal busses         : t_busarr;
   signal reg_wired_or   : t_worarr   := (others => (others => (others => '0')));
   signal reg_wired_done : t_wdonearr := (others => (others => '0'));

   signal R_vbl_irq_ena  : t_slv1;
   signal R_hbl_irq_ena  : t_slv1;
   signal R_vcnt_irq_ena : t_slv1;
   signal R_vmatch_msb   : t_slv1;
   signal R_vmatch_low   : t_slv8;
   signal vmatch_flag    : std_logic_vector(0 to 1) := "00";

   -- length-matched Din feeds for the flag registers (the eProcReg Din
   -- formal is ranged (upper downto lower); lengths match, indices don't
   -- have to)
   signal vblf_in        : std_logic_vector(0 downto 0);
   signal hblf_in        : std_logic_vector(0 downto 0);
   signal vcf_in         : t_slv1;

   signal vcount_read    : t_slv16;
   signal vcount_wrto    : std_logic_vector(0 to 1);
   signal vcount_wrval   : t_slv16;

   type t_vmatch is array (0 to 1) of unsigned(8 downto 0);
   signal vmatch : t_vmatch;

begin

   busses(0) <= gb_bus9;
   busses(1) <= gb_bus7;

   vblf_in(0) <= vblank_flag;
   hblf_in(0) <= hblank_flag;

   gcpu : for c in 0 to 1 generate
   begin

      vcf_in(c)(0) <= vmatch_flag(c);

      iVBLFLAG  : entity work.eProcReg_gba generic map (DISPSTAT_V_Blank_flag)         port map (clk, busses(c), reg_wired_or(c, 0), reg_wired_done(c)(0), vblf_in);
      iHBLFLAG  : entity work.eProcReg_gba generic map (DISPSTAT_H_Blank_flag)         port map (clk, busses(c), reg_wired_or(c, 1), reg_wired_done(c)(1), hblf_in);
      iVCFLAG   : entity work.eProcReg_gba generic map (DISPSTAT_V_Counter_flag)       port map (clk, busses(c), reg_wired_or(c, 2), reg_wired_done(c)(2), vcf_in(c));
      iVBLENA   : entity work.eProcReg_gba generic map (DISPSTAT_V_Blank_IRQ_Enable)   port map (clk, busses(c), reg_wired_or(c, 3), reg_wired_done(c)(3), R_vbl_irq_ena(c),  R_vbl_irq_ena(c));
      iHBLENA   : entity work.eProcReg_gba generic map (DISPSTAT_H_Blank_IRQ_Enable)   port map (clk, busses(c), reg_wired_or(c, 4), reg_wired_done(c)(4), R_hbl_irq_ena(c),  R_hbl_irq_ena(c));
      iVCENA    : entity work.eProcReg_gba generic map (DISPSTAT_V_Counter_IRQ_Enable) port map (clk, busses(c), reg_wired_or(c, 5), reg_wired_done(c)(5), R_vcnt_irq_ena(c), R_vcnt_irq_ena(c));
      iVMATCHM  : entity work.eProcReg_gba generic map (DISPSTAT_V_Count_Setting_MSB)  port map (clk, busses(c), reg_wired_or(c, 6), reg_wired_done(c)(6), R_vmatch_msb(c),   R_vmatch_msb(c));
      iVMATCHL  : entity work.eProcReg_gba generic map (DISPSTAT_V_Count_Setting)      port map (clk, busses(c), reg_wired_or(c, 7), reg_wired_done(c)(7), R_vmatch_low(c),   R_vmatch_low(c));
      iVCOUNT   : entity work.eProcReg_gba generic map (VCOUNT)                        port map (clk, busses(c), reg_wired_or(c, 8), reg_wired_done(c)(8), vcount_read(c), open, open, vcount_wrval(c), vcount_wrto(c));

      vcount_read(c)(24 downto 16) <= std_logic_vector(vcnt);
      vcount_read(c)(31 downto 25) <= (others => '0');

      vmatch(c) <= unsigned(std_logic_vector'(R_vmatch_msb(c) & R_vmatch_low(c)));

   end generate;

   process (reg_wired_or)
      variable wired_or9, wired_or7 : std_logic_vector(31 downto 0);
   begin
      wired_or9 := reg_wired_or(0, 0);
      wired_or7 := reg_wired_or(1, 0);
      for i in 1 to NREG - 1 loop
         wired_or9 := wired_or9 or reg_wired_or(0, i);
         wired_or7 := wired_or7 or reg_wired_or(1, i);
      end loop;
      wired_out9 <= wired_or9;
      wired_out7 <= wired_or7;
   end process;
   wired_done9 <= '0' when reg_wired_done(0) = 0 else '1';
   wired_done7 <= '0' when reg_wired_done(1) = 0 else '1';

   vcount_out <= vcnt;
   dbg_vbl_ena9 <= R_vbl_irq_ena(0)(0);

   process (clk)
      variable newline : integer range 0 to 262;
      variable vnew    : unsigned(8 downto 0);
   begin
      if rising_edge(clk) then

         irq9_vblank <= '0';
         irq9_hblank <= '0';
         irq9_vcount <= '0';
         irq7_vblank <= '0';
         irq7_hblank <= '0';
         irq7_vcount <= '0';

         drawline        <= '0';
         drawObj         <= '0';
         line_trigger    <= '0';
         hblank_trigger  <= '0';
         lcd_phase       <= '0';
         vblank_trigger  <= '0';
         refpoint_update <= '0';

         -- a VCOUNT write from either CPU is held until the next scanline
         if (vcount_wrto(0) = '1') then
            vcnt_wr_pend <= '1';
            vcnt_wr_val  <= unsigned(vcount_wrval(0)(24 downto 16));
         end if;
         if (vcount_wrto(1) = '1') then
            vcnt_wr_pend <= '1';
            vcnt_wr_val  <= unsigned(vcount_wrval(1)(24 downto 16));
         end if;

         if (reset = '1') then

            cycles       <= 0;
            line         <= 0;
            vcnt         <= (others => '0');
            vblank_flag  <= '0';
            hblank_flag  <= '0';
            vmatch_flag  <= "00";
            vcnt_wr_pend <= '0';

         elsif (ce = '1') then

            if (cycles = LINE_CYCLES - 1) then

               -- scanline start
               cycles <= 0;
               if (line = 262) then
                  newline := 0;
               else
                  newline := line + 1;
               end if;
               line <= newline;

               if (newline = 0) then
                  vnew := (others => '0');
               elsif (vcnt_wr_pend = '1') then
                  vnew := vcnt_wr_val;
               else
                  vnew := vcnt + 1;
               end if;
               vcnt_wr_pend <= '0';
               vcnt         <= vnew;

               hblank_flag <= '0';

               for c in 0 to 1 loop
                  if (vnew = vmatch(c)) then
                     vmatch_flag(c) <= '1';
                     if (R_vcnt_irq_ena(c) = "1") then
                        if (c = 0) then irq9_vcount <= '1'; else irq7_vcount <= '1'; end if;
                     end if;
                  else
                     vmatch_flag(c) <= '0';
                  end if;
               end loop;

               if (vnew = 192) then
                  vblank_flag    <= '1';
                  vblank_trigger <= '1';
                  if (R_vbl_irq_ena(0) = "1") then irq9_vblank <= '1'; end if;
                  if (R_vbl_irq_ena(1) = "1") then irq7_vblank <= '1'; end if;
               elsif (vnew = 262) then
                  vblank_flag <= '0';
               end if;

               if (newline >= 1 and newline <= 191) then
                  refpoint_update <= '1';
               end if;

            else
               cycles <= cycles + 1;

               if (cycles = RENDER_START - 1) then
                  -- hblank (and the render point: the visible-line cadence
                  -- fires here, hblank_trigger -> line_trigger -> drawline)
                  hblank_flag <= '1';
                  if (R_hbl_irq_ena(0) = "1") then irq9_hblank <= '1'; end if;
                  if (R_hbl_irq_ena(1) = "1") then irq7_hblank <= '1'; end if;
                  if (line < 192) then
                     hblank_trigger <= '1';
                  end if;
               elsif (cycles = RENDER_START) then
                  if (line < 192) then
                     line_trigger <= '1';
                  end if;
               elsif (cycles = RENDER_START + 1) then
                  -- Export every LCD render phase, including VBlank lines.
                  -- ARM-side full-video reconstruction needs the exact
                  -- 192/215/262 melonDS lifecycle points; the existing
                  -- visible-only GPU2D cadence remains unchanged.
                  lcd_phase <= '1';
                  if (line < 192) then
                     drawline    <= '1';
                     linecounter <= line;
                  end if;
                  if (line < 191) then
                     drawObj         <= '1';
                     linecounter_obj <= line + 1;
                  elsif (line = 262) then
                     drawObj         <= '1';
                     linecounter_obj <= 0;
                  end if;
               end if;

            end if;

         end if;

      end if;
   end process;

end architecture;
