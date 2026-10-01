-- SPDX-License-Identifier: GPL-3.0-or-later
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_h3d_query_watch is end;
architecture test of tb_nds_h3d_query_watch is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal busy, valid, ready, complete, blocked : std_logic := '0';
   signal data : std_logic_vector(31 downto 0);
   signal toggle : std_logic;
   signal checked : natural := 0;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_h3d_query_watch
      generic map (COUNTER_BITS => 8, PAGE_BITS => 3)
      port map (clk, reset, busy, valid, ready, complete, blocked, data, toggle);

   -- Infinite-precision reference totals with independent start/end timestamps.
   -- Small product-counter widths force many wraps and a saturated long query.
   scoreboard : process
      type totals_type is array(0 to 7) of natural;
      variable totals : totals_type := (others => 0);
      variable before : totals_type;
      variable start_cycle, duration, ticks, page : natural := 0;
      variable pending, previous_toggle : boolean := false;
      variable expected : std_logic_vector(31 downto 0) := (others => '0');
   begin
      wait until rising_edge(clk);
      if reset = '1' then
         totals := (others => 0); ticks := 0; page := 0;
         pending := false; previous_toggle := false;
         expected := (others => '0');
      else
         before := totals;
         if not pending and valid = '1' then
            start_cycle := ticks; pending := true;
         end if;
         if pending and complete = '1' then
            duration := ticks - start_cycle;
            totals(4) := totals(4) + 1;
            if duration > 255 then duration := 255; end if;
            if duration > totals(5) then totals(5) := duration; end if;
            pending := false;
         elsif complete = '1' then
            totals(6) := totals(6) + 1;
         end if;
         totals(0) := totals(0) + 1;
         if busy = '1' then totals(1) := totals(1) + 1; end if;
         if pending then totals(2) := totals(2) + 1; end if;
         if valid = '1' and ready = '0' then totals(3) := totals(3) + 1; end if;
         if blocked = '1' then totals(7) := totals(7) + 1; end if;
         ticks := ticks + 1;
         if ticks mod 8 = 0 then
            expected := std_logic_vector(to_unsigned(8 + page, 4)) &
                        std_logic_vector(to_unsigned(before(page) mod 256, 28));
            page := (page + 1) mod 8;
            previous_toggle := not previous_toggle;
            checked <= checked + 1;
         end if;
      end if;
      wait for 1 ns;
      assert data = expected report "torn, early, or incorrect probe snapshot" severity failure;
      assert (toggle = '1') = previous_toggle report "snapshot toggle cadence" severity failure;
   end process;

   stimulus : process
      procedure tick(b,v,r,c,g : std_logic; count : positive := 1) is
      begin
         for i in 1 to count loop
            wait until falling_edge(clk);
            busy <= b; valid <= v; ready <= r; complete <= c; blocked <= g;
         end loop;
      end;
      procedure query(post_wait, reply_wait : positive) is
      begin
         tick('1','1','0','0','1',post_wait);
         tick('1','1','1','0','0');
         tick('1','0','0','0','0',reply_wait);
         tick('0','0','0','1','0');
         tick('0','0','0','0','0',3);
      end;
   begin
      tick('0','0','0','0','0',3); reset <= '0';
      query(37,157);
      for i in 1 to 30 loop
         query(1 + (i*7 mod 17), 1 + (i*31 mod 199));
         tick('1','0','0','0','1',2); -- local cache read, no fence
         tick('0','0','0','1','0');
         tick('0','0','0','0','0',2);
      end loop;
      query(73,303); -- saturates latency, cumulative counters still wrap
      tick('0','0','0','0','0',80);
      -- Reset abandons a pending query; its old start must not survive.
      tick('1','1','0','0','1',7);
      reset <= '1'; tick('0','0','0','0','0',3); reset <= '0';
      query(2,4); tick('0','0','0','0','0',80);
      assert checked > 400 report "insufficient wrap/page coverage" severity failure;
      report "PASS query timing: backpressure, cache hits, delayed replies, wraps, saturation, reset";
      finish;
   end process;
end architecture;
