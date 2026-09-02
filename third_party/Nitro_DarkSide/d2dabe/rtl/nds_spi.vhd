-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS ARM7 SPI bus (0x040001C0 SPICNT / 0x040001C2 SPIDATA) with the three
-- boot-relevant devices, modeled after melonDS 1.1 src/SPI.cpp for oracle
-- parity:
--   device 0: power management IC (registers 0..7, masks per melonDS,
--             reg4 resets to 0x40; shutdown bit is accepted and ignored)
--   device 1: firmware flash (commands 03 read / 05 RDSR / 04 WRDI /
--             06 WREN; 0A write is accepted bus-side but the image is
--             read-only). The 128 KB image is served through the fw_*
--             port (sim/tests/nds_firmware.hex = melonDS's generated
--             default firmware, dumped by melonds_fwdump).
--   device 2: touchscreen TSC (control byte -> 12-bit conversion; touch
--             coordinates match melonDS: X/Y are the held 8-bit pixel
--             coordinates shifted left four, while release is X=0/Y=0xFFF;
--             mic reads 0x800 and temperature etc. read 0xFFF)
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

entity nds_spi is
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

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
      fw_data     : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_spi is

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
   signal fw_datapos : unsigned(2 downto 0) := (others => '0');   -- saturates at 4
   signal fw_a       : unsigned(23 downto 0) := (others => '0');
   signal fw_out     : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_status  : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_pend    : std_logic := '0';   -- word fetch outstanding (holds busy)
   signal fw_lane    : unsigned(1 downto 0) := (others => '0');

   -- touchscreen
   signal tsc_ctrl    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_datapos : unsigned(1 downto 0) := (others => '0');
   signal tsc_conv    : unsigned(11 downto 0) := (others => '0');

begin

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

         if (reset = '1') then
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
            tsc_ctrl   <= (others => '0');
            tsc_data   <= (others => '0');
            tsc_datapos <= (others => '0');
            tsc_conv   <= (others => '0');
         else

            -- firmware word fetch: request issued at transfer start, byte
            -- lane latched whenever the backing store answers (the busy
            -- window below waits for fw_pend to clear)
            fw_req <= '0';
            if (fw_pend = '1' and fw_done = '1') then
               fw_pend <= '0';
               case fw_lane is
                  when "00" => fw_out <= fw_data( 7 downto  0);
                  when "01" => fw_out <= fw_data(15 downto  8);
                  when "10" => fw_out <= fw_data(23 downto 16);
                  when others => fw_out <= fw_data(31 downto 24);
               end case;
            end if;

            -- transfer completion (held while a firmware fetch is in flight)
            if (cnt(7) = '1') then
               if (delay_cnt = 0 and fw_pend = '0') then
                  cnt(7) <= '0';
                  if (cnt(14) = '1') then
                     irq_spi <= '1';
                  end if;
               else
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
                        when "01" => fw_hold <= '0';
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
                                    fw_a     <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when x"05" =>   -- read status register
                                 fw_out <= fw_status;
                              when x"0A" =>   -- write: bus behavior only, image is read-only
                                 if (fw_datapos < 4) then
                                    fw_a   <= fw_a(15 downto 0) & unsigned(wval);
                                    fw_out <= (others => '0');
                                 else
                                    fw_out <= wval;
                                    fw_a   <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when others =>
                                 fw_out <= (others => '0');
                           end case;
                        end if;
                        if (v_release = '1') then fw_hold <= '0'; end if;

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
                              when "110" => conv := x"80" & x"0";         -- mic: silence -> 0x800
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
