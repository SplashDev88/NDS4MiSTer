-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dedicated Cyclone-V storage for the paired NDS sound fetch pointer/count.
--
-- The generic four-lane RAM wrapper cannot represent this word legally: its
-- byte-enable count is fixed at four, but the 49-bit state is always written
-- atomically and does not need byte enables at all.  This boundary therefore
-- exposes the exact 49-bit word and intentionally leaves byteena disconnected,
-- as required by altsyncram when WIDTH_BYTEENA is its default value of one.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

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

architecture rtl of nds_sound_fetch_state_ram is
   signal addr_a_slv : std_logic_vector(3 downto 0);
   signal addr_b_slv : std_logic_vector(3 downto 0);
begin
   addr_a_slv <= std_logic_vector(to_unsigned(addr_a, addr_a_slv'length));
   addr_b_slv <= std_logic_vector(to_unsigned(addr_b, addr_b_slv'length));

   g_cyclone5 : if is_simu = '0' generate
   begin
      packed_state_ram : altsyncram
      generic map
      (
         address_reg_b => "CLOCK1",
         clock_enable_input_a => "NORMAL",
         clock_enable_input_b => "NORMAL",
         clock_enable_output_a => "BYPASS",
         clock_enable_output_b => "BYPASS",
         indata_reg_b => "CLOCK1",
         intended_device_family => "Cyclone V",
         lpm_type => "altsyncram",
         numwords_a => 16,
         numwords_b => 16,
         operation_mode => "BIDIR_DUAL_PORT",
         outdata_aclr_a => "NONE",
         outdata_aclr_b => "NONE",
         outdata_reg_a => "UNREGISTERED",
         outdata_reg_b => "UNREGISTERED",
         power_up_uninitialized => "FALSE",
         read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
         read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
         init_file => " ",
         widthad_a => 4,
         widthad_b => 4,
         width_a => 49,
         width_b => 49,
         width_byteena_a => 1,
         width_byteena_b => 1,
         wrcontrol_wraddress_reg_b => "CLOCK1"
      )
      port map
      (
         address_a => addr_a_slv,
         address_b => addr_b_slv,
         clock0 => clk,
         clock1 => clk,
         clocken0 => '1',
         clocken1 => '1',
         data_a => data_a,
         data_b => data_b,
         wren_a => we_a,
         wren_b => we_b,
         q_a => q_a,
         q_b => q_b
      );
   end generate;

   -- Portable behavior used only by simulation builds.  The fetch FSM allows
   -- a full registered-read settle cycle before consuming q_b, matching the
   -- hardware boundary. Same-address mixed-port collisions retain the vendor
   -- primitive's pre-existing don't-care contract from the retired RAM pair.
   g_simulation : if is_simu = '1' generate
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
   end generate;
end architecture;
