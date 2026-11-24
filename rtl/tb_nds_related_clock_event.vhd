-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pulse/toggle delivery, held payload settling, and reset cancellation across
-- every input arrival phase. Includes the coincident related-clock edges.
library ieee;
use ieee.std_logic_1164.all;
entity tb_nds_related_clock_event is end;
architecture test of tb_nds_related_clock_event is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal event_in, toggle_in, pulse, toggled : std_logic := '0';
   signal payload : natural := 0;
   signal pulse_count, toggle_count : natural := 0;
   signal expected : natural := 0;
begin
   clk <= not clk after 5 ns;
   p : entity work.nds_related_clock_event
      port map(clk=>clk, reset=>reset, event_in(0)=>event_in, pulse_out(0)=>pulse);
   t : entity work.nds_related_clock_event
      generic map(TOGGLE_EVENT=>true)
      port map(clk=>clk, reset=>reset, event_in(0)=>toggle_in, pulse_out(0)=>toggled);
   process(clk)
   begin
      if rising_edge(clk) and reset='0' then
         if pulse='1' then
            assert payload=expected report "pulse retired before payload settled" severity failure;
            pulse_count<=pulse_count+1;
         end if;
         if toggled='1' then
            assert payload=expected report "toggle retired before payload settled" severity failure;
            toggle_count<=toggle_count+1;
         end if;
      end if;
   end process;
   process
      variable pc,tc : natural;
   begin
      wait for 40 ns; reset<='0';
      for phase in 0 to 19 loop
         for transaction in 1 to 8 loop
            wait until falling_edge(clk); wait for phase*500 ps;
            pc:=pulse_count; tc:=toggle_count;
            expected<=phase*8+transaction;
            event_in<='1'; toggle_in<=not toggle_in;
            -- Payload may trail the event by 9 ns; the receiver must wait.
            wait for 9 ns; payload<=phase*8+transaction;
            wait for 11 ns; event_in<='0';
            wait for 40 ns;
            assert pulse_count=pc+1 and toggle_count=tc+1
               report "lost or duplicated event" severity failure;
         end loop;
      end loop;
      -- Reset while an event is in the first capture stage, held at either
      -- level. No stale transaction may escape after reset is released.
      for level in std_logic range '0' to '1' loop
         for phase in 0 to 19 loop
            reset<='1'; event_in<=not level; toggle_in<=not level;
            wait for 40 ns; reset<='0';
            wait until falling_edge(clk); wait for phase*500 ps;
            event_in<=level; toggle_in<=level;
            wait for 2 ns; reset<='1';
            pc:=pulse_count; tc:=toggle_count;
            wait for 40 ns; reset<='0'; wait for 50 ns;
            assert pulse_count=pc and toggle_count=tc
               report "reset manufactured a completion" severity failure;
         end loop;
      end loop;
      report "PASS: 160 pulse/toggle payload checks and 40 reset arrival phases" severity note;
      std.env.stop; wait;
   end process;
end;
