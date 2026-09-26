-- SPDX-License-Identifier: GPL-3.0-or-later
-- Retain a real GX reply until an overlapping fast DMA releases the IO mux.
-- No latency change when DMA is absent; never fabricate a CPU completion.
library ieee;
use ieee.std_logic_1164.all;
entity nds_h3d_gx_dma_completion is
 port(clk, reset, gx_complete, dma_bus_on : in std_logic;
      cpu_complete : out std_logic);
end;
architecture rtl of nds_h3d_gx_dma_completion is
 signal pending : std_logic := '0';
begin
 cpu_complete <= (gx_complete or pending) and not dma_bus_on and not reset;
 process(clk)
 begin
  if rising_edge(clk) then
   if reset='1' then pending<='0';
   elsif dma_bus_on='0' then pending<='0';
   elsif gx_complete='1' then pending<='1';
   end if;
  end if;
 end process;
end;
