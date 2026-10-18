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
   generic (EXPERIMENTAL_CHECKPOINT : boolean := false);
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
      lcd_phase_line    : out unsigned(8 downto 0) := (others => '0');
      vblank_trigger    : out std_logic := '0';
      refpoint_update   : out std_logic := '0';

      vcount_out        : out unsigned(8 downto 0);  -- live line, for compose/debug
      dbg_vbl_ena9      : out std_logic := '0';      -- diagnostic-only persistent ARM9 DISPSTAT bit 3
      checkpoint_stop  : in std_logic := '0';
      checkpoint_stopped : out std_logic := '0';
      checkpoint_address : in unsigned(2 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
   );
end entity;

architecture arch of nds_gpu_timing is
   signal stop_timing : std_logic;
   signal stop_seen : std_logic := '0';

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
   signal restore_active, restore_write_valid : std_logic;
   signal restore_count : unsigned(2 downto 0) := (others => '0');
   signal restore_error : std_logic := '0';
   -- Quartus 17 cannot read integer OUT ports in the checkpoint mux, even
   -- with VHDL-2008 enabled. Keep the existing registers behind wire aliases.
   signal linecounter_state, linecounter_obj_state : integer range 0 to 191 := 0;

   function valid_word(a : unsigned(2 downto 0); d : std_logic_vector(31 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 0 => return unsigned(d(11 downto 0)) < LINE_CYCLES and unsigned(d(20 downto 12)) < 263;
         when 1 => return unsigned(d(31 downto 21)) = 0 and unsigned(d(20 downto 12)) < 263;
         when 2 => return unsigned(d(31 downto 16)) = 0 and unsigned(d(7 downto 0)) < 192 and unsigned(d(15 downto 8)) < 192;
         when 3 | 4 => return (d and x"FFFF0047") = x"00000000";
         when others => return false;
      end case;
   end function;

begin

   linecounter <= linecounter_state;
   linecounter_obj <= linecounter_obj_state;

   stop_timing <= checkpoint_stop when EXPERIMENTAL_CHECKPOINT else '0';
   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   restore_write_valid <= '1' when restore_active = '1' and stop_timing = '1' and
      gb_bus9.ena = '0' and gb_bus7.ena = '0' and restore_error = '0' and checkpoint_write = '1' and
      restore_count < 5 and checkpoint_address = restore_count and valid_word(checkpoint_address,checkpoint_write_data) else '0';
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and stop_timing = '1' and
      gb_bus9.ena = '0' and gb_bus7.ena = '0' and restore_error = '0' and restore_count = 5 and checkpoint_write = '0' else '0';
   process(clk)
   begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then
            restore_count <= (others => '0'); restore_error <= '0';
         elsif reset = '0' or stop_timing = '0' or gb_bus9.ena = '1' or gb_bus7.ena = '1' then restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then restore_count <= restore_count + 1;
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;
   process(all)
      variable c : natural range 0 to 1;
   begin
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and checkpoint_address < 5 and
         ((checkpoint_stopped = '1' and checkpoint_restore = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         case to_integer(checkpoint_address) is
            when 0 => checkpoint_data <= hblank_flag & vblank_flag & std_logic_vector(vcnt) &
               std_logic_vector(to_unsigned(line,9)) & std_logic_vector(to_unsigned(cycles,12));
            when 1 => checkpoint_data(20 downto 0) <= std_logic_vector(lcd_phase_line) & vmatch_flag(1) & vmatch_flag(0) &
               std_logic_vector(vcnt_wr_val) & vcnt_wr_pend;
            when 2 => checkpoint_data(15 downto 0) <= std_logic_vector(to_unsigned(linecounter_obj_state,8)) & std_logic_vector(to_unsigned(linecounter_state,8));
            when 3 | 4 =>
               c := to_integer(checkpoint_address) - 3;
               checkpoint_data(15 downto 7) <= R_vmatch_low(c) & R_vmatch_msb(c);
               checkpoint_data(5 downto 3) <= R_vcnt_irq_ena(c) & R_hbl_irq_ena(c) & R_vbl_irq_ena(c);
            when others => null;
         end case;
      end if;
   end process;
   process(clk) begin
      if rising_edge(clk) then
         if reset = '1' then stop_seen <= '0';
         else stop_seen <= stop_timing; end if;
      end if;
   end process;
   -- Pulses from the preceding enabled edge are delivered once before this
   -- acknowledgement. Register access remains live until the CPU buses drain.
   checkpoint_stopped <= '1' when EXPERIMENTAL_CHECKPOINT and
      reset = '0' and stop_timing = '1' and stop_seen = '1' and
      gb_bus9.ena = '0' and gb_bus7.ena = '0' and gb_bus9.rst = '0' and gb_bus7.rst = '0' and
      irq9_vblank = '0' and irq9_hblank = '0' and irq9_vcount = '0' and
      irq7_vblank = '0' and irq7_hblank = '0' and irq7_vcount = '0' and
      drawline = '0' and drawObj = '0' and line_trigger = '0' and
      hblank_trigger = '0' and lcd_phase = '0' and vblank_trigger = '0' and
      refpoint_update = '0' else '0';

   -- Reuse the existing DISPSTAT register storage, with no shadow bank.
   -- Suppress its bus reset throughout restore and inject only lower-half
   -- writes; never generate a VCOUNT write as a side effect of loading flags.
   process(all)
   begin
      busses(0) <= gb_bus9; busses(1) <= gb_bus7;
      if restore_active = '1' then
         for c in 0 to 1 loop
            busses(c).rst <= '0'; busses(c).ena <= '0'; busses(c).rnw <= '1';
            if restore_write_valid = '1' and checkpoint_address = 3+c then
               busses(c).Adr <= x"0000004"; busses(c).Din <= checkpoint_write_data;
               busses(c).rnw <= '0'; busses(c).ena <= '1'; busses(c).bEna <= "0011";
            end if;
         end loop;
      end if;
   end process;

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

         if restore_active = '1' then
            if restore_write_valid = '1' then
               case to_integer(checkpoint_address) is
                  when 0 =>
                     cycles <= to_integer(unsigned(checkpoint_write_data(11 downto 0)));
                     line <= to_integer(unsigned(checkpoint_write_data(20 downto 12)));
                     vcnt <= unsigned(checkpoint_write_data(29 downto 21));
                     vblank_flag <= checkpoint_write_data(30); hblank_flag <= checkpoint_write_data(31);
                  when 1 =>
                     vcnt_wr_pend <= checkpoint_write_data(0); vcnt_wr_val <= unsigned(checkpoint_write_data(9 downto 1));
                     vmatch_flag(0) <= checkpoint_write_data(10); vmatch_flag(1) <= checkpoint_write_data(11);
                     lcd_phase_line <= unsigned(checkpoint_write_data(20 downto 12));
                  when 2 =>
                     linecounter_state <= to_integer(unsigned(checkpoint_write_data(7 downto 0)));
                     linecounter_obj_state <= to_integer(unsigned(checkpoint_write_data(15 downto 8)));
                  when others => null;
               end case;
            end if;
         elsif (reset = '1') then

            cycles       <= 0;
            line         <= 0;
            lcd_phase_line <= (others => '0');
            vcnt         <= (others => '0');
            vblank_flag  <= '0';
            hblank_flag  <= '0';
            vmatch_flag  <= "00";
            vcnt_wr_pend <= '0';

         elsif (ce = '1' and stop_timing = '0') then

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
                  -- Pair the exported phase with the physical raster line.
                  -- VCOUNT is software-writable and therefore cannot identify
                  -- transport lifecycle markers reliably.
                  lcd_phase_line <= to_unsigned(line, lcd_phase_line'length);
                  if (line < 192) then
                     drawline    <= '1';
                     linecounter_state <= line;
                  end if;
                  if (line < 191) then
                     drawObj         <= '1';
                     linecounter_obj_state <= line + 1;
                  elsif (line = 262) then
                     drawObj         <= '1';
                     linecounter_obj_state <= 0;
                  end if;
               end if;

            end if;

         end if;

      end if;
   end process;

end architecture;
