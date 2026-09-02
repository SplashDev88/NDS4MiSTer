-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS ARM7 DMA: 4 channels, registers 0x040000B0-0x040000DF (no FILL words -
-- those are ARM9-only). Port of nds_dma9 with the ARM7 differences per
-- GBATEK/melonDS:
--
--   * CNT: count in [15:0] - channels 0-2 use 14 bits (0 -> 0x4000),
--     channel 3 uses 16 (0 -> 0x10000); [22:21] dst ctrl, [24:23] src ctrl,
--     [25] repeat, [26] 32-bit, [29:28] start timing (2 bits, GBA layout:
--     0 immediate, 1 vblank, 2 DS card slot, 3 wifi/GBA-slot - stubbed),
--     [30] IRQ, [31] enable. Bit 27 (GBA gamepak DRQ) is dead. Registers
--     read back like the ARM9 side (NDS, unlike GBA).
--   * card trigger: one pulse per ready data word from nds_card when the
--     ARM7 owns the slot (EXMEMCNT[11]=1); games arm count=1 + repeat.
--   * transfers go through membus7 with the CPU paused (same dma_on +
--     CPU_bus_idle grant idiom as the ARM9 side; no TCMs to bypass here).
--
-- Timing is functional-only, same caveat and same FSM shape as nds_dma9 so
-- the DualSOUP pacing can be dialed into both at once (M9).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_dma7 is
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      gb_bus       : in  proc_bus_gb_type;
      wired_out    : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done   : out std_logic;

      trig_vblank  : in  std_logic;
      trig_card    : in  std_logic;
      card_supported : in std_logic := '1';

      cpu_bus_idle : in  std_logic;
      dma_on       : out std_logic := '0';
      dma_bus_on   : out std_logic := '0';

      -- ARM7 membus access port (muxed onto the CPU port in nds_top)
      mb_ena       : out std_logic := '0';
      mb_rnw       : out std_logic := '1';
      mb_adr       : out std_logic_vector(31 downto 0) := (others => '0');
      mb_acc       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      mb_lowbits   : out std_logic_vector(1 downto 0) := "00";
      mb_dout      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din       : in  std_logic_vector(31 downto 0);
      mb_done      : in  std_logic;

      irq_dma      : out std_logic_vector(3 downto 0) := (others => '0');

      -- Sticky fail-closed report. Card and WiFi/GBA-slot timing need owners
      -- that are not present in the first local-LCD product slice.
      unsupported_mode : out std_logic := '0'
   );
end entity;

architecture arch of nds_dma7 is

   constant ADR_BASE : unsigned(27 downto 0) := x"00000B0";

   type t_chan is record
      sad      : std_logic_vector(27 downto 0);
      dad      : std_logic_vector(27 downto 0);
      count    : std_logic_vector(15 downto 0);
      dstctl   : std_logic_vector(1 downto 0);
      srcctl   : std_logic_vector(1 downto 0);
      repeat   : std_logic;
      word32   : std_logic;
      timing   : std_logic_vector(1 downto 0);
      irqena   : std_logic;
      enable   : std_logic;
      cur_src  : unsigned(27 downto 0);
      cur_dst  : unsigned(27 downto 0);
      remain   : unsigned(16 downto 0);   -- 0x10000 max (ch3)
      pend     : std_logic;
   end record;
   constant CHAN_INIT : t_chan := ((others => '0'), (others => '0'), (others => '0'),
                                   "00", "00", '0', '0', "00", '0', '0',
                                   (others => '0'), (others => '0'), (others => '0'), '0');
   type t_chans is array (0 to 3) of t_chan;
   signal ch : t_chans := (others => CHAN_INIT);

   type t_state is (IDLE, GRANT, LATCH, RD, RD_WAIT, WR, WR_WAIT, NEXTUNIT, COMPLETE);
   signal state  : t_state := IDLE;
   signal active : integer range 0 to 3 := 0;

   signal rdval  : std_logic_vector(31 downto 0) := (others => '0');

   signal regsel_ch  : integer range 0 to 3;
   signal regsel_reg : integer range 0 to 2;
   signal reg_hit    : std_logic;

   -- per-channel count width mask: 14 bits for 0-2, 16 for 3
   function count_mask(chn : integer) return std_logic_vector is
   begin
      if (chn = 3) then
         return x"FFFF";
      else
         return x"3FFF";
      end if;
   end function;

   function inc_of(ctl : std_logic_vector(1 downto 0); w32 : std_logic) return integer is
      variable step : integer;
   begin
      if (w32 = '1') then step := 4; else step := 2; end if;
      case ctl is
         when "01"   => return -step;
         when "10"   => return 0;
         when others => return step;
      end case;
   end function;

begin

   -- ================= register decode =================
   process (all)
      variable off : integer;
   begin
      reg_hit    <= '0';
      regsel_ch  <= 0;
      regsel_reg <= 0;
      if (unsigned(gb_bus.Adr) >= ADR_BASE and unsigned(gb_bus.Adr) < ADR_BASE + 16#30#) then
         off := to_integer(unsigned(gb_bus.Adr) - ADR_BASE) / 4;
         reg_hit    <= '1';
         -- Four channels, three words each. Keep this as the literal MMIO
         -- map so synthesis does not implement /3 and mod 3 divider trees.
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
      end if;
   end process;

   wired_done <= reg_hit;
   wired_out  <= x"0" & ch(regsel_ch).sad when (reg_hit = '1' and regsel_reg = 0) else
                 x"0" & ch(regsel_ch).dad when (reg_hit = '1' and regsel_reg = 1) else
                 ch(regsel_ch).enable & ch(regsel_ch).irqena & ch(regsel_ch).timing & '0' &
                 ch(regsel_ch).word32 & ch(regsel_ch).repeat & ch(regsel_ch).srcctl &
                 ch(regsel_ch).dstctl & "00000" & ch(regsel_ch).count
                 when reg_hit = '1' else (others => '0');

   -- ================= main FSM + register writes =================
   process (clk)
      variable v_ena   : std_logic;
      variable v_pick  : integer range 0 to 3;
      variable v_got   : std_logic;
      variable v_inc   : integer;
      variable lane16  : std_logic_vector(15 downto 0);
      variable cmask   : std_logic_vector(15 downto 0);
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
            if (gb_bus.ena = '1' and gb_bus.rnw = '0' and reg_hit = '1') then
               case regsel_reg is
                  when 0 =>
                     for i in 0 to 3 loop
                        if (gb_bus.bEna(i) = '1') then
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
                     cmask := count_mask(regsel_ch);
                     if (gb_bus.bEna(0) = '1') then
                        ch(regsel_ch).count(7 downto 0) <= gb_bus.Din(7 downto 0) and cmask(7 downto 0);
                     end if;
                     if (gb_bus.bEna(1) = '1') then
                        ch(regsel_ch).count(15 downto 8) <= gb_bus.Din(15 downto 8) and cmask(15 downto 8);
                     end if;
                     if (gb_bus.bEna(2) = '1') then
                        ch(regsel_ch).dstctl <= gb_bus.Din(22 downto 21);
                        ch(regsel_ch).srcctl(0) <= gb_bus.Din(23);
                     end if;
                     if (gb_bus.bEna(3) = '1') then
                        ch(regsel_ch).srcctl(1) <= gb_bus.Din(24);
                        ch(regsel_ch).repeat <= gb_bus.Din(25);
                        ch(regsel_ch).word32 <= gb_bus.Din(26);
                        ch(regsel_ch).timing <= gb_bus.Din(29 downto 28);
                        ch(regsel_ch).irqena <= gb_bus.Din(30);
                        if (gb_bus.Din(31) = '1' and
                            (gb_bus.Din(29 downto 28) = "11" or
                             (gb_bus.Din(29 downto 28) = "10" and
                              card_supported = '0'))) then
                           ch(regsel_ch).enable <= '0';
                           ch(regsel_ch).pend <= '0';
                           unsupported_mode <= '1';
                        else
                           ch(regsel_ch).enable <= gb_bus.Din(31);
                           if (gb_bus.Din(31) = '1' and v_ena = '0') then
                              ch(regsel_ch).cur_src <= unsigned(ch(regsel_ch).sad);
                              ch(regsel_ch).cur_dst <= unsigned(ch(regsel_ch).dad);
                              ch(regsel_ch).remain  <= (others => '0');
                              if (gb_bus.Din(29 downto 28) = "00") then
                                 ch(regsel_ch).pend <= '1';
                              end if;
                           end if;
                        end if;
                     end if;
               end case;
            end if;

            -- -------- triggers --------
            for i in 0 to 3 loop
               if (ch(i).enable = '1') then
                  if (trig_vblank = '1' and ch(i).timing = "01") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_card = '1' and ch(i).timing = "10") then
                     ch(i).pend <= '1';
                  end if;
                  -- timing "11" (wifi / GBA slot) never fires
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
                  if (ch(active).remain = 0) then
                     if (unsigned(ch(active).count) = 0) then
                        if (active = 3) then
                           ch(active).remain <= to_unsigned(16#10000#, 17);
                        else
                           ch(active).remain <= to_unsigned(16#4000#, 17);
                        end if;
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
                     rdval <= mb_din;
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
                  ch(active).cur_src <= ch(active).cur_src + v_inc;
                  v_inc := inc_of(ch(active).dstctl, ch(active).word32);
                  ch(active).cur_dst <= ch(active).cur_dst + v_inc;
                  ch(active).remain  <= ch(active).remain - 1;
                  if (ch(active).remain = 1 or ch(active).enable = '0') then
                     state <= COMPLETE;
                  else
                     state <= RD;
                  end if;

               when COMPLETE =>
                  if (ch(active).repeat = '0' or ch(active).timing = "00") then
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
