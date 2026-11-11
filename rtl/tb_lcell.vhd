-- SPDX-License-Identifier: GPL-3.0-only
-- Functional model only. Physical setup/hold uses the Quartus LCELL primitive
-- and all-corner timing reports; no propagation delay is assumed here.
library ieee;
use ieee.std_logic_1164.all;
entity lcell is
   port (a_in : in std_logic; a_out : out std_logic);
end entity;
architecture functional of lcell is
begin
   a_out <= a_in;
end architecture;
