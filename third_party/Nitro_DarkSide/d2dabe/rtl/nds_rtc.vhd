-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS RTC (S-35199-style) behind the ARM7 GPIO register 0x04000138.
-- Bus protocol and command set follow melonDS 1.1 RTC.cpp (the oracle):
--   IO bit0 = data, bit1 = clock, bit2 = chip select, bit4 = data direction
--   (1 = CPU drives data). CS rising edge resets the transfer; while CS is
--   high, each write with clock low shifts one bit LSB-first - in on bit0
--   when dir=1 (8 bits -> a byte: first the command, then write data), out
--   on bit0 from the response buffer when dir=0.
-- Command byte: games send the MSB-first form 0110-rrrd (0x6X) which is
-- bit-reversed to rrr-0110/1110; bit7 of the effective command = read.
-- Registers (cmd bits 6:4): 0 status1 (bits 4-7 auto-clear on read),
-- 4 status2, 2 date+time (7 BCD bytes), 6 time (3 BCD bytes), 1/5 alarms,
-- 3 clock adjust, 7 free register.
--
-- The clock ticks from a fixed seed (2026-07-18 Sat 06:00:00, 24h mode) at
-- one BCD second per 33513982 clk1x cycles; date rollover is deliberately
-- naive (day increments to BCD 0x32 at most inside a sim run - nothing in
-- reach runs for a month of sim time). MiSTer wiring can later preset the
-- seed from HPS time via the (not yet added) savestate-style preset bus.
-- No interrupt generation: NitroSDK/calico tick via hardware timers, the
-- RTC /INT line is unconnected on the IRQ side for now (status2 stored).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_rtc is
   port
   (
      clk         : in  std_logic;
      ce          : in  std_logic;
      reset       : in  std_logic;

      -- '1' = firmware boot. Decides the power-up value of status1 bit 7, the
      -- power-off/reset-detect flag. On real hardware it is set at power-up and
      -- auto-clears when status1 is read - and the FIRMWARE is the first reader,
      -- so a game always sees it already clear. HLE direct boot never runs the
      -- firmware, so presenting 0x82 there makes the GAME the first reader and
      -- hands it a flag hardware would never have shown it. Same class of
      -- post-firmware state as the direct-boot env block fakes.
      fw_boot     : in  std_logic := '0';

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic
   );
end entity;

architecture arch of nds_rtc is

   constant ADR_RTC : std_logic_vector(27 downto 0) := x"0000138";

   constant CYCLES_PER_SEC : integer := 33513982;

   signal io_reg     : std_logic_vector(15 downto 0) := (others => '0');

   -- transfer state
   signal in_byte    : std_logic_vector(7 downto 0) := (others => '0');
   signal in_bit     : integer range 0 to 7 := 0;
   signal in_pos     : integer range 0 to 15 := 0;
   signal cur_cmd    : std_logic_vector(7 downto 0) := (others => '0');
   type t_out is array (0 to 6) of std_logic_vector(7 downto 0);
   signal out_buf    : t_out := (others => (others => '0'));
   signal out_bit    : integer range 0 to 7 := 0;
   signal out_pos    : integer range 0 to 6 := 0;

   -- device registers
   -- status1 bit 1 = 24-hour mode, bit 7 = power-off / reset detect. Bit 7 is
   -- POWER-UP-STATE-DEPENDENT and the reset block below selects it from fw_boot:
   --   firmware boot -> 0x82. The ARM7 BIOS bit-bangs status1 out of 0x04000138
   --     and branches on bits 7:6 to pick cold boot vs warm boot; with bit 7 clear
   --     it takes the warm-boot path and diverges from the melonDS oracle at ARM7
   --     instruction ~217000 (pc 0x2216).
   --   direct boot   -> 0x02. Hardware clears bit 7 when status1 is first read,
   --     and on hardware the FIRMWARE is that first reader, so a game never sees
   --     it set. HLE skips the firmware, so 0x82 would make the game the first
   --     reader and hand it a flag hardware would never have shown it.
   signal status1    : std_logic_vector(7 downto 0) := x"02";
   signal status2    : std_logic_vector(7 downto 0) := x"00";
   -- DateTime: year, month, day, weekday, hour, minute, second (BCD)
   type t_dt is array (0 to 6) of std_logic_vector(7 downto 0);
   signal datetime   : t_dt := (x"26", x"07", x"18", x"06", x"06", x"00", x"00");
   signal alarm1     : t_dt := (others => (others => '0'));    -- 0..2 used
   signal alarm2     : t_dt := (others => (others => '0'));    -- 0..2 used
   signal clockadj   : std_logic_vector(7 downto 0) := x"00";
   signal freereg    : std_logic_vector(7 downto 0) := x"00";

   signal sec_div    : integer range 0 to CYCLES_PER_SEC - 1 := 0;

   -- bit-reverse table for the 0x6X command form (melonDS rev[])
   type t_rev is array (0 to 15) of std_logic_vector(7 downto 0);
   constant CMDREV : t_rev := (x"06", x"86", x"46", x"C6", x"26", x"A6", x"66", x"E6",
                               x"16", x"96", x"56", x"D6", x"36", x"B6", x"76", x"F6");

   function bcd_inc(v : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable r : unsigned(7 downto 0) := unsigned(v);
   begin
      if (r(3 downto 0) = 9) then
         r(3 downto 0) := (others => '0');
         r(7 downto 4) := r(7 downto 4) + 1;
      else
         r(3 downto 0) := r(3 downto 0) + 1;
      end if;
      return std_logic_vector(r);
   end function;

begin

   wired_out7  <= x"0000" & io_reg when (bus7.Adr = ADR_RTC) else (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_RTC) else '0';

   process (clk)
      variable wval  : std_logic_vector(15 downto 0);
      variable vbyte : std_logic_vector(7 downto 0);
      variable vcmd  : std_logic_vector(7 downto 0);
      variable vio   : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk) then

         if (reset = '1') then

            io_reg  <= (others => '0');
            in_bit  <= 0; in_pos <= 0; out_bit <= 0; out_pos <= 0;
            -- power-up value: bit 7 set only for a real firmware boot (see the
            -- fw_boot port comment)
            if (fw_boot = '1') then
               status1 <= x"82";
            else
               status1 <= x"02";
            end if;
            status2 <= x"00";
            datetime <= (x"26", x"07", x"18", x"06", x"06", x"00", x"00");
            sec_div <= 0;

         elsif (ce = '1') then

            -- ---------------- wall clock ----------------
            if (sec_div = CYCLES_PER_SEC - 1) then
               sec_div <= 0;
               if (datetime(6) = x"59") then
                  datetime(6) <= x"00";
                  if (datetime(5) = x"59") then
                     datetime(5) <= x"00";
                     if (datetime(4) = x"23") then
                        datetime(4) <= x"00";
                        datetime(2) <= bcd_inc(datetime(2));  -- naive day bump
                     else
                        datetime(4) <= bcd_inc(datetime(4));
                     end if;
                  else
                     datetime(5) <= bcd_inc(datetime(5));
                  end if;
               else
                  datetime(6) <= bcd_inc(datetime(6));
               end if;
            else
               sec_div <= sec_div + 1;
            end if;

            -- ---------------- bus protocol ----------------
            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_RTC) then
               wval := io_reg;
               if (bus7.bEna(0) = '1') then wval(7 downto 0)  := bus7.Din(7 downto 0); end if;
               if (bus7.bEna(1) = '1') then wval(15 downto 8) := bus7.Din(15 downto 8); end if;

               vio := io_reg;

               if (wval(2) = '1') then
                  if (io_reg(2) = '0') then
                     -- CS rising: start transfer
                     in_byte <= (others => '0');
                     in_bit  <= 0;
                     in_pos  <= 0;
                     out_buf <= (others => (others => '0'));
                     out_bit <= 0;
                     out_pos <= 0;
                  elsif (wval(1) = '0') then  -- clock low
                     if (wval(4) = '1') then
                        -- CPU -> RTC, LSB first
                        vbyte := in_byte;
                        vbyte(in_bit) := wval(0);
                        in_byte <= vbyte;
                        if (in_bit = 7) then
                           in_bit  <= 0;
                           in_byte <= (others => '0');
                           if (in_pos < 15) then
                              in_pos <= in_pos + 1;
                           end if;

                           if (in_pos = 0) then
                              -- command byte
                              if (vbyte(7 downto 4) = x"6") then
                                 vcmd := CMDREV(to_integer(unsigned(vbyte(3 downto 0))));
                              else
                                 vcmd := vbyte;
                              end if;
                              cur_cmd <= vcmd;
                              if (vcmd(7) = '1') then
                                 -- read command: fill the response buffer
                                 case vcmd(6 downto 4) is
                                    when "000" =>
                                       out_buf(0) <= status1;
                                       status1(7 downto 4) <= x"0";
                                    when "100" => out_buf(0) <= status2;
                                    when "010" =>
                                       for i in 0 to 6 loop out_buf(i) <= datetime(i); end loop;
                                    when "110" =>
                                       for i in 0 to 2 loop out_buf(i) <= datetime(4 + i); end loop;
                                    when "001" =>
                                       if (status2(2) = '1') then
                                          for i in 0 to 2 loop out_buf(i) <= alarm1(i); end loop;
                                       else
                                          out_buf(0) <= alarm1(2);
                                       end if;
                                    when "101" =>
                                       for i in 0 to 2 loop out_buf(i) <= alarm2(i); end loop;
                                    when "011" => out_buf(0) <= clockadj;
                                    when others => out_buf(0) <= freereg;
                                 end case;
                              end if;
                           else
                              -- write data byte (in_pos >= 1)
                              case cur_cmd(6 downto 4) is
                                 when "000" =>
                                    -- status1: bit0 reset (state only), bits 1-3 stored
                                    status1(3 downto 1) <= vbyte(3 downto 1);
                                 when "100" => status2 <= vbyte;
                                 when "010" =>
                                    if (in_pos <= 7) then datetime(in_pos - 1) <= vbyte; end if;
                                 when "110" =>
                                    if (in_pos <= 3) then datetime(3 + in_pos) <= vbyte; end if;
                                 when "001" =>
                                    if (in_pos <= 3) then alarm1(in_pos - 1) <= vbyte; end if;
                                 when "101" =>
                                    if (in_pos <= 3) then alarm2(in_pos - 1) <= vbyte; end if;
                                 when "011" => clockadj <= vbyte;
                                 when others => freereg <= vbyte;
                              end case;
                           end if;
                        else
                           in_bit <= in_bit + 1;
                        end if;
                     else
                        -- RTC -> CPU, LSB first
                        vio(0) := out_buf(out_pos)(out_bit);
                        if (out_bit = 7) then
                           out_bit <= 0;
                           if (out_pos < 6) then out_pos <= out_pos + 1; end if;
                        else
                           out_bit <= out_bit + 1;
                        end if;
                     end if;
                  end if;
               end if;

               -- IO register update (melonDS Write tail): with dir=1 the
               -- whole value lands; with dir=0 bit0 stays RTC-driven
               if (wval(4) = '1') then
                  io_reg <= wval;
               else
                  io_reg <= wval(15 downto 1) & vio(0);
               end if;

            end if;

         end if;

      end if;
   end process;

end architecture;
