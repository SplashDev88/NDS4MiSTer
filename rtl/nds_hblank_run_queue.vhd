-- SPDX-License-Identifier: GPL-3.0-or-later
-- Store regular scanline runs implicitly and retain every discontinuity.
-- Expansion preserves each source timestamp, line and display-frame number.
-- Only received pulses increase the count; no future event is synthesized.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_hblank_run_queue is
   generic (
      LINE_CYCLES : positive := 2130;
      LAST_LINE : natural := 262;
      BOUNDARY_ADDRESS_BITS : positive := 9;
      EVENT_INDEX_BITS : positive := 17
   );
   port (
      clk, reset, service_ready : in std_logic;
      source_pulse : in std_logic;
      source_line : in std_logic_vector(8 downto 0);
      source_frame : in std_logic_vector(31 downto 0);
      source_timestamp : in std_logic_vector(63 downto 0);
      event_valid : out std_logic;
      event_ready : in std_logic;
      event_line : out std_logic_vector(8 downto 0);
      event_frame : out std_logic_vector(31 downto 0);
      event_timestamp : out std_logic_vector(63 downto 0);
      pending_level : out std_logic_vector(EVENT_INDEX_BITS - 1 downto 0);
      fault : out std_logic
   );
end entity;

architecture arch of nds_hblank_run_queue is
   subtype event_data is std_logic_vector(104 downto 0);
   constant DEPTH : positive := 2 ** BOUNDARY_ADDRESS_BITS;
   constant MAX_PENDING : unsigned(EVENT_INDEX_BITS - 1 downto 0) := (others => '1');
   type boundary_memory is array (0 to DEPTH - 1) of
      std_logic_vector(104 + EVENT_INDEX_BITS downto 0);
   signal boundaries : boundary_memory;
   attribute ramstyle : string;
   attribute ramstyle of boundaries : signal is "M10K, no_rw_check";
   signal boundary_head : std_logic_vector(104 + EVENT_INDEX_BITS downto 0);
   signal read_pointer, write_pointer : unsigned(BOUNDARY_ADDRESS_BITS - 1 downto 0) := (others => '0');
   signal boundary_count : unsigned(BOUNDARY_ADDRESS_BITS downto 0) := (others => '0');
   signal count, head_index, next_index : unsigned(EVENT_INDEX_BITS - 1 downto 0) := (others => '0');
   signal predicted_head, predicted_tail : event_data := (others => '0');
   signal source_data, head_data : event_data;
   signal use_boundary, pop, need_push, irregular, push, boundary_pop, boundary_push : std_logic;
   signal fault_i : std_logic := '0';

   function successor(d : event_data) return event_data is
      variable r : event_data;
   begin
      r(104 downto 41) := std_logic_vector(unsigned(d(104 downto 41)) + LINE_CYCLES);
      if unsigned(d(8 downto 0)) = LAST_LINE then
         r(8 downto 0) := (others => '0');
         r(40 downto 9) := std_logic_vector(unsigned(d(40 downto 9)) + 1);
      else
         r(8 downto 0) := std_logic_vector(unsigned(d(8 downto 0)) + 1);
         r(40 downto 9) := d(40 downto 9);
      end if;
      return r;
   end function;
begin
   assert EVENT_INDEX_BITS > BOUNDARY_ADDRESS_BITS
      report "event capacity must exceed boundary capacity" severity failure;
   assert LAST_LINE < 512 report "invalid final scanline" severity failure;
   source_data <= source_timestamp & source_frame & source_line;
   boundary_head <= boundaries(to_integer(read_pointer));
   use_boundary <= '1' when boundary_count /= 0 and
      boundary_head(104 + EVENT_INDEX_BITS downto 105) = std_logic_vector(head_index) else '0';
   head_data <= boundary_head(104 downto 0) when use_boundary = '1' else predicted_head;
   event_valid <= '1' when service_ready = '1' and (count /= 0 or source_pulse = '1') else '0';
   event_line <= head_data(8 downto 0) when count /= 0 else source_line;
   event_frame <= head_data(40 downto 9) when count /= 0 else source_frame;
   event_timestamp <= head_data(104 downto 41) when count /= 0 else source_timestamp;
   pending_level <= std_logic_vector(count);
   fault <= fault_i;

   pop <= '1' when service_ready = '1' and count /= 0 and event_ready = '1' else '0';
   need_push <= '1' when service_ready = '1' and source_pulse = '1' and
      (count /= 0 or event_ready = '0') else '0';
   irregular <= '1' when count /= 0 and source_data /= predicted_tail else '0';
   boundary_pop <= pop and use_boundary;
   push <= '1' when need_push = '1' and (count /= MAX_PENDING or pop = '1') and
      (irregular = '0' or boundary_count /= DEPTH or boundary_pop = '1') else '0';
   boundary_push <= push and irregular;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            fault_i <= '0';
         elsif need_push = '1' and push = '0' then
            fault_i <= '1';
         end if;
         if reset = '1' or service_ready = '0' then
            count <= (others => '0');
            head_index <= (others => '0');
            next_index <= (others => '0');
            boundary_count <= (others => '0');
            read_pointer <= (others => '0');
            write_pointer <= (others => '0');
         else
            -- An empty queue bypasses directly. A newly retained first event
            -- seeds a new run; stale RAM is unreachable until a boundary push.
            if count = 0 then
               boundary_count <= (others => '0');
               read_pointer <= (others => '0');
               write_pointer <= (others => '0');
               if push = '1' then
                  count <= to_unsigned(1, count'length);
                  head_index <= (others => '0');
                  next_index <= to_unsigned(1, next_index'length);
                  predicted_head <= source_data;
                  predicted_tail <= successor(source_data);
               end if;
            else
               case std_logic_vector'(push & pop) is
                  when "10" => count <= count + 1;
                  when "01" => count <= count - 1;
                  when others => null;
               end case;
               if pop = '1' then
                  head_index <= head_index + 1;
                  predicted_head <= successor(head_data);
               end if;
               if push = '1' then
                  next_index <= next_index + 1;
                  predicted_tail <= successor(source_data);
               end if;
               if boundary_push = '1' then
                  boundaries(to_integer(write_pointer)) <= std_logic_vector(next_index) & source_data;
                  write_pointer <= write_pointer + 1;
               end if;
               if boundary_pop = '1' then
                  read_pointer <= read_pointer + 1;
               end if;
               case std_logic_vector'(boundary_push & boundary_pop) is
                  when "10" => boundary_count <= boundary_count + 1;
                  when "01" => boundary_count <= boundary_count - 1;
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;
end architecture;
