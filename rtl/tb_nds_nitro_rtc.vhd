library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_nitro_rtc is end entity;

architecture sim of tb_nds_nitro_rtc is
   signal clk : std_logic := '0';
   signal ce : std_logic := '1';
   signal reset : std_logic := '1';
   signal fw_boot : std_logic := '1';
   signal rtc_seed, rtc_datetime : std_logic_vector(55 downto 0) := (others => '0');
   signal rtc_seed_toggle, date_written : std_logic := '0';
   signal bus7 : proc_bus_gb_type := (
      Din => (others => '0'), Adr => x"0000138", rnw => '1', ena => '0',
      acc => ACCESS_16BIT, bEna => (others => '0'), rst => '0');
   signal dout : std_logic_vector(31 downto 0);
   signal done : std_logic;
   subtype byte_t is std_logic_vector(7 downto 0);
   type bytes_t is array(natural range <>) of byte_t;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_nitro_rtc
      generic map (CYCLES_PER_SECOND => 8192)
      port map (clk => clk, ce => ce, reset => reset, fw_boot => fw_boot,
         rtc_seed => rtc_seed, rtc_seed_toggle => rtc_seed_toggle,
         rtc_datetime => rtc_datetime, date_written => date_written,
         bus7 => bus7, wired_out7 => dout, wired_done7 => done);

   process
      variable result : bytes_t(0 to 6);
      variable toggle_before : std_logic;
      variable before : std_logic_vector(55 downto 0);
      variable hour_seed : std_logic_vector(55 downto 0);
      variable hour_bcd, hour_wire : byte_t;

      procedure cycles(constant count : natural) is
      begin
         for i in 1 to count loop wait until falling_edge(clk); end loop;
      end procedure;

      procedure seed(constant value : std_logic_vector(55 downto 0)) is
      begin
         wait until falling_edge(clk);
         rtc_seed <= value;
         cycles(2);
         rtc_seed_toggle <= not rtc_seed_toggle;
         cycles(6);
      end procedure;

      procedure poke(constant value : byte_t) is
      begin
         wait until falling_edge(clk);
         bus7.Din <= x"000000" & value;
         bus7.rnw <= '0'; bus7.ena <= '1'; bus7.bEna <= "0001";
         wait until falling_edge(clk);
         bus7.rnw <= '1'; bus7.ena <= '0'; bus7.bEna <= "0000";
      end procedure;

      procedure begin_serial is
      begin
         poke(x"10"); -- CS low, CPU output direction
         poke(x"16"); -- CS rising, clock high
      end procedure;

      procedure send_byte(constant value : byte_t) is
         variable v : byte_t;
      begin
         for bit_index in 0 to 7 loop
            v := x"16"; v(0) := value(bit_index); poke(v);
            v(1) := '0'; poke(v);
         end loop;
      end procedure;

      procedure receive_byte(variable value : out byte_t) is
      begin
         for bit_index in 0 to 7 loop
            poke(x"06"); poke(x"04");
            value(bit_index) := dout(0);
         end loop;
      end procedure;

      procedure write_register(constant command : byte_t; constant data : bytes_t) is
      begin
         begin_serial; send_byte(command);
         for i in data'range loop send_byte(data(i)); end loop;
         poke(x"10");
      end procedure;

      procedure read_register(constant command : byte_t; variable data : out bytes_t) is
      begin
         begin_serial; send_byte(command);
         for i in data'range loop receive_byte(data(i)); end loop;
         poke(x"10");
      end procedure;

      procedure next_second is
         variable old : byte_t;
         variable guard : natural := 0;
      begin
         old := rtc_datetime(55 downto 48);
         while rtc_datetime(55 downto 48) = old loop
            cycles(1); guard := guard + 1;
            assert guard <= 8193 report "RTC clock did not advance" severity failure;
         end loop;
      end procedure;

      procedure expect_date(constant expected : std_logic_vector(55 downto 0); constant label_text : string) is
      begin
         assert rtc_datetime = expected
            report label_text & " got=" & to_hstring(rtc_datetime) & " expected=" & to_hstring(expected)
            severity failure;
      end procedure;
   begin
      cycles(3);
      expect_date(x"00000006010100", "FPGA initialization calendar");
      reset <= '0'; cycles(2);
      read_register(x"61", result(0 to 0));
      assert result(0) = x"82" report "unseeded native boot must expose power-loss status" severity failure;
      read_register(x"86", result(0 to 0));
      assert result(0) = x"02" report "unseeded cold flag must clear on status read" severity failure;
      reset <= '1'; cycles(2);
      toggle_before := date_written;
      seed(x"59592303280224"); -- 2024-02-28 Wed 23:59:59, while reset held
      expect_date(x"59592303280224", "seed accepted during reset");
      assert date_written = toggle_before report "host seed must not notify guest write" severity failure;
      reset <= '0'; cycles(2);
      read_register(x"61", result(0 to 0));
      assert result(0) = x"02" report "valid host seed must clear power-loss status" severity failure;
      read_register(x"86", result(0 to 0)); -- native LSB-first command form
      assert result(0) = x"02" report "seeded status must remain clear" severity failure;
      read_register(x"65", result);
      assert result = bytes_t'(x"24", x"02", x"28", x"03", x"63", x"59", x"59")
         report "serial full date or 24-hour PM bit differs" severity failure;
      next_second;
      expect_date(x"00000004290224", "leap day rollover");
      assert date_written = toggle_before report "elapsed seconds must not notify guest write" severity failure;

      seed(x"59592304290224"); next_second;
      expect_date(x"00000005010324", "leap February end");
      seed(x"59592306280226"); next_second;
      expect_date(x"00000000010326", "non-leap February end and weekday wrap");
      seed(x"59592303300426"); next_second;
      expect_date(x"00000004010526", "30-day month end");
      seed(x"59592305311299"); next_second;
      expect_date(x"00000006010100", "year 2099 wraps to 2000");
      seed(x"59592301280200"); next_second;
      expect_date(x"00000002290200", "2000 is a leap year");

      seed(x"56562304011026"); -- 2026-10-01 23:56:56
      before := rtc_datetime;
      reset <= '1'; cycles(10); reset <= '0'; cycles(2);
      expect_date(before, "native guest reset retains seeded date");
      read_register(x"61", result(0 to 0));
      assert result(0) = x"02" report "native guest reset must retain seed-valid status" severity failure;
      fw_boot <= '0'; reset <= '1'; cycles(10); reset <= '0'; cycles(2);
      expect_date(before, "guest reset retains date");
      read_register(x"61", result(0 to 0));
      assert result(0) = x"02" report "direct boot cold flag must be clear" severity failure;
      write_register(x"60", bytes_t'(0 => x"00")); -- 12-hour mode
      read_register(x"67", result(0 to 2));
      assert result(0 to 2) = bytes_t'(x"51", x"56", x"56") report "23:56 must read as 11 PM" severity failure;
      expect_date(before, "changing hour mode preserves canonical time");
      write_register(x"60", bytes_t'(0 => x"02"));
      read_register(x"67", result(0 to 2));
      assert result(0) = x"63" report "24h mode restoration wrong" severity failure;

      write_register(x"60", bytes_t'(0 => x"00"));
      toggle_before := date_written;
      write_register(x"66", bytes_t'(x"40", x"00", x"00")); -- noon in 12h wire form
      assert date_written /= toggle_before report "complete guest time write not notified" severity failure;
      expect_date(x"00001204011026", "12h noon decoded into canonical 12");
      read_register(x"67", result(0 to 2));
      assert result(0) = x"40" report "12h noon serial encoding wrong" severity failure;
      write_register(x"66", bytes_t'(x"00", x"00", x"00"));
      expect_date(x"00000004011026", "12h midnight decoded into canonical 0");
      seed(x"59592304011026"); next_second;
      expect_date(x"00000005021026", "midnight rollover while serial mode is 12h");
      read_register(x"67", result(0 to 2));
      assert result(0) = x"00" report "12h midnight wire encoding wrong" severity failure;

      -- Exercise every dynamic hour conversion after removing decimal divide.
      for h in 0 to 23 loop
         hour_bcd := std_logic_vector(to_unsigned((h / 10) * 16 + h mod 10, 8));
         hour_seed := x"00000004011026"; hour_seed(39 downto 32) := hour_bcd;
         seed(hour_seed);
         write_register(x"60", bytes_t'(0 => x"02"));
         read_register(x"67", result(0 to 2));
         hour_wire := hour_bcd;
         if h >= 12 then hour_wire(6) := '1'; end if;
         assert result(0) = hour_wire report "24h conversion failed for hour " & integer'image(h) severity failure;
         write_register(x"60", bytes_t'(0 => x"00"));
         read_register(x"67", result(0 to 2));
         hour_wire := std_logic_vector(to_unsigned(((h mod 12) / 10) * 16 + (h mod 12) mod 10, 8));
         if h >= 12 then hour_wire(6) := '1'; end if;
         assert result(0) = hour_wire report "12h conversion failed for hour " & integer'image(h) severity failure;
         write_register(x"66", bytes_t'(hour_wire, x"00", x"00"));
         assert rtc_datetime(39 downto 32) = hour_bcd report "12h CPU write conversion failed for hour " & integer'image(h) severity failure;
      end loop;

      write_register(x"60", bytes_t'(0 => x"02"));
      toggle_before := date_written;
      write_register(x"64", bytes_t'(x"26", x"02", x"29", x"00", x"23", x"59", x"59"));
      assert date_written /= toggle_before report "complete guest date write not notified" severity failure;
      expect_date(x"59592300010326", "non-leap invalid day advances month as melonDS");
      write_register(x"64", bytes_t'(x"FA", x"1A", x"32", x"07", x"24", x"60", x"6F"));
      expect_date(x"00000000010100", "invalid CPU BCD fields sanitized");
      write_register(x"64", bytes_t'(x"24", x"02", x"29", x"04", x"12", x"30", x"45"));
      expect_date(x"45301204290224", "valid guest leap date");
      read_register(x"A6", result);
      assert result = bytes_t'(x"24", x"02", x"29", x"04", x"52", x"30", x"45")
         report "direct command full-date read differs" severity failure;

      -- The native firmware writes single-byte status and free registers too.
      write_register(x"62", bytes_t'(0 => x"04"));
      read_register(x"63", result(0 to 0));
      assert result(0) = x"04" report "status2 storage failure" severity failure;
      write_register(x"68", bytes_t'(x"01", x"02", x"03"));
      read_register(x"69", result(0 to 2));
      assert result(0 to 2) = bytes_t'(x"01", x"02", x"03") report "alarm1 storage failure" severity failure;
      write_register(x"6E", bytes_t'(0 => x"5A"));
      read_register(x"6F", result(0 to 0));
      assert result(0) = x"5A" report "free register storage failure" severity failure;
      toggle_before := date_written;
      write_register(x"60", bytes_t'(0 => x"03"));
      expect_date(x"00000006010100", "RTC software reset calendar");
      assert date_written /= toggle_before report "RTC software reset not notified" severity failure;

      -- Data changes without a toggle cannot replace guest time.
      before := rtc_datetime; rtc_seed <= x"00000004011026"; cycles(6);
      expect_date(before, "seed data without toggle ignored");
      seed(x"99999999310299");
      expect_date(x"00000000010299", "host invalid fields and February day sanitized");
      toggle_before := date_written;
      ce <= '0'; before := rtc_datetime; cycles(9000);
      expect_date(before, "clock respects CE");
      assert date_written = toggle_before report "CE pause changed notification" severity failure;
      -- CDC capture itself is independent of CE.
      seed(x"00000804011026"); expect_date(x"00000804011026", "seed accepted while CE paused");
      ce <= '1'; cycles(2);
      bus7.Adr <= x"0000134"; cycles(1);
      assert done = '0' and dout = x"00000000" report "RTC leaks into other bus address" severity failure;
      report "PASS: native RTC GPIO, seed/reset, Gregorian rollovers, BCD validation, hour modes, write notifications" severity note;
      stop;
      wait;
   end process;
end architecture;
