-- Fresh-process fixed-point IRQ restore. The continuation oracle is recorded
-- before reset from normal execution, never manufactured by a second restore.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_irq_restore is
   generic(RESTORING : boolean := false; SCENARIO : natural := 0; WRITE_ORDER : natural range 0 to 5 := 0);
end;
architecture sim of tb_nds_checkpoint_irq_restore is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal ce : std_logic := '1';
   signal bus_io : proc_bus_gb_type := ((others => '0'),(others => '0'),'1','0',ACCESS_32BIT,"0000",'1');
   signal irq_in : std_logic_vector(31 downto 0) := (others => '0');
   signal irq, unhalt, idle, valid, restore_ready, restore_error : std_logic;
   signal address : unsigned(1 downto 0) := (others => '0');
   signal restore, write_state : std_logic := '0';
   signal data, write_data, ime, ie, flags : std_logic_vector(31 downto 0) := (others => '0');
   function flags_for_scenario return unsigned is
   begin
      if SCENARIO = 5 then return to_unsigned(0,32); end if;
      return rotate_left(unsigned'(x"CA3500F1"), SCENARIO*7);
   end;
   function enable_for_scenario return unsigned is
   begin
      if SCENARIO = 4 then return to_unsigned(0,32); end if;
      return rotate_left(unsigned'(x"5A5A81C3"), SCENARIO*3);
   end;
   constant initial_flags : unsigned(31 downto 0) := flags_for_scenario;
   constant initial_enable : unsigned(31 downto 0) := enable_for_scenario;
   constant held_sources : std_logic_vector(31 downto 0) := std_logic_vector(initial_flags and x"CCC3C333");
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_irq generic map(EXPERIMENTAL_CHECKPOINT => true)
      port map(clk => clk, ce => ce, reset => reset, gb_bus => bus_io,
         wired_out => open, wired_done => open, irq_in => irq_in, cpu_irq => irq, cpu_unhalt => unhalt,
         dbg_ime => ime, dbg_ie => ie, dbg_if => flags, checkpoint_idle => idle,
         checkpoint_address => address, checkpoint_data => data, checkpoint_valid => valid,
         checkpoint_restore => restore, checkpoint_write => write_state, checkpoint_write_data => write_data,
         checkpoint_restore_ready => restore_ready, checkpoint_restore_error => restore_error);
   stimulus : process
      file state_file, trace_file : text;
      variable line_buffer : line;
      type image_t is array(0 to 2) of std_logic_vector(31 downto 0);
      variable image : image_t;
      type orders_t is array(0 to 5, 0 to 2) of natural;
      constant orders : orders_t := ((0,1,2),(0,2,1),(1,0,2),(1,2,0),(2,0,1),(2,1,0));
      variable expected, actual : std_logic_vector(99 downto 0);
      variable random : unsigned(31 downto 0) := to_unsigned(1234567+SCENARIO*7919,32);
      variable saved_flags : std_logic_vector(31 downto 0);
      procedure step(n : positive := 1) is
      begin for k in 1 to n loop wait until rising_edge(clk); wait for 1 ns; end loop; end;
      procedure guest_write(a : natural; value : std_logic_vector(31 downto 0)) is
      begin
         bus_io.Adr <= std_logic_vector(to_unsigned(a,28)); bus_io.Din <= value;
         bus_io.ena <= '1'; bus_io.rnw <= '0'; bus_io.bEna <= "1111";
         step; bus_io.ena <= '0'; step;
      end;
      procedure load_word(a : natural; value : std_logic_vector(31 downto 0)) is
      begin
         address <= to_unsigned(a,2); write_data <= value; write_state <= '1';
         step; write_state <= '0'; step(2+a);
      end;
      procedure read_image is
      begin
         for a in 0 to 2 loop
            address <= to_unsigned(a,2); wait for 1 ns;
            assert valid = '1' report "IRQ image unavailable at fixed point" severity failure;
            if RESTORING then assert data = image(a) report "IRQ restored word differs from captured image" severity failure;
            else image(a) := data; end if;
         end loop;
         address <= "11"; wait for 1 ns;
         assert valid = '0' and data = x"00000000" report "undefined IRQ word exposed state" severity failure;
      end;
      procedure continue_trace is
      begin
         for i in 0 to 512 loop
            actual := ime & ie & flags & "00" & irq & unhalt;
            if RESTORING then
               assert not endfile(trace_file) report "IRQ reference trace truncated" severity failure;
               readline(trace_file,line_buffer); hread(line_buffer,expected);
               assert actual = expected report "IRQ continuation mismatch at step " & integer'image(i) severity failure;
            else
               hwrite(line_buffer,actual); writeline(trace_file,line_buffer);
            end if;
            random := random xor shift_left(random,13);
            random := random xor shift_right(random,17);
            random := random xor shift_left(random,5);
            irq_in <= std_logic_vector(random);
            ce <= '1'; if i mod 7 = 0 then ce <= '0'; end if;
            bus_io.ena <= '0'; bus_io.rnw <= '0'; bus_io.bEna <= std_logic_vector(random(7 downto 4));
            bus_io.Din <= std_logic_vector(rotate_left(random,11));
            case i mod 5 is
               when 0 => bus_io.Adr <= std_logic_vector(to_unsigned(16#208#,28)); bus_io.ena <= '1';
               when 1 => bus_io.Adr <= std_logic_vector(to_unsigned(16#210#,28)); bus_io.ena <= '1';
               when 2 => bus_io.Adr <= std_logic_vector(to_unsigned(16#214#,28)); bus_io.ena <= '1';
               when others => null;
            end case;
            step;
         end loop;
         if RESTORING then assert endfile(trace_file) report "IRQ reference has trailing records" severity failure; end if;
      end;
   begin
      step(4);
      if RESTORING then
         file_open(state_file,"irq.state",read_mode);
         for a in 0 to 2 loop readline(state_file,line_buffer); hread(line_buffer,image(a)); end loop;
         assert endfile(state_file) report "unexpected IRQ image size" severity failure;
         file_close(state_file);
         restore <= '1'; step;
         -- Missing words cannot be accepted. Gaps while reset remains high
         -- must preserve all previously restored live registers.
         for slot in 0 to 2 loop
            load_word(orders(WRITE_ORDER,slot),image(orders(WRITE_ORDER,slot)));
            if slot < 2 then assert restore_ready = '0' report "incomplete IRQ restore accepted" severity failure; end if;
            step(5+slot);
         end loop;
         assert restore_ready = '1' and restore_error = '0' report "complete IRQ restore never became ready" severity failure;
         read_image;
         -- Reject unsupported words and reserved IME bits, poison the entire
         -- attempt, and require a fresh complete image after withdrawal.
         for invalid_case in 0 to 1 loop
            if invalid_case = 0 then load_word(3,x"00000000"); else load_word(0,x"00000002"); end if;
            assert restore_error = '1' and restore_ready = '0' and valid = '0' and data = x"00000000"
               report "invalid IRQ restore was not rejected" severity failure;
            load_word(0,image(0));
            assert restore_error = '1' and restore_ready = '0' report "invalid IRQ attempt silently recovered" severity failure;
            restore <= '0'; step; restore <= '1'; step;
            assert restore_ready = '0' report "new IRQ attempt retained old coverage" severity failure;
            for slot in 0 to 2 loop load_word(orders(WRITE_ORDER,slot),image(orders(WRITE_ORDER,slot))); end loop;
            assert restore_ready = '1' and restore_error = '0' report "fresh IRQ attempt failed" severity failure;
            read_image;
         end loop;
         irq_in <= held_sources;
         restore <= '0'; reset <= '0'; bus_io.rst <= '0'; step(2);
         -- Live writes on the checkpoint port are rejected without altering
         -- guest state. Ordinary IRQ processing remains the original path.
         saved_flags := flags;
         for a in 0 to 2 loop
            restore <= '1'; write_state <= '1'; address <= to_unsigned(a,2);
            if a = 0 then write_data <= (31 downto 1 => '0') & not image(0)(0);
            elsif a = 1 then write_data <= not image(1);
            else write_data <= (others => '0'); end if;
            step; write_state <= '0';
            assert restore_error = '1' and restore_ready = '0' and valid = '0' and
               flags = saved_flags and ime = image(0) and ie = image(1)
               report "checkpoint modified a running IRQ controller" severity failure;
            restore <= '0'; step;
         end loop;
         file_open(trace_file,"irq.trace",read_mode);
      else
         reset <= '0'; bus_io.rst <= '0'; step;
         guest_write(16#210#,std_logic_vector(initial_enable));
         guest_write(16#208#,std_logic_vector(to_unsigned(SCENARIO mod 2,32)));
         irq_in <= std_logic_vector(initial_flags); step(3);
         irq_in <= held_sources; step(3);
         assert idle = '1' report "capture did not reach IRQ fixed point" severity failure;
         read_image;
         file_open(state_file,"irq.state",write_mode);
         for a in 0 to 2 loop hwrite(line_buffer,image(a)); writeline(state_file,line_buffer); end loop;
         file_close(state_file);
         file_open(trace_file,"irq.trace",write_mode);
      end if;
      continue_trace; file_close(trace_file);
      report "CHECKPOINT_IRQ_RESTORE_PASS restoring=" & boolean'image(RESTORING) &
         " scenario=" & integer'image(SCENARIO) & " order=" & integer'image(WRITE_ORDER);
      std.env.stop; wait;
   end process;
   process begin wait for 1 ms; assert false report "IRQ restore watchdog" severity failure; end process;
end;
