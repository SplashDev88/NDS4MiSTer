-- SPDX-License-Identifier: GPL-3.0-or-later
-- Capture current input levels once per hold. Normal operation is a direct
-- combinational path, preserving the product's existing sampling latency.
library ieee;
use ieee.std_logic_1164.all;
entity nds_checkpoint_inputs is
   generic (ENABLE : boolean := false; WIDTH : positive := 31);
   port (clk, reset, hold : in std_logic;
         live : in std_logic_vector(WIDTH-1 downto 0);
         value : out std_logic_vector(WIDTH-1 downto 0);
         held : out std_logic := '0');
end;
architecture rtl of nds_checkpoint_inputs is
begin
   enabled : if ENABLE generate
      signal captured : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
      signal valid : std_logic := '0';
   begin
      value <= captured when valid = '1' and hold = '1' and reset = '0' else live;
      held <= valid and hold and not reset;
      process(clk) begin
         if rising_edge(clk) then
            if reset = '1' or hold = '0' then valid <= '0';
            elsif valid = '0' then captured <= live; valid <= '1'; end if;
         end if;
      end process;
   end generate;
   disabled : if not ENABLE generate
      value <= live;
      held <= '0';
   end generate;
end;
