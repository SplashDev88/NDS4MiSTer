-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- Product RTC based on Nitro nds_rtc and melonDS RTC.cpp's GPIO protocol.
-- Calendar range 2000..2099, with Gregorian month lengths and leap years.
-- rtc_seed / rtc_datetime use seven packed BCD bytes, low byte first:
-- year, month, day, weekday (0=Sunday), hour (canonical 24h), minute, second.
-- The CPU serial hour includes PM bit6 in both 12h and 24h modes; the host
-- interface always uses canonical 00..23 without PM bit6.
--
-- Host CDC contract: make seed data stable before changing seed_toggle, then
-- hold until at least four destination clk edges have passed. Data and toggle
-- are synchronized internally; seeds are accepted even during guest reset.
-- Seed is a command, not a continuously enforced clock: guest date edits and
-- elapsed time remain authoritative until another host toggle arrives.
-- Guest reset resets serial/status state, but retains the calendar. FPGA
-- power-up defaults to 2000-01-01; the frontend must seed the real date/time.
-- Accepting a host seed clears the power-loss flag, matching melonDS's frontend.
-- A retained seed-valid flag prevents guest reset from discarding that state.
-- date_written toggles after a complete guest date/time write (or RTC software
-- reset); it does not toggle on elapsed seconds or host seed. Synchronize it
-- and coherently sample rtc_datetime before using it outside this clock domain.
--
-- Scope: calendar, status, serial register access and alarm storage. RTC IRQs,
-- oscillator trim effects, DSi commands and battery-backed retention through
-- FPGA reconfiguration are not implemented. Host persistence is a separate
-- responsibility; the toggle is a notification, not a durability acknowledgement.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_nitro_rtc is
   generic (CYCLES_PER_SECOND : positive := 33513982);
   port
   (
      clk         : in  std_logic;
      ce          : in  std_logic;
      reset       : in  std_logic;

      -- '1' = firmware boot. Before a host seed, status1 bit7 is the
      -- power-off/reset-detect flag. On real hardware it is set at power-up and
      -- auto-clears when status1 is read - and the FIRMWARE is the first reader,
      -- so a game always sees it already clear. HLE direct boot never runs the
      -- firmware, so presenting 0x82 there makes the GAME the first reader and
      -- hands it a flag hardware would never have shown it. Same class of
      -- post-firmware state as the direct-boot env block fakes.
      fw_boot     : in  std_logic := '0';

      rtc_seed        : in  std_logic_vector(55 downto 0) := (others => '0');
      rtc_seed_toggle : in  std_logic := '0';
      rtc_datetime    : out std_logic_vector(55 downto 0);
      date_written    : out std_logic;

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic
   );
end entity;

architecture arch of nds_nitro_rtc is

   constant ADR_RTC : std_logic_vector(27 downto 0) := x"0000138";


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

   -- Firmware cold boot presents reset-detect bit7; direct boot presents
   -- the post-firmware state. Reading status1 clears its upper nibble.
   signal status1    : std_logic_vector(7 downto 0) := x"02";
   signal status2    : std_logic_vector(7 downto 0) := x"00";
   -- DateTime: year, month, day, weekday, hour, minute, second (BCD)
   type t_dt is array (0 to 6) of std_logic_vector(7 downto 0);
   constant INITIAL_DATETIME : t_dt := (x"00", x"01", x"01", x"06", x"00", x"00", x"00");
   signal datetime   : t_dt := INITIAL_DATETIME;
   signal seed_meta, seed_sync : std_logic_vector(55 downto 0) := (others => '0');
   signal seed_toggle_sync : std_logic_vector(2 downto 0) := (others => '0');
   signal seed_seen : std_logic := '0';
   signal seed_valid : std_logic := '0';
   signal date_toggle : std_logic := '0';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of seed_toggle_sync : signal is "TRUE";
   attribute ASYNC_REG of seed_meta : signal is "TRUE";
   attribute ASYNC_REG of seed_sync : signal is "TRUE";
   signal alarm1     : t_dt := (others => (others => '0'));    -- 0..2 used
   signal alarm2     : t_dt := (others => (others => '0'));    -- 0..2 used
   signal clockadj   : std_logic_vector(7 downto 0) := x"00";
   signal freereg    : std_logic_vector(7 downto 0) := x"00";

   signal sec_div    : integer range 0 to CYCLES_PER_SECOND - 1 := 0;

   -- bit-reverse table for the 0x6X command form (melonDS rev[])
   type t_rev is array (0 to 15) of std_logic_vector(7 downto 0);
   constant CMDREV : t_rev := (x"06", x"86", x"46", x"C6", x"26", x"A6", x"66", x"E6",
                               x"16", x"96", x"56", x"D6", x"36", x"B6", x"76", x"F6");

   subtype decimal_t is natural range 0 to 99;
   subtype decoded_bcd_t is natural range 0 to 165;
   function bcd_value(v : std_logic_vector(7 downto 0)) return decoded_bcd_t is
   begin
      return to_integer(unsigned(v(7 downto 4))) * 10 + to_integer(unsigned(v(3 downto 0)));
   end function;

   function to_bcd(v : decimal_t) return std_logic_vector is
   begin
      -- Bounded decimal conversion without fabric division. Most callers use
      -- constant field bounds; the remaining dynamic values are hours/days.
      case v is
         when 0 to 9   => return x"0" & std_logic_vector(to_unsigned(v, 4));
         when 10 to 19 => return x"1" & std_logic_vector(to_unsigned(v - 10, 4));
         when 20 to 29 => return x"2" & std_logic_vector(to_unsigned(v - 20, 4));
         when 30 to 39 => return x"3" & std_logic_vector(to_unsigned(v - 30, 4));
         when 40 to 49 => return x"4" & std_logic_vector(to_unsigned(v - 40, 4));
         when 50 to 59 => return x"5" & std_logic_vector(to_unsigned(v - 50, 4));
         when 60 to 69 => return x"6" & std_logic_vector(to_unsigned(v - 60, 4));
         when 70 to 79 => return x"7" & std_logic_vector(to_unsigned(v - 70, 4));
         when 80 to 89 => return x"8" & std_logic_vector(to_unsigned(v - 80, 4));
         when 90 to 99 => return x"9" & std_logic_vector(to_unsigned(v - 90, 4));
      end case;
   end function;

   function bcd_inc(v : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable r : unsigned(7 downto 0) := unsigned(v);
   begin
      if r(3 downto 0) = 9 then
         r(3 downto 0) := (others => '0');
         r(7 downto 4) := r(7 downto 4) + 1;
      else r(3 downto 0) := r(3 downto 0) + 1; end if;
      return std_logic_vector(r);
   end function;

   function sanitize(v : std_logic_vector(7 downto 0); lo, hi : decimal_t) return std_logic_vector is
   begin
      if unsigned(v(7 downto 4)) > 9 or unsigned(v(3 downto 0)) > 9 or
         unsigned(v) < unsigned(to_bcd(lo)) or unsigned(v) > unsigned(to_bcd(hi)) then
         return to_bcd(lo);
      end if;
      return v;
   end function;

   function month_days(year_bcd, month_bcd : std_logic_vector(7 downto 0)) return natural is
   begin
      case month_bcd is
         when x"02" =>
            -- (10*tens + units) mod 4; all stored years have valid BCD.
            if year_bcd(0) = '0' and year_bcd(1) = year_bcd(4) then return 29; else return 28; end if;
         when x"04" | x"06" | x"09" | x"11" => return 30;
         when others => return 31;
      end case;
   end function;

   function next_month(d : t_dt) return t_dt is
      variable r : t_dt := d;
   begin
      r(2) := x"01";
      if r(1) = x"12" then
         r(1) := x"01";
         if r(0) = x"99" then r(0) := x"00";
         else r(0) := bcd_inc(r(0)); end if;
      else r(1) := bcd_inc(r(1)); end if;
      return r;
   end function;

   function tick_second(d : t_dt) return t_dt is
      variable r : t_dt := d;
   begin
      if r(6) /= x"59" then r(6) := bcd_inc(r(6)); return r; end if;
      r(6) := x"00";
      if r(5) /= x"59" then r(5) := bcd_inc(r(5)); return r; end if;
      r(5) := x"00";
      if r(4) /= x"23" then r(4) := bcd_inc(r(4)); return r; end if;
      r(4) := x"00";
      if r(3) = x"06" then r(3) := x"00";
      else r(3) := bcd_inc(r(3)); end if;
      if unsigned(r(2)) >= unsigned(to_bcd(month_days(r(0), r(1)))) then return next_month(r); end if;
      r(2) := bcd_inc(r(2));
      return r;
   end function;

   function serial_hour(hour : std_logic_vector(7 downto 0); mode24 : std_logic) return std_logic_vector is
      variable n : natural range 0 to 23 := bcd_value(hour);
      variable r : std_logic_vector(7 downto 0);
   begin
      if mode24 = '1' then r := hour;
      elsif n >= 12 then r := to_bcd(n - 12); else r := hour; end if;
      if n >= 12 then r(6) := '1'; end if;
      return r;
   end function;

   function write_field(d : t_dt; index : natural; value : std_logic_vector(7 downto 0);
                        mode24 : std_logic) return t_dt is
      variable r : t_dt := d;
      variable h : std_logic_vector(7 downto 0);
      variable n : natural range 0 to 23;
   begin
      case index is
         when 0 => r(0) := sanitize(value, 0, 99);
         when 1 => r(1) := sanitize(value and x"1F", 1, 12);
         when 2 =>
            r(2) := sanitize(value and x"3F", 1, 31);
            -- melonDS WriteDateTime rolls an out-of-month day to day 1 of
            -- the following month after sanitizing the individual BCD field.
            if unsigned(r(2)) > unsigned(to_bcd(month_days(r(0), r(1)))) then r := next_month(r); end if;
         when 3 => r(3) := sanitize(value and x"07", 0, 6);
         when 4 =>
            if mode24 = '1' then r(4) := sanitize(value and x"3F", 0, 23);
            else
               h := sanitize(value and x"3F", 0, 11);
               n := bcd_value(h);
               if value(6) = '1' then n := n + 12; end if;
               r(4) := to_bcd(n);
            end if;
         when 5 => r(5) := sanitize(value and x"7F", 0, 59);
         when 6 => r(6) := sanitize(value and x"7F", 0, 59);
         when others => null;
      end case;
      return r;
   end function;

   function seeded_date(v : std_logic_vector(55 downto 0)) return t_dt is
      variable r : t_dt;
   begin
      r(0) := sanitize(v(7 downto 0), 0, 99);
      r(1) := sanitize(v(15 downto 8), 1, 12);
      r(2) := sanitize(v(23 downto 16), 1, month_days(r(0), r(1)));
      r(3) := sanitize(v(31 downto 24), 0, 6);
      r(4) := sanitize(v(39 downto 32), 0, 23);
      r(5) := sanitize(v(47 downto 40), 0, 59);
      r(6) := sanitize(v(55 downto 48), 0, 59);
      return r;
   end function;

begin

   datetime_pack : for i in 0 to 6 generate
      rtc_datetime(i * 8 + 7 downto i * 8) <= datetime(i);
   end generate;
   date_written <= date_toggle;

   wired_out7  <= x"0000" & io_reg when (bus7.Adr = ADR_RTC) else (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_RTC) else '0';

   process (clk)
      variable wval  : std_logic_vector(15 downto 0);
      variable vbyte : std_logic_vector(7 downto 0);
      variable vcmd  : std_logic_vector(7 downto 0);
      variable vio   : std_logic_vector(15 downto 0);
      variable next_dt : t_dt;
   begin
      if rising_edge(clk) then
         seed_meta <= rtc_seed;
         seed_sync <= seed_meta;
         seed_toggle_sync <= seed_toggle_sync(1 downto 0) & rtc_seed_toggle;
         next_dt := datetime;

         if (reset = '1') then

            io_reg  <= (others => '0');
            in_bit  <= 0; in_pos <= 0; out_bit <= 0; out_pos <= 0;
            -- An imported configured firmware with valid host time must not
            -- enter its battery-reset setup flow on a later guest reset.
            if (fw_boot = '1' and seed_valid = '0') then
               status1 <= x"82";
            else
               status1 <= x"02";
            end if;
            status2 <= x"00";
            in_byte <= (others => '0'); cur_cmd <= (others => '0');
            out_buf <= (others => (others => '0'));

         elsif (ce = '1') then

            -- ce must represent a 33,513,982 Hz DS clock enable (or use
            -- the generic for the actual qualified clock rate).
            if sec_div = CYCLES_PER_SECOND - 1 then
               sec_div <= 0;
               next_dt := tick_second(datetime);
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
                              if vcmd(7) = '1' and vcmd(3 downto 0) = x"6" then
                                 -- read command: fill the response buffer
                                 case vcmd(6 downto 4) is
                                    when "000" =>
                                       out_buf(0) <= status1;
                                       status1(7 downto 4) <= x"0";
                                    when "100" => out_buf(0) <= status2;
                                    when "010" =>
                                       for i in 0 to 6 loop out_buf(i) <= next_dt(i); end loop;
                                       out_buf(4) <= serial_hour(next_dt(4), status1(1));
                                    when "110" =>
                                       for i in 0 to 2 loop out_buf(i) <= next_dt(4 + i); end loop;
                                       out_buf(0) <= serial_hour(next_dt(4), status1(1));
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
                              -- Only DS register commands are implemented.
                              if cur_cmd(3 downto 0) = x"6" and cur_cmd(7) = '0' then
                                 case cur_cmd(6 downto 4) is
                                    when "000" =>
                                       if in_pos = 1 then
                                          if vbyte(0) = '1' then
                                             next_dt := INITIAL_DATETIME;
                                             status1 <= (others => '0');
                                             status2 <= (others => '0');
                                             alarm1 <= (others => (others => '0'));
                                             alarm2 <= (others => (others => '0'));
                                             clockadj <= x"00"; freereg <= x"00";
                                             sec_div <= 0;
                                             date_toggle <= not date_toggle;
                                          end if;
                                          status1(3 downto 1) <= vbyte(3 downto 1);
                                          -- Canonical 24h storage needs no time
                                          -- mutation when changing display mode.
                                       end if;
                                    when "100" => if in_pos = 1 then status2 <= vbyte; end if;
                                    when "010" =>
                                       if in_pos <= 7 then next_dt := write_field(next_dt, in_pos - 1, vbyte, status1(1)); end if;
                                       if in_pos = 7 then date_toggle <= not date_toggle; sec_div <= 0; end if;
                                    when "110" =>
                                       if in_pos <= 3 then next_dt := write_field(next_dt, in_pos + 3, vbyte, status1(1)); end if;
                                       if in_pos = 3 then date_toggle <= not date_toggle; sec_div <= 0; end if;
                                    when "001" =>
                                       if status2(2) = '1' then
                                          if in_pos <= 3 then alarm1(in_pos - 1) <= vbyte; end if;
                                       elsif in_pos = 1 then alarm1(2) <= vbyte; end if;
                                    when "101" => if in_pos <= 3 then alarm2(in_pos - 1) <= vbyte; end if;
                                    when "011" => if in_pos = 1 then clockadj <= vbyte; end if;
                                    when others => if in_pos = 1 then freereg <= vbyte; end if;
                                 end case;
                              end if;
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

         if seed_toggle_sync(2) /= seed_seen then
            next_dt := seeded_date(seed_sync);
            seed_seen <= seed_toggle_sync(2);
            seed_valid <= '1';
            sec_div <= 0;
            status1(7) <= '0';
         end if;
         datetime <= next_dt;

      end if;
   end process;

end architecture;
