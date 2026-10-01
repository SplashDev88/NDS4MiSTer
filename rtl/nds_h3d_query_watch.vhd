-- SPDX-License-Identifier: GPL-3.0-or-later
-- Passive query timing; no output feeds console execution or handshakes.
-- Counts clk1x cycles (33.513982 MHz). All cumulative counters wrap; the
-- longest completed uncached request saturates. See docs/query-wait-probe.md.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_h3d_query_watch is
   generic (
      COUNTER_BITS : positive := 28;
      PAGE_BITS : positive := 21
   );
   port (
      clk, reset : in std_logic;
      read_busy, request_valid, request_ready, complete : in std_logic;
      gpu_blocked : in std_logic;
      sample_data : out std_logic_vector(31 downto 0) := (others => '0');
      sample_toggle : out std_logic := '0'
   );
end entity;

architecture arch of nds_h3d_query_watch is
   subtype count_type is unsigned(COUNTER_BITS-1 downto 0);
   signal elapsed, busy_cycles, uncached_cycles, issue_cycles : count_type := (others => '0');
   signal requests_done, longest, cache_done, gpu_cycles : count_type := (others => '0');
   signal age : count_type := (others => '0');
   signal pending : std_logic := '0';
   signal page : unsigned(2 downto 0) := (others => '0');
   signal divider : unsigned(PAGE_BITS-1 downto 0) := (others => '0');
   signal toggle : std_logic := '0';
begin
   assert COUNTER_BITS <= 28 report "query-watch counter exceeds wire payload" severity failure;
   sample_toggle <= toggle;
   process(clk)
      variable value : count_type;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            elapsed <= (others => '0'); busy_cycles <= (others => '0');
            uncached_cycles <= (others => '0'); issue_cycles <= (others => '0');
            requests_done <= (others => '0'); longest <= (others => '0');
            cache_done <= (others => '0'); gpu_cycles <= (others => '0');
            age <= (others => '0'); pending <= '0';
            divider <= (others => '0'); page <= (others => '0');
            sample_data <= (others => '0'); toggle <= '0';
         else
            elapsed <= elapsed + 1;
            if read_busy = '1' then busy_cycles <= busy_cycles + 1; end if;
            if gpu_blocked = '1' then gpu_cycles <= gpu_cycles + 1; end if;
            if request_valid = '1' and request_ready = '0' then
               issue_cycles <= issue_cycles + 1;
            end if;

            -- Start at first ISSUE cycle, including source-gate backpressure.
            -- End on the CPU completion pulse, not on fence posting or the
            -- ARM's reply commit. Cache-only reads never set pending.
            if pending = '0' and request_valid = '1' then
               pending <= '1'; age <= to_unsigned(1, COUNTER_BITS);
               uncached_cycles <= uncached_cycles + 1;
            elsif pending = '1' and complete = '0' then
               uncached_cycles <= uncached_cycles + 1;
               if age /= (age'range => '1') then age <= age + 1; end if;
            end if;
            if complete = '1' then
               if pending = '1' then
                  requests_done <= requests_done + 1;
                  if age > longest then longest <= age; end if;
               else
                  cache_done <= cache_done + 1;
               end if;
               pending <= '0'; age <= (others => '0');
            end if;

            -- Each value is a cumulative snapshot at its own page boundary.
            -- Hold the entire bus until the next toggle (~62.6 ms in product).
            -- The receiver synchronizes only this toggle before capturing it.
            divider <= divider + 1;
            if divider = (divider'range => '1') then
               case to_integer(page) is
                  when 0 => value := elapsed;
                  when 1 => value := busy_cycles;
                  when 2 => value := uncached_cycles;
                  when 3 => value := issue_cycles;
                  when 4 => value := requests_done;
                  when 5 => value := longest;
                  when 6 => value := cache_done;
                  when others => value := gpu_cycles;
               end case;
               sample_data <= '1' & std_logic_vector(page) & std_logic_vector(resize(value,28));
               toggle <= not toggle;
               page <= page + 1;
            end if;
         end if;
      end if;
   end process;
end architecture;
