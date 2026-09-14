-- SPDX-License-Identifier: GPL-3.0-or-later
-- Passive completed-write counters for private streamed-audio diagnosis.
-- Request metadata is latched: the live bus may already hold the next request
-- when a completion is observed. No output participates in any bus handshake.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_sound_stream_watch is
   generic (
      WINDOW0_FIRST_WORD : natural := 0;
      WINDOW0_WORDS : positive := 1;
      WINDOW1_FIRST_WORD : natural := 1;
      WINDOW1_WORDS : positive := 1
   );
   port (
      clk, reset : in std_logic;
      permit9, req9, rnw9, done9 : in std_logic;
      addr9 : in std_logic_vector(21 downto 2);
      be9 : in std_logic_vector(3 downto 0);
      permit7, req7, rnw7, done7 : in std_logic;
      addr7 : in std_logic_vector(21 downto 2);
      be7 : in std_logic_vector(3 downto 0);
      diagnostic : out std_logic_vector(63 downto 0)
   );
end entity;

architecture passive of nds_sound_stream_watch is
   signal bytes9, bytes7 : unsigned(27 downto 0) := (others => '0');
   signal pending9, pending7 : unsigned(2 downto 0) := (others => '0');
   function selected_bytes(permit, rnw : std_logic;
      addr : std_logic_vector(21 downto 2);
      be : std_logic_vector(3 downto 0)) return unsigned is
      variable a : natural;
      variable n : unsigned(2 downto 0) := (others => '0');
   begin
      if permit = '1' and rnw = '0' then
         a := to_integer(unsigned(addr));
         if (a >= WINDOW0_FIRST_WORD and a < WINDOW0_FIRST_WORD + WINDOW0_WORDS) or
            (a >= WINDOW1_FIRST_WORD and a < WINDOW1_FIRST_WORD + WINDOW1_WORDS) then
            for i in 0 to 3 loop
               if be(i) = '1' then n := n + 1; end if;
            end loop;
         end if;
      end if;
      return n;
   end function;
begin
   diagnostic <= x"E" & std_logic_vector(bytes9) & x"F" & std_logic_vector(bytes7);
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            bytes9 <= (others => '0'); bytes7 <= (others => '0');
            pending9 <= (others => '0'); pending7 <= (others => '0');
         else
            if done9 = '1' then
               bytes9 <= bytes9 + resize(pending9, bytes9'length);
               pending9 <= (others => '0');
            end if;
            if done7 = '1' then
               bytes7 <= bytes7 + resize(pending7, bytes7'length);
               pending7 <= (others => '0');
            end if;
            -- A simultaneous completion retires the old metadata above, then
            -- the new request replaces it. Excluded accesses also replace it.
            if req9 = '1' then pending9 <= selected_bytes(permit9, rnw9, addr9, be9); end if;
            if req7 = '1' then pending7 <= selected_bytes(permit7, rnw7, addr7, be7); end if;
         end if;
      end if;
   end process;
end architecture;
