-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Writable-firmware extension contributed by InsaneFriend (GitHub: saneFriend).
-- NDS ARM7 SPI bus (0x040001C0 SPICNT / 0x040001C2 SPIDATA) with the three
-- boot-relevant devices, modeled after melonDS 1.1 src/SPI.cpp for oracle
-- parity:
--   device 0: power management IC (registers 0..7, masks per melonDS,
--             reg4 resets to 0x40; shutdown bit is accepted and ignored)
--   device 1: firmware flash (03 read / 05 RDSR / 04 WRDI / 06 WREN /
--             02 and 0A program). The 256 KB address space is served by
--             the fw_* backing port, with acknowledged byte writes and
--             persistent writeback busy reported by flash status bit0.
--   device 2: touchscreen TSC (control byte -> 12-bit conversion; touch
--             coordinates match melonDS: X/Y are the held 8-bit pixel
--             coordinates shifted left four, while release is X=0/Y=0xFFF;
--             mic reads 0x800 at rest or synthetic blowing noise while held;
--             temperature etc. read 0xFFF)
-- Lid reopening produces a one-cycle ARM7 IRQ22, including while halted.
--
-- A byte transfer takes 8*(8<<baud) clk cycles (SPI shifts one bit per
-- 33 MHz cycle pair set by baud); busy (bit7) is set for the duration and
-- irq_spi pulses at completion when CNT bit14 is set. Reading SPIDATA
-- while busy or disabled returns 0. Disabling the bus (bit15 1->0)
-- releases the selected device's chipselect (libnds relies on this).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- PRODUCT-LOCAL DERIVATIVE of the donor nds_spi.vhd, with an acknowledged
-- write-back path and program chip-select release for the firmware flash.
--
-- The donor accepts command 0x0A on the bus but discards the data, because its
-- image is a read-only hex fixture. Measured against melonDS: Pokemon Pearl
-- issues 0x06 / 0x0A / 0x04 (write enable, page program, write disable) and
-- will NOT boot unless those writes persist -- with the image served correctly
-- but writes discarded it hangs in exactly the ARM9 spin loop observed on
-- hardware. New Super Mario Bros. only ever issues 0x03/0x05, which is why it
-- was never affected.
--
-- Page program on real flash can only clear bits; melonDS stores the byte
-- outright and boots the game, so this follows melonDS rather than the
-- stricter hardware behaviour.
entity nds_nitro_spi is
   generic (EXPERIMENTAL_CHECKPOINT : boolean := false);
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

      -- Firmware image write-back, driven by the 0x0A handler below. There is
      -- deliberately no separate write address: the 0x0A path drives the SAME
      -- fw_addr register a read would, so the store reuses its existing decode.
      -- A second 16-bit decode cost ~163 ALMs and broke routing on this
      -- 98%-full device.
      fw_wr       : out std_logic := '0';
      fw_wlane    : out unsigned(1 downto 0) := (others => '0');
      fw_wdata    : out std_logic_vector(7 downto 0) := (others => '0');
      -- Sector-backed firmware reports uncommitted writes in flash status bit0.
      -- Every fw_wr is acknowledged via fw_done before SPI busy can clear.
      fw_busy     : in std_logic := '0';
      fw_release  : out std_logic := '0';

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic;

      irq_spi     : out std_logic := '0';   -- one-cycle pulse (ARM7 IRQ bit 23)

      touch_active : in std_logic;
      touch_x      : in std_logic_vector(7 downto 0);
      touch_y      : in std_logic_vector(7 downto 0);

      -- firmware image read port (256 KB, word addressed). fw_req pulses
      -- one cycle with a fresh fw_addr; the backing store answers with
      -- fw_done + valid fw_data any number of cycles later (BRAM: 1 cycle,
      -- DDR3 pager: tens). The SPI byte busy window stretches until the
      -- word arrives, so any latency is architecturally invisible.
      fw_addr     : out unsigned(17 downto 2) := (others => '0');
      fw_req      : out std_logic := '0';
      fw_done     : in  std_logic;
      fw_data     : in  std_logic_vector(31 downto 0);

      lid_closed  : in std_logic := '0';
      mic_blow    : in std_logic := '0';
      irq_lid     : out std_logic := '0';
      checkpoint_stop : in std_logic := '0';
      checkpoint_stopped : out std_logic := '0';
      -- Nine ordered words (0..8), captured only at a drained byte boundary.
      -- Restore writes the live registers with reset and stop held throughout.
      checkpoint_address : in unsigned(3 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
   );
end entity;

architecture arch of nds_nitro_spi is

   constant ADR_SPI : std_logic_vector(27 downto 0) := x"00001C0";

   -- host
   signal cnt        : std_logic_vector(15 downto 0) := (others => '0'); -- bit7 = busy
   signal delay_cnt  : unsigned(9 downto 0) := (others => '0');
   signal cnt_rd     : std_logic_vector(31 downto 0);
   signal rdata      : std_logic_vector(7 downto 0);

   -- power management
   type t_pmregs is array (0 to 7) of std_logic_vector(7 downto 0);
   signal pm_regs    : t_pmregs := (others => (others => '0'));
   signal pm_hold    : std_logic := '0';
   signal pm_index   : std_logic_vector(7 downto 0) := (others => '0');
   signal pm_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal pm_datapos : unsigned(1 downto 0) := (others => '0');

   function pm_mask(i : integer) return std_logic_vector is
   begin
      case i is
         when 0 => return x"7F";
         when 2 => return x"01";
         when 3 => return x"03";
         when 4 => return x"0F";
         when others => return x"00";
      end case;
   end function;

   -- firmware flash
   signal fw_hold    : std_logic := '0';
   signal fw_cmd     : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_datapos : unsigned(2 downto 0) := (others => '0');   -- saturates at 7
   signal fw_a       : unsigned(23 downto 0) := (others => '0');
   signal fw_out     : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_status  : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_pending_write : std_logic := '0';
   signal fw_pend    : std_logic := '0';   -- backing read/write outstanding
   signal fw_lane    : unsigned(1 downto 0) := (others => '0');
   signal lid_was_closed : std_logic := '0';
   -- Clipped, band-limited noise approximates a breath hitting the microphone.
   -- Hold each random polarity for four conversions; unfiltered LFSR samples
   -- are rejected by games that classify blowing rather than just loudness.
   -- Use symmetric +/-127 in 8-bit mode: -128 trips NSMB's peak check.
   -- No host audio stream, sample ROM or changes to console clocking are needed.
   signal mic_noise : unsigned(15 downto 0) := x"ACE1";
   signal mic_phase : unsigned(1 downto 0) := (others => '0');
   signal mic_positive : std_logic := '0';

   -- touchscreen
   signal tsc_ctrl    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_datapos : unsigned(1 downto 0) := (others => '0');
   signal tsc_conv    : unsigned(11 downto 0) := (others => '0');
   signal stop_spi : std_logic;
   signal restore_active, restore_write_valid : std_logic;
   signal restore_count : unsigned(3 downto 0) := (others => '0');
   signal restore_error : std_logic := '0';

   function valid_word(a : unsigned(3 downto 0); d : std_logic_vector(31 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 0 => return d(31 downto 17) = (31 downto 17 => '0') and
                          (d(15 downto 0) and x"34FC") = x"0000";
         when 1 | 2 | 4 => return true;
         when 3 | 8 => return d(31 downto 19) = (31 downto 19 => '0');
         when 5 => return d(31 downto 23) = (31 downto 23 => '0');
         when 6 => return d(31 downto 26) = (31 downto 26 => '0');
         when 7 => return d(31 downto 30) = "00";
         when others => return false;
      end case;
   end function;

begin

   stop_spi <= checkpoint_stop when EXPERIMENTAL_CHECKPOINT else '0';
   -- Byte completion drains its actual backing response and IRQ. Chip-select
   -- and command state remain intact. fw_busy belongs to the external cache,
   -- whose dirty data/host transactions require a separate capture contract.
   checkpoint_stopped <= '1' when stop_spi = '1' and reset = '0' and
      bus7.ena = '0' and cnt(7) = '0' and fw_pend = '0' and fw_done = '0' and
      fw_req = '0' and fw_wr = '0' and fw_release = '0' and
      irq_spi = '0' and irq_lid = '0' else '0';

   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   restore_write_valid <= '1' when restore_active = '1' and stop_spi = '1' and
      bus7.ena = '0' and fw_done = '0' and restore_error = '0' and checkpoint_write = '1' and
      restore_count < 9 and checkpoint_address = restore_count and
      valid_word(checkpoint_address, checkpoint_write_data) else '0';
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and stop_spi = '1' and
      bus7.ena = '0' and fw_done = '0' and restore_count = 9 and restore_error = '0' and
      checkpoint_write = '0' else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then
            restore_count <= (others => '0'); restore_error <= '0';
         elsif reset = '0' or stop_spi = '0' or bus7.ena = '1' or fw_done = '1' then
            restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then restore_count <= restore_count + 1;
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;

   process(all)
   begin
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and checkpoint_address < 9 and
         ((checkpoint_stopped = '1' and checkpoint_restore = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         case to_integer(checkpoint_address) is
            when 0 => checkpoint_data(16 downto 0) <= lid_was_closed & cnt;
            when 1 | 2 =>
               for i in 0 to 3 loop
                  checkpoint_data(i*8+7 downto i*8) <= pm_regs((to_integer(checkpoint_address)-1)*4+i);
               end loop;
            when 3 => checkpoint_data(18 downto 0) <= pm_hold & std_logic_vector(pm_datapos) & pm_data & pm_index;
            when 4 => checkpoint_data <= fw_cmd & std_logic_vector(fw_a);
            when 5 => checkpoint_data(22 downto 0) <= std_logic_vector(fw_lane) & fw_pending_write & fw_hold &
               std_logic_vector(fw_datapos) & fw_status & fw_out;
            when 6 => checkpoint_data(25 downto 0) <= std_logic_vector(fw_wlane) & fw_wdata & std_logic_vector(fw_addr);
            when 7 => checkpoint_data(29 downto 0) <= std_logic_vector(tsc_conv) & std_logic_vector(tsc_datapos) & tsc_data & tsc_ctrl;
            when 8 => checkpoint_data(18 downto 0) <= mic_positive & std_logic_vector(mic_phase) & std_logic_vector(mic_noise);
            when others => null;
         end case;
      end if;
   end process;

   rdata <= x"00"   when (cnt(15) = '0' or cnt(7) = '1') else
            pm_data when (cnt(9 downto 8) = "00") else
            fw_out  when (cnt(9 downto 8) = "01") else
            tsc_data;

   cnt_rd <= x"00" & rdata & cnt;

   wired_out7  <= cnt_rd when (bus7.Adr = ADR_SPI) else (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_SPI) else '0';

   process (clk)
      variable wval     : std_logic_vector(7 downto 0);
      variable dev      : std_logic_vector(1 downto 0);
      variable conv     : unsigned(11 downto 0);
      variable v_release : std_logic;
   begin
      if rising_edge(clk) then

         irq_spi <= '0';
         irq_lid <= '0';

         if restore_active = '1' then
            -- Busy/delay, backing request and IRQ pulses are absent at capture.
            -- Preserve loaded words through arbitrary gaps; ordinary reset must
            -- not erase them. External firmware cache data/dirty epoch are NOT
            -- included in this local image and need their own restore owner.
            delay_cnt <= (others => '0'); fw_pend <= '0';
            fw_req <= '0'; fw_wr <= '0'; fw_release <= '0';
            if restore_write_valid = '1' then
               case to_integer(checkpoint_address) is
                  when 0 => cnt <= checkpoint_write_data(15 downto 0); lid_was_closed <= checkpoint_write_data(16);
                  when 1 | 2 =>
                     for i in 0 to 3 loop
                        pm_regs((to_integer(checkpoint_address)-1)*4+i) <= checkpoint_write_data(i*8+7 downto i*8);
                     end loop;
                  when 3 =>
                     pm_index <= checkpoint_write_data(7 downto 0); pm_data <= checkpoint_write_data(15 downto 8);
                     pm_datapos <= unsigned(checkpoint_write_data(17 downto 16)); pm_hold <= checkpoint_write_data(18);
                  when 4 => fw_a <= unsigned(checkpoint_write_data(23 downto 0)); fw_cmd <= checkpoint_write_data(31 downto 24);
                  when 5 =>
                     fw_out <= checkpoint_write_data(7 downto 0); fw_status <= checkpoint_write_data(15 downto 8);
                     fw_datapos <= unsigned(checkpoint_write_data(18 downto 16)); fw_hold <= checkpoint_write_data(19);
                     fw_pending_write <= checkpoint_write_data(20); fw_lane <= unsigned(checkpoint_write_data(22 downto 21));
                  when 6 =>
                     fw_addr <= unsigned(checkpoint_write_data(15 downto 0)); fw_wdata <= checkpoint_write_data(23 downto 16);
                     fw_wlane <= unsigned(checkpoint_write_data(25 downto 24));
                  when 7 =>
                     tsc_ctrl <= checkpoint_write_data(7 downto 0); tsc_data <= checkpoint_write_data(15 downto 8);
                     tsc_datapos <= unsigned(checkpoint_write_data(17 downto 16)); tsc_conv <= unsigned(checkpoint_write_data(29 downto 18));
                  when 8 =>
                     mic_noise <= unsigned(checkpoint_write_data(15 downto 0)); mic_phase <= unsigned(checkpoint_write_data(17 downto 16));
                     mic_positive <= checkpoint_write_data(18);
                  when others => null;
               end case;
            end if;
         elsif (reset = '1') then
            lid_was_closed <= lid_closed;
            mic_noise <= x"ACE1";
            mic_phase <= (others => '0');
            mic_positive <= '0';
            cnt        <= (others => '0');
            delay_cnt  <= (others => '0');
            pm_regs    <= (others => (others => '0'));
            pm_regs(4) <= x"40";
            pm_hold    <= '0';
            pm_data    <= (others => '0');
            fw_hold    <= '0';
            fw_status  <= (others => '0');
            fw_out     <= (others => '0');
            fw_pend    <= '0';
            fw_req     <= '0';
            fw_wr      <= '0';
            fw_release <= '0';
            fw_pending_write <= '0';
            tsc_ctrl   <= (others => '0');
            tsc_data   <= (others => '0');
            tsc_datapos <= (others => '0');
            tsc_conv   <= (others => '0');
         else
            -- Preserve the last observed lid while stopped. On release the
            -- current physical state is sampled, producing at most the normal
            -- reopen pulse. Input changes while stopped are not an event log.
            if stop_spi = '0' then
            lid_was_closed <= lid_closed;
            irq_lid <= lid_was_closed and not lid_closed;
            end if;

            -- firmware word fetch: request issued at transfer start, byte
            -- lane latched whenever the backing store answers (the busy
            -- window below waits for fw_pend to clear)
            fw_req <= '0';
            fw_wr  <= '0';
            fw_release <= '0';
            if (fw_pend = '1' and fw_done = '1') then
               fw_pend <= '0';
               if fw_pending_write = '0' then
               case fw_lane is
                  when "00" => fw_out <= fw_data( 7 downto  0);
                  when "01" => fw_out <= fw_data(15 downto  8);
                  when "10" => fw_out <= fw_data(23 downto 16);
                  when others => fw_out <= fw_data(31 downto 24);
               end case;
               end if;
            end if;

            -- transfer completion (held while a firmware fetch is in flight)
            if (cnt(7) = '1') then
               if (delay_cnt = 0 and fw_pend = '0') then
                  cnt(7) <= '0';
                  if (cnt(14) = '1') then
                     irq_spi <= '1';
                  end if;
               elsif delay_cnt /= 0 then
                  -- Saturate while storage is backpressured; wrapping at zero
                  -- used to append an unrelated 1024-cycle delay after an ack.
                  delay_cnt <= delay_cnt - 1;
               end if;
            end if;

            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_SPI) then

               -- SPICNT low/high bytes (0x1C0/0x1C1)
               if (bus7.bEna(0) = '1') then
                  -- busy (bit7) is read-only; writable low bits: baud [1:0]
                  cnt(6 downto 2) <= (others => '0');
                  cnt(1 downto 0) <= bus7.Din(1 downto 0);
               end if;
               if (bus7.bEna(1) = '1') then
                  -- writable: [9:8] device, [11] hold, [14] irq, [15] enable
                  -- (mask 0xCF03 with byte granularity)
                  if (cnt(15) = '1' and bus7.Din(15) = '0') then
                     -- disable releases the selected device's chipselect
                     case cnt(9 downto 8) is
                        when "00" => pm_hold <= '0';
                        when "01" =>
                           fw_hold <= '0';
                           if fw_hold = '1' and (fw_cmd = x"0A" or fw_cmd = x"02") then
                              fw_release <= '1';
                           end if;
                        when others =>
                           -- melonDS SPIDevice::Release() resets the TSC byte
                           -- position whenever chip-select is released.  Some
                           -- games use PENIRQ only on broad title prompts, but
                           -- begin real coordinate conversions in a fresh SPI
                           -- transaction.  Carrying the old position into that
                           -- transaction shifts the X/Y result bytes.
                           tsc_datapos <= (others => '0');
                     end case;
                  end if;
                  cnt(15 downto 14) <= bus7.Din(15 downto 14);
                  cnt(11)           <= bus7.Din(11);
                  cnt(9 downto 8)   <= bus7.Din(9 downto 8);
                  cnt(13 downto 12) <= "00";
                  cnt(10)           <= '0';
               end if;

               -- SPIDATA (0x1C2)
               if (bus7.bEna(2) = '1' and cnt(15) = '1' and cnt(7) = '0') then
                  wval := bus7.Din(23 downto 16);
                  dev  := cnt(9 downto 8);
                  cnt(7)    <= '1';
                  delay_cnt <= shift_left(to_unsigned(8, 10), 3 + to_integer(unsigned(cnt(1 downto 0)))) - 1;
                  v_release := not cnt(11);

                  case dev is

                     when "00" =>   -- power management
                        if (pm_hold = '0') then
                           pm_index   <= wval;
                           pm_hold    <= '1';
                           pm_data    <= (others => '0');
                           pm_datapos <= "01";
                        else
                           if (pm_datapos = 1) then
                              if (pm_index(7) = '1') then
                                 pm_data <= pm_regs(to_integer(unsigned(pm_index(2 downto 0))));
                              else
                                 pm_regs(to_integer(unsigned(pm_index(2 downto 0)))) <=
                                    (pm_regs(to_integer(unsigned(pm_index(2 downto 0)))) and not pm_mask(to_integer(unsigned(pm_index(2 downto 0)))))
                                    or (wval and pm_mask(to_integer(unsigned(pm_index(2 downto 0)))));
                                 pm_data <= (others => '0');
                              end if;
                           else
                              pm_data <= (others => '0');
                           end if;
                           if (pm_datapos /= 3) then
                              pm_datapos <= pm_datapos + 1;
                           end if;
                        end if;
                        if (v_release = '1') then pm_hold <= '0'; end if;

                     when "01" =>   -- firmware flash
                        if (fw_hold = '0') then
                           fw_cmd     <= wval;
                           fw_hold    <= '1';
                           fw_out     <= (others => '0');
                           fw_datapos <= "001";
                           fw_a       <= (others => '0');
                           case wval is
                              when x"04" => fw_status(1) <= '0';   -- write disable
                              when x"06" => fw_status(1) <= '1';   -- write enable
                              when others => null;
                           end case;
                        else
                           case fw_cmd is
                              when x"03" =>   -- read
                                 if (fw_datapos < 4) then
                                    fw_a   <= fw_a(15 downto 0) & unsigned(wval);
                                    fw_out <= (others => '0');
                                 else
                                    -- serve fw[addr & 0x3FFFF], addr++ (2 Mbit
                                    -- chip mirror-wraps at 256 KB)
                                    fw_addr  <= fw_a(17 downto 2);
                                    fw_lane  <= fw_a(1 downto 0);
                                    fw_req   <= '1';
                                    fw_pend  <= '1';
                                    fw_pending_write <= '0';
                                    fw_a     <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when x"05" =>   -- read status register
                                 fw_out <= fw_status(7 downto 1) & fw_busy;
                              when x"0A" | x"02" => -- page program, acknowledged backing
                                 if (fw_datapos < 4) then
                                    fw_a   <= fw_a(15 downto 0) & unsigned(wval);
                                    fw_out <= (others => '0');
                                 else
                                    fw_out   <= wval;
                                    -- Publish the byte to the firmware store,
                                    -- reusing fw_addr so the store needs only
                                    -- one address decode. Only writes inside a
                                    -- served region take effect; the store
                                    -- ignores the rest, so this cannot corrupt
                                    -- anything it does not already hold.
                                    fw_addr  <= fw_a(17 downto 2);
                                    fw_wlane <= fw_a(1 downto 0);
                                    fw_wdata <= wval;
                                    fw_wr    <= '1';
                                    fw_pend <= '1';
                                    fw_pending_write <= '1';
                                    fw_a     <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when others =>
                                 fw_out <= (others => '0');
                           end case;
                        end if;
                        if (v_release = '1') then
                           fw_hold <= '0';
                           if fw_hold = '1' and (fw_cmd = x"0A" or fw_cmd = x"02") then
                              fw_release <= '1';
                           end if;
                        end if;

                     when others =>   -- touchscreen
                        if (tsc_datapos = 1) then
                           tsc_data <= '0' & std_logic_vector(tsc_conv(11 downto 5));
                        elsif (tsc_datapos = 2) then
                           tsc_data <= std_logic_vector(tsc_conv(4 downto 0)) & "000";
                        else
                           tsc_data <= (others => '0');
                        end if;
                        if (wval(7) = '1') then
                           tsc_ctrl    <= wval;
                           tsc_datapos <= "01";
                           case wval(6 downto 4) is
                              when "001" =>
                                 if (touch_active = '1') then
                                    conv := shift_left(resize(unsigned(touch_y), 12), 4);
                                 else
                                    conv := x"FFF";                       -- released Y
                                 end if;
                              when "101" =>
                                 if (touch_active = '1') then
                                    conv := shift_left(resize(unsigned(touch_x), 12), 4);
                                 else
                                    conv := (others => '0');              -- released X
                                 end if;
                              when "110" =>
                                 conv := x"800";
                                 if mic_blow = '1' then
                                    conv := x"010";
                                    if mic_phase = 0 then
                                       mic_positive <= mic_noise(0);
                                       if mic_noise(0) = '1' then conv := x"FF0"; end if;
                                    elsif mic_positive = '1' then
                                       conv := x"FF0";
                                    end if;
                                    mic_phase <= mic_phase + 1;
                                    mic_noise <= (mic_noise(0) xor mic_noise(2) xor
                                                  mic_noise(3) xor mic_noise(5)) &
                                                 mic_noise(15 downto 1);
                                 else
                                    mic_phase <= (others => '0');
                                 end if;
                              when others => conv := x"FF" & x"F";        -- everything else: 0xFFF
                           end case;
                           if (wval(3) = '1') then
                              conv := conv and x"FF0";
                           end if;
                           tsc_conv <= conv;
                        else
                           if (tsc_datapos /= 3) then
                              tsc_datapos <= tsc_datapos + 1;
                           end if;
                        end if;
                        if (v_release = '1') then
                           -- Match SPIHost::WriteData(): the transferred byte
                           -- is produced first, then an unheld transaction
                           -- releases chip-select and resets DataPos.
                           tsc_datapos <= (others => '0');
                        end if;

                  end case;
               end if;
            end if;

         end if;
      end if;
   end process;

end architecture;
