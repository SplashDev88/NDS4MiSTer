-- SPDX-License-Identifier: GPL-3.0-or-later
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_checkpoint_inputs is end;
architecture sim of tb_nds_checkpoint_inputs is
 signal clk : std_logic := '0';signal reset,hold : std_logic := '0';
 signal live,value,bypass : std_logic_vector(30 downto 0):=(others=>'0');
 signal held,bypass_held : std_logic;
begin
 clk<=not clk after 5 ns;
 dut:entity work.nds_checkpoint_inputs generic map(ENABLE=>true)
 port map(clk=>clk,reset=>reset,hold=>hold,live=>live,value=>value,held=>held);
 baseline:entity work.nds_checkpoint_inputs
 port map(clk=>clk,reset=>reset,hold=>hold,live=>live,value=>bypass,held=>bypass_held);
 process
  variable saved : std_logic_vector(30 downto 0);
  variable rng : unsigned(30 downto 0):=to_unsigned(137,31);
  procedure step is begin wait until rising_edge(clk);wait for 1 ns;end;
 begin
  for trial in 0 to 127 loop
   hold<='0';step;
   rng:=rng(29 downto 0)&(rng(30) xor rng(27));live<=std_logic_vector(rng);wait for 1 ns;
   assert value=live and bypass=live and held='0' and bypass_held='0' report "input pass-through gained latency" severity failure;
   saved:=live;hold<='1';step;
   assert held='1' and value=saved report "input capture incorrect" severity failure;
   for k in 0 to 30 loop
    live<=std_logic_vector(unsigned(live) xor shift_left(to_unsigned(1,31),k));wait for 1 ns;
    assert value=saved and held='1' and bypass=live and bypass_held='0' report "input hold or disabled path changed" severity failure;
    step;
   end loop;
   if trial mod 7=0 then reset<='1';wait for 1 ns;assert held='0' and value=live severity failure;step;reset<='0';step;
   else hold<='0';wait for 1 ns;assert value=live and held='0' report "input release did not sample current levels" severity failure;end if;
  end loop;
  report "CHECKPOINT_INPUTS_PASS: 128 holds, every input bit, immediate bypass/release, reset and fresh recapture";
  stop;wait;
 end process;
end;
