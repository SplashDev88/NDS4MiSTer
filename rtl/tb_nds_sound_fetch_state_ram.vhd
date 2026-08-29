-- Simulation-only portable stand-in for the vendor-backed packed sound RAM.
-- It is intentionally absent from files.qip and exists only so nvc can
-- analyze and elaborate nds_sound without an Altera simulation library.
library ieee;
use ieee.std_logic_1164.all;

entity nds_sound_fetch_state_ram is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk    : in  std_logic;
      addr_a : in  natural range 0 to 15;
      data_a : in  std_logic_vector(48 downto 0);
      q_a    : out std_logic_vector(48 downto 0);
      we_a   : in  std_logic;
      addr_b : in  natural range 0 to 15;
      data_b : in  std_logic_vector(48 downto 0);
      q_b    : out std_logic_vector(48 downto 0);
      we_b   : in  std_logic
   );
end entity;

architecture simulation of nds_sound_fetch_state_ram is
   type ram_t is array (0 to 15) of std_logic_vector(48 downto 0);
   signal ram : ram_t := (others => (others => '0'));
begin
   process (clk)
   begin
      if rising_edge(clk) then
         if we_a = '1' then
            ram(addr_a) <= data_a;
            q_a <= data_a;
         else
            q_a <= ram(addr_a);
         end if;
         if we_b = '1' then
            ram(addr_b) <= data_b;
            q_b <= data_b;
         else
            q_b <= ram(addr_b);
         end if;
      end if;
   end process;
end architecture;
