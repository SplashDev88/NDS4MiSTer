-- SPDX-License-Identifier: GPL-3.0-or-later
-- Host metadata has already crossed as held data with delayed validity.
-- Validate it against the header actually read by the cartridge loader.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
entity nds_host_save_profile is
   port(clk, reset, start : in std_logic;
        game_code, host_code : in std_logic_vector(31 downto 0);
        host_valid : in std_logic;
        host_type : in std_logic_vector(3 downto 0);
        busy, valid : out std_logic := '0';
        save_type : out std_logic_vector(3 downto 0) := (others => '0');
        fault : out std_logic := '0');
end entity;
architecture rtl of nds_host_save_profile is
   signal publish_pending : std_logic := '0';
   signal nand16, nand8 : boolean;
begin
   nand16 <= game_code = x"45524F55" or game_code = x"50524F55" or game_code = x"4A524F55";
   nand8 <= game_code = x"50425855" or game_code = x"4A425841";
   busy <= publish_pending;
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            valid <= '0'; save_type <= (others => '0');
            fault <= '0'; publish_pending <= '0';
         elsif start = '1' then
            valid <= '0'; publish_pending <= '0';
            if host_valid = '1' and host_code = game_code and ((not nand16 and not nand8 and unsigned(host_type) <= 7) or
               (nand16 and host_type = x"9") or (nand8 and host_type = x"8")) then
               save_type <= host_type;
               publish_pending <= '1';
            else
               fault <= '1';
            end if;
         elsif publish_pending = '1' then
            -- Publish one cycle after the payload, matching the old ROM lookup.
            valid <= '1'; publish_pending <= '0';
         end if;
      end if;
   end process;
end architecture;
