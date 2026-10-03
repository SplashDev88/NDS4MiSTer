-- SPDX-License-Identifier: GPL-3.0-or-later
-- Actual four-lane store config pipeline, mask, range and guest handoff checks.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_nitro_firmware_cfg is
 generic (collision : boolean := false);
end;
architecture sim of tb_nds_nitro_firmware_cfg is
 signal clk : std_logic := '0';
 signal addr : std_logic_vector(15 downto 0) := (others=>'0');
 signal req, done, wr, cfg : std_logic := '0';
 signal data, cd : std_logic_vector(31 downto 0) := (others=>'0');
 signal lane : std_logic_vector(1 downto 0) := "00";
 signal byte_data : std_logic_vector(7 downto 0) := x"00";
 signal ca : std_logic_vector(6 downto 0) := (others=>'0');
 signal be : std_logic_vector(3 downto 0) := "0000";
 type words is array(0 to 127) of std_logic_vector(31 downto 0);
 function pattern(i:integer) return std_logic_vector is
 begin return std_logic_vector(to_unsigned(16#12345600#+i,32)); end;
begin
 clk <= not clk after 5 ns;
 dut:entity work.nds_nitro_firmware port map(clk,addr,req,done,data,wr,lane,byte_data,cfg,ca,cd,be);
 process
  variable expected:words;
  variable before_word, result:std_logic_vector(31 downto 0);
  procedure edge is begin wait until rising_edge(clk);wait for 1 ns;end;
  procedure fetch(a:integer; want:std_logic_vector(31 downto 0)) is
  begin
   wait until falling_edge(clk);addr<=std_logic_vector(to_unsigned(a,16));req<='1';
   edge; assert done='0' report "early read completion" severity failure;
   wait until falling_edge(clk);req<='0'; edge;
   assert done='1' and data=want report "readback mismatch at "&integer'image(a) severity failure;
   edge;assert done='0' report "duplicate read completion" severity failure;
  end;
 begin
  edge;edge;
  fetch(2,x"4E4C454D"); fetch(32641,x"004D0001");fetch(32705,x"004D0001");
  wait until falling_edge(clk);addr<=std_logic_vector(to_unsigned(32640,16));
  edge;edge;before_word:=data;
  wait until falling_edge(clk);cfg<='1';ca<=(others=>'0');cd<=pattern(0);be<="1111";
  if collision then req<='1';end if;
  edge;assert data=before_word and done='0' report "configuration changed data on acceptance edge" severity failure;
  wait until falling_edge(clk);cfg<='0';cd<=x"DEADBEEF";ca<=(others=>'1');be<="0000";
  edge;assert data=before_word and done='0' report "configuration pipeline latency changed" severity failure;
  edge;assert data=pattern(0) and done='0' report "configuration commit/data capture failed" severity failure;
  -- Back-to-back all128 words, both redundant pages; immediate input poison.
  for i in 0 to 127 loop
   wait until falling_edge(clk);cfg<='1';ca<=std_logic_vector(to_unsigned(i,7));cd<=pattern(i);be<="1111";
   edge;assert done='0' report "configuration fabricated guest completion" severity failure;expected(i):=pattern(i);
  end loop;
  wait until falling_edge(clk);cfg<='0';cd<=x"BAD0BAD0";be<="0000";ca<=(others=>'0');edge;edge;
  for i in 0 to 127 loop fetch(32640+i,expected(i));end loop;
  -- Every byte mask, including zero, preserving all disabled lanes.
  for mask in 0 to 15 loop
   wait until falling_edge(clk);cfg<='1';ca<=std_logic_vector(to_unsigned(127,7));cd<=std_logic_vector(to_unsigned(16#A50000#+mask*16#10101#,32));be<=std_logic_vector(to_unsigned(mask,4));
   for l in 0 to 3 loop
    if ((mask/(2**l)) mod 2)=1 then expected(127)(l*8+7 downto l*8):=std_logic_vector(to_unsigned((16#A50000#+mask*16#10101#)/(2**(8*l)) mod 256,8));end if;
   end loop;
   edge;wait until falling_edge(clk);cfg<='0';cd<=x"FFFFFFFF";be<="0000";edge;edge;
   fetch(32767,expected(127));
  end loop;
  -- Config cannot address header/AP region; regular guest store stays writable.
  fetch(2,x"4E4C454D");fetch(1000,x"FFFFFFFF");
  wait until falling_edge(clk);addr<=std_logic_vector(to_unsigned(32640,16));wr<='1';lane<="01";byte_data<=x"CC";
  edge;wait until falling_edge(clk);wr<='0';edge;edge;
  expected(0)(15 downto 8):=x"CC";fetch(32640,expected(0));
  report "PASS: cfg128 exact words,16 masks, captured data, one-cycle commit, guest reads/writes";
  stop;wait;
 end process;
 process begin wait for 100 us;assert false report "cfg fixture timeout" severity failure;end process;
end;
