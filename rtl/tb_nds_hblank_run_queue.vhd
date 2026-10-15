library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_hblank_run_queue is
   generic (BOUNDARY_BITS : positive := 3; INDEX_BITS : positive := 6);
end entity;

architecture sim of tb_nds_hblank_run_queue is
   signal clk, reset, active, pulse, ready, valid, fault : std_logic := '0';
   signal src_line, dst_line : std_logic_vector(8 downto 0) := (others => '0');
   signal src_frame, dst_frame : std_logic_vector(31 downto 0) := (others => '0');
   signal src_time, dst_time : std_logic_vector(63 downto 0) := (others => '0');
   signal level : std_logic_vector(INDEX_BITS-1 downto 0);
begin
   dut : entity work.nds_hblank_run_queue
      generic map(BOUNDARY_ADDRESS_BITS => BOUNDARY_BITS, EVENT_INDEX_BITS => INDEX_BITS)
      port map(clk => clk, reset => reset, service_ready => active,
         source_pulse => pulse, source_line => src_line, source_frame => src_frame,
         source_timestamp => src_time, event_valid => valid, event_ready => ready,
         event_line => dst_line, event_frame => dst_frame, event_timestamp => dst_time,
         pending_level => level, fault => fault);

   stimulus : process
      constant DEPTH : positive := 2 ** BOUNDARY_BITS;
      constant MAX_PENDING : positive := 2 ** INDEX_BITS - 1;
      constant MODEL_SIZE : positive := MAX_PENDING + 16;
      type datum is record
         line : std_logic_vector(8 downto 0);
         frame : std_logic_vector(31 downto 0);
         stamp : std_logic_vector(63 downto 0);
      end record;
      type model_array is array(0 to MODEL_SIZE - 1) of datum;
      variable model : model_array;
      variable rd, wr, used : natural := 0;
      variable checks, step : natural := 0;
      variable sticky : boolean := false;
      variable seed : unsigned(31 downto 0) := x"a517c239";

      -- Independently generated literal event stream. The oracle stores every
      -- event verbatim; it does not implement compression or a successor rule.
      function regular(i : natural) return datum is
         variable d : datum;
         variable frame : unsigned(31 downto 0) := x"fffffffe";
         variable stamp : unsigned(63 downto 0) := x"fffffffffff80000";
      begin
         d.line := std_logic_vector(to_unsigned((i + 260) mod 263, 9));
         frame := frame + ((i + 260) / 263);
         d.frame := std_logic_vector(frame);
         stamp := stamp + to_unsigned(i * 2130, 64);
         d.stamp := std_logic_vector(stamp);
         return d;
      end function;

      function discontinuous(i : natural) return datum is
         variable d : datum;
      begin
         d.line := std_logic_vector(to_unsigned((i * 37) mod 512, 9));
         d.frame := std_logic_vector(to_unsigned(i * 13, 32));
         d.stamp := std_logic_vector(to_unsigned(i * 4097, 64));
         return d;
      end function;

      procedure tick(d : datum; send, take : boolean;
                     reset_now : boolean := false; enabled : boolean := true;
                     drop_now : boolean := false) is
         variable expected : datum;
         variable had_queued, bypass : boolean;
      begin
         step := step + 1;
         clk <= '0'; reset <= '0'; active <= '0'; pulse <= '0'; ready <= '0';
         if reset_now then reset <= '1'; end if;
         if enabled then active <= '1'; end if;
         if send then pulse <= '1'; end if;
         if take then ready <= '1'; end if;
         src_line <= d.line; src_frame <= d.frame; src_time <= d.stamp;
         wait for 5 ns;
         assert to_integer(unsigned(level)) = used report "pending level at step " & integer'image(step) severity failure;
         if not reset_now then
            assert (valid = '1') = (enabled and (used /= 0 or send))
               report "valid at step " & integer'image(step) severity failure;
            if valid = '1' then
               if used /= 0 then expected := model(rd); else expected := d; end if;
               assert dst_line = expected.line and dst_frame = expected.frame and dst_time = expected.stamp
                  report "event data mismatch at step " & integer'image(step) &
                     " got line=" & integer'image(to_integer(unsigned(dst_line))) &
                     " expected line=" & integer'image(to_integer(unsigned(expected.line))) severity failure;
               checks := checks + 1;
            end if;
         end if;
         if reset_now or not enabled then
            used := 0; rd := 0; wr := 0;
            if reset_now then sticky := false; end if;
         else
            had_queued := used /= 0;
            bypass := not had_queued and send and take;
            if had_queued and take then rd := (rd + 1) mod MODEL_SIZE; used := used - 1; end if;
            if send and not bypass and not drop_now then
               model(wr) := d; wr := (wr + 1) mod MODEL_SIZE; used := used + 1;
            end if;
            if drop_now then sticky := true; end if;
         end if;
         clk <= '1'; wait for 5 ns;
         assert to_integer(unsigned(level)) = used report "updated level at step " & integer'image(step) severity failure;
         assert (fault = '1') = sticky report "sticky fault at step " & integer'image(step) severity failure;
      end procedure;

      procedure clear is
      begin
         tick(regular(0), false, false, reset_now => true);
      end procedure;

      procedure drain is
      begin
         while used /= 0 loop tick(regular(0), false, true); end loop;
         tick(regular(0), false, true);
      end procedure;

      variable n, index : natural;
      variable send, take : boolean;
      variable d : datum;
   begin
      clear;
      for i in 0 to 1000 loop tick(regular(i), true, true); end loop;
      report "BYPASS_PASS";

      n := 4096;
      if n > MAX_PENDING - 3 then n := MAX_PENDING - 3; end if;
      for i in 0 to n - 1 loop tick(regular(i), true, false); end loop;
      -- Irregular data cannot disturb an already asserted held head.
      for i in 0 to 9 loop tick(discontinuous(i), false, false); end loop;
      drain;
      report "LONG_REGULAR_AND_WRAP_PASS events=" & integer'image(n);

      clear;
      -- Every entry after the first consumes a discontinuity descriptor.
      for i in 0 to DEPTH loop tick(discontinuous(i), true, false); end loop;
      tick(regular(0), false, true); -- first head has no descriptor
      -- Full ring: read the old descriptor and replace that address on the
      -- same edge. Downstream must receive the old value, exactly once.
      tick(discontinuous(DEPTH + 1), true, true);
      tick(discontinuous(DEPTH + 2), true, false, drop_now => true);
      drain;
      tick(regular(0), false, false, enabled => false);
      assert fault = '1' report "service stop incorrectly cleared sticky overflow" severity failure;
      clear;
      report "IRREGULAR_CAPACITY_AND_REFILL_PASS";

      -- Capacity is independently bounded even when no descriptors are used.
      for i in 0 to MAX_PENDING - 1 loop tick(regular(i), true, false); end loop;
      tick(regular(MAX_PENDING), true, true); -- full simultaneous pop/push
      tick(regular(MAX_PENDING + 1), true, false, drop_now => true);
      drain;
      clear;
      report "EVENT_CAPACITY_PASS";

      -- Keep a live tail through multiple modular index/ring wraps, mixing
      -- repeats, skipped lines, frame jumps, time gaps and ordinary runs.
      for i in 0 to 4 loop tick(regular(i), true, false); end loop;
      for i in 5 to 2 ** INDEX_BITS + 100 loop
         if i mod 17 = 0 then d := discontinuous(i); else d := regular(i); end if;
         tick(d, true, true);
      end loop;
      drain;
      report "INDEX_WRAP_AND_MIXED_REFILL_PASS";

      -- Deterministic randomized source/sink stalls; cap occupancy below the
      -- worst-case descriptor capacity so every input must survive.
      clear; index := 0;
      for i in 0 to 20000 loop
         seed := seed xor shift_left(seed, 13);
         seed := seed xor shift_right(seed, 17);
         seed := seed xor shift_left(seed, 5);
         send := seed(0) = '1' and used < DEPTH - 1;
         take := seed(1) = '1';
         if seed(4 downto 2) = "000" then d := discontinuous(index); else d := regular(index); end if;
         tick(d, send, take);
         if send then index := index + 1; end if;
      end loop;
      drain;
      report "RANDOM_STALLS_PASS";

      for i in 0 to 4 loop tick(discontinuous(i), true, false); end loop;
      tick(discontinuous(5), true, false, enabled => false);
      tick(discontinuous(6), true, false, enabled => false);
      tick(regular(9), true, false);
      drain;
      for i in 0 to 4 loop tick(discontinuous(i), true, false); end loop;
      clear;
      tick(regular(19), true, false); drain;
      report "HBLANK_RUN_QUEUE_PASS checks=" & integer'image(checks) &
         " boundary_bits=" & integer'image(BOUNDARY_BITS) & " index_bits=" & integer'image(INDEX_BITS);
      stop;
      wait;
   end process;
end architecture;
