-- SPDX-License-Identifier: GPL-3.0-or-later
-- Standard (not extended) palette shadow for ARM9 CPU/DMA reads. Both engine
-- banks exist even when Engine B's pixel renderer is disabled. The existing
-- GPU write ports and their IO completion handshake are unchanged.
library ieee;
use ieee.std_logic_1164.all;
library MEM;

entity nds_palette_readback is
   generic (is_simu : std_logic := '0');
   port (
      clk, reset : in std_logic;
      power_a, power_b : in std_logic;
      addr : in integer range 0 to 511;
      we : in std_logic;
      be : in std_logic_vector(3 downto 0);
      data : in std_logic_vector(31 downto 0);
      q : out std_logic_vector(31 downto 0);
      clear_busy : out std_logic
   );
end entity;

architecture rtl of nds_palette_readback is
   signal clear_run : std_logic := '1';
   signal reset_d : std_logic := '0';
   signal clear_addr : integer range 0 to 511 := 0;
   signal clearing, write_enable, read_power : std_logic;
   signal read_power_q : std_logic := '0';
   signal write_addr : integer range 0 to 511;
   signal write_data, ram_q : std_logic_vector(31 downto 0);
   signal write_be : std_logic_vector(3 downto 0);
begin
   -- Complete clearing while reset is held, like the GPU palette clear pass.
   -- Restart on every reset edge so ROM reloads cannot inherit old palettes.
   clearing <= clear_run or (reset and not reset_d);
   clear_busy <= clearing;
   process (clk)
   begin
      if rising_edge(clk) then
         reset_d <= reset;
         if reset = '1' and reset_d = '0' then
            clear_run <= '1';
            clear_addr <= 0;
         elsif clear_run = '1' then
            if clear_addr = 511 then clear_run <= '0';
            else clear_addr <= clear_addr + 1; end if;
         end if;
         read_power_q <= read_power;
      end if;
   end process;

   read_power <= power_a when addr < 256 else power_b;
   write_addr <= clear_addr when clearing = '1' else addr;
   write_data <= x"00000000" when clearing = '1' else data;
   write_be <= "1111" when clearing = '1' else be;
   write_enable <= clearing or (we and read_power and not reset);
   q <= ram_q when read_power_q = '1' else x"00000000";

   ram : entity MEM.SyncRamDualByteEnable
      generic map (is_simu => is_simu, is_cyclone5 => '1', ADDR_WIDTH => 9)
      port map (
         clk => clk, ce_a => '1', addr_a => write_addr,
         datain_a0 => write_data(7 downto 0), datain_a1 => write_data(15 downto 8),
         datain_a2 => write_data(23 downto 16), datain_a3 => write_data(31 downto 24),
         dataout_a => open, we_a => write_enable, be_a => write_be,
         ce_b => '1', addr_b => addr,
         datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => ram_q, we_b => '0', be_b => "0000");
end architecture;
