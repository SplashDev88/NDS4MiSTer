-- Record a normal timer continuation, then compare it after loading the held
-- component into a fresh simulator process. No internal state is forced.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_timer_restore is
   generic(RESTORING : boolean := false; PRESCALER : natural range 0 to 3 := 0;
      SCENARIO : natural range 0 to 5 := 0; WRITE_ORDER : natural range 0 to 2 := 0);
end;
architecture sim of tb_nds_checkpoint_timer_restore is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal ce : std_logic := '1';
   signal bus_io : proc_bus_gb_type := ((others => '0'),(others => '0'),'1','0',ACCESS_32BIT,"0000",'1');
   constant idle_bus : proc_bus_gb_type := ((others => '0'),(others => '0'),'1','0',ACCESS_32BIT,"0000",'0');
   signal stopped, stop_count, valid, restore_ready, restore_error : std_logic := '0';
   signal address : unsigned(3 downto 0) := (others => '0');
   signal restore, write_state : std_logic := '0';
   signal data, write_data, read_data : std_logic_vector(31 downto 0) := (others => '0');
   signal done, tick0, tick1 : std_logic;
   signal irq : std_logic_vector(3 downto 0);
   signal debug0, debug1, debug2, debug3 : unsigned(15 downto 0);
begin
   clk <= not clk after 5 ns;
   dut : entity work.gba_timer generic map(is_simu => '1',EXPERIMENTAL_CHECKPOINT => true)
      port map(clk => clk, ce => ce, reset => reset, gb_bus => bus_io,
         savestate_bus => idle_bus, ss_wired_out => open, ss_wired_done => open, loading_savestate => '0',
         wired_out => read_data, wired_done => done, IRP_Timer => irq, timer0_tick => tick0, timer1_tick => tick1,
         debugout0 => debug0, debugout1 => debug1, debugout2 => debug2, debugout3 => debug3,
         checkpoint_stop => stop_count, checkpoint_stopped => stopped,
         checkpoint_address => address, checkpoint_data => data, checkpoint_valid => valid,
         checkpoint_restore => restore, checkpoint_write => write_state, checkpoint_write_data => write_data,
         checkpoint_restore_ready => restore_ready, checkpoint_restore_error => restore_error);
   stimulus : process
      file state_file, trace_file : text;
      variable line_buffer : line;
      type image_t is array(0 to 12) of std_logic_vector(31 downto 0);
      variable image : image_t;
      variable expected, actual : std_logic_vector(103 downto 0);
      variable random : unsigned(31 downto 0) := to_unsigned(1234567+SCENARIO*7919+PRESCALER*65537,32);
      variable ticks : natural := 0;
      procedure step(n : positive := 1) is
      begin
         for k in 1 to n loop
            wait until rising_edge(clk); wait for 1 ns;
            if restore = '1' and reset = '1' then
               assert irq = "0000" and tick0 = '0' and tick1 = '0'
                  report "timer event escaped reset-held restore" severity failure;
            end if;
         end loop;
      end;
      procedure guest_write(a : natural; value : std_logic_vector(31 downto 0)) is
      begin
         bus_io.Adr <= std_logic_vector(to_unsigned(a,28)); bus_io.Din <= value;
         bus_io.ena <= '1'; bus_io.rnw <= '0'; bus_io.bEna <= "1111";
         step; bus_io.ena <= '0'; step;
      end;
      procedure load_word(a : natural; value : std_logic_vector(31 downto 0)) is
      begin
         address <= to_unsigned(a,4); write_data <= value; write_state <= '1';
         step; write_state <= '0'; step(2+a mod 3);
      end;
      procedure load_image is
         variable a : natural;
      begin
         for slot in 0 to 12 loop
            case WRITE_ORDER is
               when 0 => a := slot;
               when 1 => a := 12-slot;
               when others => a := (slot*5) mod 13;
            end case;
            load_word(a,image(a));
            if slot < 12 then assert restore_ready = '0' report "incomplete timer restore accepted" severity failure; end if;
         end loop;
         step(3);
         assert restore_ready = '1' and restore_error = '0' report "complete timer restore never became ready" severity failure;
      end;
      procedure read_image(compare : boolean) is
      begin
         for a in 0 to 12 loop
            address <= to_unsigned(a,4); wait for 1 ns;
            assert valid = '1' report "timer image unavailable at held boundary" severity failure;
            if compare then assert data = image(a) report "timer restored word differs at " & integer'image(a) severity failure;
            else image(a) := data; end if;
         end loop;
         for a in 13 to 15 loop
            address <= to_unsigned(a,4); wait for 1 ns;
            assert valid = '0' and data = x"00000000" report "undefined timer word exposed state" severity failure;
         end loop;
      end;
   begin
      step(4);
      if RESTORING then
         file_open(state_file,"timer.state",read_mode);
         for a in 0 to 12 loop readline(state_file,line_buffer); hread(line_buffer,image(a)); end loop;
         assert endfile(state_file) report "unexpected timer image size" severity failure;
         file_close(state_file);
         restore <= '1'; step;
         load_image; read_image(true);
         for invalid_case in 0 to 5 loop
            case invalid_case is
               when 0 | 1 | 2 => load_word(13+invalid_case,x"00000000");
               when 3 => load_word(0,x"00000400");
               when 4 => load_word(1,x"00080000");
               when others => load_word(3,x"00000004");
            end case;
            assert restore_error = '1' and restore_ready = '0' and valid = '0' and data = x"00000000"
               report "invalid timer restore was not rejected" severity failure;
            load_word(0,image(0));
            assert restore_error = '1' and restore_ready = '0' report "invalid timer attempt silently recovered" severity failure;
            restore <= '0'; step; restore <= '1'; step;
            assert restore_ready = '0' report "new timer attempt retained old coverage" severity failure;
            load_image; read_image(true);
         end loop;
         stop_count <= '1'; restore <= '0'; reset <= '0'; bus_io.rst <= '0'; step(4);
         -- Live checkpoint writes are rejected even while the timer is held.
         -- The complete unchanged image is checked after each attempted word.
         for a in 0 to 12 loop
            restore <= '1'; write_state <= '1'; address <= to_unsigned(a,4); write_data <= (others => '0');
            step; write_state <= '0';
            assert restore_error = '1' and restore_ready = '0' and valid = '0'
               report "live timer restore was not rejected" severity failure;
            restore <= '0'; step(3); read_image(true);
         end loop;
         file_open(trace_file,"timer.trace",read_mode);
      else
         reset <= '0'; bus_io.rst <= '0';
         if SCENARIO = 5 then stop_count <= '1'; end if;
         step;
         if SCENARIO /= 5 then
            guest_write(16#104#,x"00C4FFFD");
            guest_write(16#108#,std_logic_vector(to_unsigned(16#00C0FFFD#+((PRESCALER+1) mod 4)*65536,32)));
            guest_write(16#10C#,x"00C4FFFE");
            if SCENARIO = 2 then stop_count <= '1'; guest_write(16#100#,x"00C0FFFF");
            else guest_write(16#100#,std_logic_vector(to_unsigned(16#00C0FFFE#+PRESCALER*65536,32))); end if;
            case SCENARIO is
               when 0 => step(123+PRESCALER*7);
               when 1 =>
                  for k in 1 to 10000 loop exit when tick0 = '1'; step; end loop;
                  assert tick0 = '1' report "fixture missed pending timer overflow" severity failure;
               when 2 => null; -- stop before startwait retires
               when 3 => step(157); guest_write(16#100#,x"00401234");
               when 4 =>
                  step(157); reset <= '1'; bus_io.rst <= '1'; step(4);
                  reset <= '0'; bus_io.rst <= '0';
               when others => null;
            end case;
         end if;
         stop_count <= '1'; step(4);
         assert stopped = '1' report "capture did not reach timer boundary" severity failure;
         read_image(false);
         if SCENARIO = 2 then assert image(3)(1) = '1' report "fixture lacks pending timer start" severity failure; end if;
         if SCENARIO = 4 then assert image(2)(15 downto 0) /= image(2)(31 downto 16) report "fixture lacks distinct counter readback" severity failure; end if;
         if SCENARIO = 5 then
            for a in 0 to 12 loop assert image(a) = x"00000000" report "fixture lacks all-zero timer state" severity failure; end loop;
         end if;
         file_open(state_file,"timer.state",write_mode);
         for a in 0 to 12 loop hwrite(line_buffer,image(a)); writeline(state_file,line_buffer); end loop;
         file_close(state_file);
         file_open(trace_file,"timer.trace",write_mode);
      end if;
      bus_io.Adr <= std_logic_vector(to_unsigned(16#100#,28)); bus_io.ena <= '0';
      bus_io.rnw <= '1'; bus_io.bEna <= "1111"; bus_io.Din <= (others => '0');
      address <= (others => '0'); stop_count <= '0'; wait for 1 ns;
      assert valid = '0' and data = x"00000000" report "running timer exposed a checkpoint" severity failure;
      -- Include the first combinational overflow/cascade before a resumed edge,
      -- then long prescaler runs and byte writes with clock-enable stalls.
      for i in 0 to 8704 loop
         actual := read_data & std_logic_vector(debug0 & debug1 & debug2 & debug3) & '0' & done & irq & tick0 & tick1;
         if RESTORING then
            assert not endfile(trace_file) report "timer reference trace truncated" severity failure;
            readline(trace_file,line_buffer); hread(line_buffer,expected);
            assert actual = expected report "timer continuation mismatch at step " & integer'image(i) &
               " actual=" & to_hstring(actual) & " expected=" & to_hstring(expected) severity failure;
         else hwrite(line_buffer,actual); writeline(trace_file,line_buffer); end if;
         if tick0 = '1' and ce = '1' then ticks := ticks+1; end if;
         random := random xor shift_left(random,13); random := random xor shift_right(random,17); random := random xor shift_left(random,5);
         ce <= '1'; if i mod 7 = 0 then ce <= '0'; end if;
         bus_io.Adr <= std_logic_vector(to_unsigned(16#100#+(i mod 4)*4,28));
         bus_io.ena <= '0'; bus_io.rnw <= '1';
         if i >= 8192 then
            bus_io.bEna <= std_logic_vector(random(7 downto 4)); bus_io.Din <= std_logic_vector(random);
            if i mod 3 = 0 then bus_io.ena <= '1'; bus_io.rnw <= '0'; end if;
         end if;
         step;
      end loop;
      if SCENARIO < 3 then assert ticks >= 2 report "timer trace lacks repeated overflow" severity failure; end if;
      if RESTORING then assert endfile(trace_file) report "timer reference has trailing records" severity failure; end if;
      file_close(trace_file);
      report "CHECKPOINT_TIMER_RESTORE_PASS restoring=" & boolean'image(RESTORING) &
         " prescaler=" & integer'image(PRESCALER) & " scenario=" & integer'image(SCENARIO) &
         " order=" & integer'image(WRITE_ORDER) & " ticks=" & integer'image(ticks);
      std.env.stop; wait;
   end process;
   process begin wait for 1 ms; assert false report "timer restore watchdog" severity failure; end process;
end;
