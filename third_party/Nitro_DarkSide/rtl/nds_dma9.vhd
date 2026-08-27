-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS ARM9 DMA (M6): 4 channels, registers 0x040000B0-0x040000EF incl. the
-- FILL words. Semantics per DualSOUP dma.c (Jaklyy's hardware research) and
-- GBATEK:
--
--   * CNT: [20:0] word count (0 -> 0x200000), [22:21] dst ctrl (0 inc,
--     1 dec, 2 fixed, 3 inc-reload), [24:23] src ctrl (3 behaves as inc +
--     reload, DualSOUP), [25] repeat, [26] 32-bit, [29:27] start timing,
--     [30] IRQ, [31] enable. SAD/DAD/CNT all read back (NDS, unlike GBA).
--   * enable rising edge latches src/dst; the word count is latched lazily
--     when the remaining count is 0 (so repeat reloads it per trigger, and
--     ctrl-3 re-latches the address then too) - DualSOUP DMA_Run.
--   * start timings implemented: 0 immediate, 1 vblank, 2 hblank (visible
--     lines only - the gpu2d cadence pulses), 3 display start (VCOUNT 2..193,
--     stopped at 194), and 5 card when the caller provides a card trigger.
--     Display FIFO mode 4 and GX FIFO mode 7 have no slow path and fail
--     closed. Mode 6 also fails closed. A caller without card ownership must
--     set card_supported low; mode 5 then fails closed instead of waiting.
--   * repeat re-arms every trigger for non-immediate modes; immediate
--     transfers clear enable regardless. IRQ per completed transfer.
--   * transfers go through the ARM9 membus with the CPU paused (dma_on +
--     CPU_bus_idle grant) and the TCM windows bypassed (DMA cannot see
--     ITCM/DTCM). Addresses are masked to 0x0FFFFFFF and hold the size
--     alignment; 16-bit reads take the rotated lane, writes replicate.
--
-- Timing is functional-only for now: one read + one write handshake per
-- unit, no cycle accuracy. The M9 pacing target is the DualSOUP dma.txt
-- measurement: NR+NW first pair, then SR/SW pairs, a 1-cycle stall after
-- a fast first read, and main-RAM read prefetch making later SRs
-- single-cycle. The FSM shape below (first-pair / steady-pair) is chosen
-- so those timings can be dialed in without restructuring.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_dma9 is
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      gb_bus       : in  proc_bus_gb_type;
      wired_out    : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done   : out std_logic;

      -- trigger pulses (gpu2d cadence: vblank start / visible-line hblank;
      -- card: one pulse per ready data word from nds_card)
      trig_vblank  : in  std_logic;
      trig_hblank  : in  std_logic;
      trig_display : in  std_logic := '0';
      stop_display : in  std_logic := '0';
      trig_card    : in  std_logic;
      card_supported : in std_logic := '1';

      -- membus grant: dma_on pauses the CPU, the bus is ours once idle
      cpu_bus_idle : in  std_logic;
      dma_on       : out std_logic := '0';
      dma_bus_on   : out std_logic := '0';

      -- ARM9 membus access port (muxed onto the CPU port in nds_top)
      mb_ena       : out std_logic := '0';
      mb_rnw       : out std_logic := '1';
      mb_adr       : out std_logic_vector(31 downto 0) := (others => '0');
      mb_acc       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      mb_lowbits   : out std_logic_vector(1 downto 0) := "00";
      mb_dout      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din       : in  std_logic_vector(31 downto 0);
      mb_done      : in  std_logic;

      irq_dma      : out std_logic_vector(3 downto 0) := (others => '0');

      -- Sticky fail-closed report. Display FIFO mode 4 needs a dedicated
      -- request lane and is outside this first slow-path integration.
      unsupported_mode : out std_logic := '0'
   );
end entity;

architecture arch of nds_dma9 is

   constant ADR_BASE : unsigned(27 downto 0) := x"00000B0";

   type t_chan is record
      sad      : std_logic_vector(27 downto 0);
      dad      : std_logic_vector(27 downto 0);
      count    : std_logic_vector(20 downto 0);
      dstctl   : std_logic_vector(1 downto 0);
      srcctl   : std_logic_vector(1 downto 0);
      repeat   : std_logic;
      word32   : std_logic;
      timing   : std_logic_vector(2 downto 0);
      irqena   : std_logic;
      enable   : std_logic;
      -- latched transfer state
      cur_src  : unsigned(27 downto 0);
      cur_dst  : unsigned(27 downto 0);
      remain   : unsigned(21 downto 0);   -- 0x200000 max
      pend     : std_logic;
   end record;
   constant CHAN_INIT : t_chan := ((others => '0'), (others => '0'), (others => '0'),
                                   "00", "00", '0', '0', "000", '0', '0',
                                   (others => '0'), (others => '0'), (others => '0'), '0');
   type t_chans is array (0 to 3) of t_chan;
   signal ch : t_chans := (others => CHAN_INIT);

   type t_fill is array (0 to 3) of std_logic_vector(31 downto 0);
   signal fill : t_fill := (others => (others => '0'));

   type t_state is (IDLE, GRANT, LATCH, RD, RD_WAIT, WR, WR_WAIT, NEXTUNIT, COMPLETE);
   signal state  : t_state := IDLE;
   signal active : integer range 0 to 3 := 0;

   signal rdval  : std_logic_vector(31 downto 0) := (others => '0');

   -- register write/read decode
   signal regsel_ch  : integer range 0 to 3;
   signal regsel_reg : integer range 0 to 2;
   signal reg_hit    : std_logic;
   signal fill_hit   : std_logic;

   function inc_of(ctl : std_logic_vector(1 downto 0); w32 : std_logic) return integer is
      variable step : integer;
   begin
      if (w32 = '1') then step := 4; else step := 2; end if;
      case ctl is
         when "01"   => return -step;
         when "10"   => return 0;
         when others => return step;      -- 0 and 3: increment
      end case;
   end function;

begin

   -- ================= register decode =================
   process (all)
      variable off : integer;
   begin
      reg_hit    <= '0';
      fill_hit   <= '0';
      regsel_ch  <= 0;
      regsel_reg <= 0;
      if (unsigned(gb_bus.Adr) >= ADR_BASE and unsigned(gb_bus.Adr) < ADR_BASE + 16#40#) then
         off := to_integer(unsigned(gb_bus.Adr) - ADR_BASE) / 4;
         if (off < 12) then
            reg_hit    <= '1';
            -- Four channels, three words each. An arithmetic /3 and mod 3
            -- here makes Quartus build two full combinational dividers for a
            -- twelve-value MMIO decode; spell out the exact fixed mapping.
            case off is
               when 0  => regsel_ch <= 0; regsel_reg <= 0;
               when 1  => regsel_ch <= 0; regsel_reg <= 1;
               when 2  => regsel_ch <= 0; regsel_reg <= 2;
               when 3  => regsel_ch <= 1; regsel_reg <= 0;
               when 4  => regsel_ch <= 1; regsel_reg <= 1;
               when 5  => regsel_ch <= 1; regsel_reg <= 2;
               when 6  => regsel_ch <= 2; regsel_reg <= 0;
               when 7  => regsel_ch <= 2; regsel_reg <= 1;
               when 8  => regsel_ch <= 2; regsel_reg <= 2;
               when 9  => regsel_ch <= 3; regsel_reg <= 0;
               when 10 => regsel_ch <= 3; regsel_reg <= 1;
               when 11 => regsel_ch <= 3; regsel_reg <= 2;
               when others => null;
            end case;
         else
            fill_hit  <= '1';
            regsel_ch <= off mod 4;
         end if;
      end if;
   end process;

   wired_done <= reg_hit or fill_hit;
   wired_out  <= fill(regsel_ch) when fill_hit = '1' else
                 x"0" & ch(regsel_ch).sad when (reg_hit = '1' and regsel_reg = 0) else
                 x"0" & ch(regsel_ch).dad when (reg_hit = '1' and regsel_reg = 1) else
                 ch(regsel_ch).enable & ch(regsel_ch).irqena & ch(regsel_ch).timing &
                 ch(regsel_ch).word32 & ch(regsel_ch).repeat & ch(regsel_ch).srcctl &
                 ch(regsel_ch).dstctl & ch(regsel_ch).count
                 when reg_hit = '1' else (others => '0');

   -- ================= main FSM + register writes =================
   process (clk)
      variable v_ena   : std_logic;
      variable v_pick  : integer range 0 to 3;
      variable v_got   : std_logic;
      variable v_inc   : integer;
      variable lane16  : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk) then

         irq_dma <= (others => '0');
         mb_ena  <= '0';

         if (reset = '1') then
            ch     <= (others => CHAN_INIT);
            state  <= IDLE;
            dma_on <= '0';
            dma_bus_on <= '0';
            unsupported_mode <= '0';
         else

            -- -------- CPU register writes --------
            if (gb_bus.ena = '1' and gb_bus.rnw = '0') then
               if (fill_hit = '1') then
                  for i in 0 to 3 loop
                     if (gb_bus.bEna(i) = '1') then
                        fill(regsel_ch)(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               elsif (reg_hit = '1') then
                  case regsel_reg is
                     when 0 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1' and i < 4) then
                              if (i = 3) then
                                 ch(regsel_ch).sad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).sad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when 1 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1') then
                              if (i = 3) then
                                 ch(regsel_ch).dad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).dad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when others =>
                        v_ena := ch(regsel_ch).enable;
                        if (gb_bus.bEna(0) = '1') then ch(regsel_ch).count(7 downto 0)   <= gb_bus.Din(7 downto 0);   end if;
                        if (gb_bus.bEna(1) = '1') then ch(regsel_ch).count(15 downto 8)  <= gb_bus.Din(15 downto 8);  end if;
                        if (gb_bus.bEna(2) = '1') then
                           ch(regsel_ch).count(20 downto 16) <= gb_bus.Din(20 downto 16);
                           ch(regsel_ch).dstctl <= gb_bus.Din(22 downto 21);
                           ch(regsel_ch).srcctl(0) <= gb_bus.Din(23);
                        end if;
                        if (gb_bus.bEna(3) = '1') then
                           ch(regsel_ch).srcctl(1) <= gb_bus.Din(24);
                           ch(regsel_ch).repeat <= gb_bus.Din(25);
                           ch(regsel_ch).word32 <= gb_bus.Din(26);
                           ch(regsel_ch).timing <= gb_bus.Din(29 downto 27);
                           ch(regsel_ch).irqena <= gb_bus.Din(30);
                           if (gb_bus.Din(31) = '1' and
                               (gb_bus.Din(29 downto 27) = "100" or
                                gb_bus.Din(29 downto 27) = "110" or
                                gb_bus.Din(29 downto 27) = "111" or
                                (gb_bus.Din(29 downto 27) = "101" and
                                 card_supported = '0'))) then
                              -- No ordinary slow-memory request can model
                              -- these missing trigger owners. Reject enable
                              -- and raise the sticky product fault.
                              ch(regsel_ch).enable <= '0';
                              ch(regsel_ch).pend <= '0';
                              unsupported_mode <= '1';
                           else
                              ch(regsel_ch).enable <= gb_bus.Din(31);
                              -- enable rising edge: latch addresses, arm
                              if (gb_bus.Din(31) = '1' and v_ena = '0') then
                                 ch(regsel_ch).cur_src <= unsigned(ch(regsel_ch).sad);
                                 ch(regsel_ch).cur_dst <= unsigned(ch(regsel_ch).dad);
                                 ch(regsel_ch).remain  <= (others => '0');
                                 if (gb_bus.Din(29 downto 27) = "000") then
                                    ch(regsel_ch).pend <= '1';
                                 end if;
                              end if;
                           end if;
                        end if;
                  end case;
               end if;
            end if;

            -- -------- triggers --------
            for i in 0 to 3 loop
               if (ch(i).enable = '1') then
                  if (trig_vblank = '1' and ch(i).timing = "001") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_hblank = '1' and ch(i).timing = "010") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_display = '1' and ch(i).timing = "011") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_card = '1' and ch(i).timing = "101") then
                     ch(i).pend <= '1';
                  end if;
               end if;
               if (stop_display = '1' and ch(i).timing = "011") then
                  ch(i).enable <= '0';
                  ch(i).pend <= '0';
               end if;
            end loop;

            -- -------- transfer FSM --------
            case state is

               when IDLE =>
                  dma_bus_on <= '0';
                  v_got  := '0';
                  v_pick := 0;
                  for i in 3 downto 0 loop
                     if (ch(i).pend = '1' and ch(i).enable = '1') then
                        v_pick := i;
                        v_got  := '1';
                     end if;
                  end loop;
                  if (v_got = '1') then
                     active <= v_pick;
                     dma_on <= '1';
                     state  <= GRANT;
                  else
                     dma_on <= '0';
                  end if;

               when GRANT =>
                  if (cpu_bus_idle = '1') then
                     dma_bus_on <= '1';
                     state      <= LATCH;
                  end if;

               when LATCH =>
                  ch(active).pend <= '0';
                  -- lazy count latch (DualSOUP): remaining 0 means reload;
                  -- ctrl 3 re-latches its address too
                  if (ch(active).remain = 0) then
                     if (unsigned(ch(active).count) = 0) then
                        ch(active).remain <= to_unsigned(16#200000#, 22);
                     else
                        ch(active).remain <= unsigned('0' & ch(active).count);
                     end if;
                     if (ch(active).srcctl = "11") then
                        ch(active).cur_src <= unsigned(ch(active).sad);
                     end if;
                     if (ch(active).dstctl = "11") then
                        ch(active).cur_dst <= unsigned(ch(active).dad);
                     end if;
                  end if;
                  state <= RD;

               when RD =>
                  mb_ena     <= '1';
                  mb_rnw     <= '1';
                  if (ch(active).word32 = '1') then
                     mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 2)) & "00";
                     mb_acc     <= ACCESS_32BIT;
                     mb_lowbits <= "00";
                  else
                     mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 1)) & '0';
                     mb_acc     <= ACCESS_16BIT;
                     mb_lowbits <= std_logic_vector(ch(active).cur_src(1 downto 1)) & '0';
                  end if;
                  state <= RD_WAIT;

               when RD_WAIT =>
                  if (mb_done = '1') then
                     rdval <= mb_din;   -- membus rotates: low half = the halfword
                     state <= WR;
                  end if;

               when WR =>
                  mb_ena <= '1';
                  mb_rnw <= '0';
                  if (ch(active).word32 = '1') then
                     mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 2)) & "00";
                     mb_acc  <= ACCESS_32BIT;
                     mb_dout <= rdval;
                  else
                     mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 1)) & '0';
                     mb_acc  <= ACCESS_16BIT;
                     lane16  := rdval(15 downto 0);
                     mb_dout <= lane16 & lane16;
                  end if;
                  mb_lowbits <= "00";
                  state <= WR_WAIT;

               when WR_WAIT =>
                  if (mb_done = '1') then
                     state <= NEXTUNIT;
                  end if;

               when NEXTUNIT =>
                  v_inc := inc_of(ch(active).srcctl, ch(active).word32);
                  ch(active).cur_src <= ch(active).cur_src + v_inc;  -- wraps mod 2^28 (address mask)
                  v_inc := inc_of(ch(active).dstctl, ch(active).word32);
                  ch(active).cur_dst <= ch(active).cur_dst + v_inc;
                  ch(active).remain  <= ch(active).remain - 1;
                  if (ch(active).remain = 1 or ch(active).enable = '0') then
                     state <= COMPLETE;
                  else
                     state <= RD;
                  end if;

               when COMPLETE =>
                  -- repeat keeps the channel armed for the next trigger;
                  -- immediate transfers always disable (DualSOUP)
                  if (ch(active).repeat = '0' or ch(active).timing = "000") then
                     ch(active).enable <= '0';
                  end if;
                  if (ch(active).irqena = '1') then
                     irq_dma(active) <= '1';
                  end if;
                  dma_bus_on <= '0';
                  state      <= IDLE;

            end case;

         end if;
      end if;
   end process;

end architecture;
