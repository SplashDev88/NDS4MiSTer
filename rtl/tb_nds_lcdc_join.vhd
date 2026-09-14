-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exercise pending LCDC read sharing across writes, mode changes and reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_lcdc_join is
   generic (expect_join : boolean := true);
end;
architecture sim of tb_nds_lcdc_join is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal maps : std_logic_vector(71 downto 0) := (others=>'0');
   signal clear_busy, req, accept, done, lcdc : std_logic := '0';
   signal addr : unsigned(18 downto 2) := (others=>'0');
   signal data : std_logic_vector(31 downto 0);
   signal rsreq, rsready, rsdone : std_logic := '0';
   signal rsbank : std_logic_vector(1 downto 0);
   signal rsaddr : unsigned(16 downto 3);
   signal rsdata : std_logic_vector(63 downto 0) := (others=>'0');
   signal srv_req, srv_rnw, cpu_write, cpu_wok : std_logic := '0';
   signal srv_bank : std_logic_vector(1 downto 0);
   signal srv_addr : unsigned(16 downto 2);
   signal srv_din : std_logic_vector(31 downto 0);
   signal cpu_addr : unsigned(23 downto 2) := (others=>'0');
   signal cycles, reads, seen, inflight : natural := 0;
   type results_t is array(0 to 15) of std_logic_vector(31 downto 0);
   signal results : results_t := (others=>(others=>'0'));
   function word(a : natural) return std_logic_vector is
   begin return std_logic_vector(to_unsigned(16#12000000#+a,32)); end;
begin
   clk<=not clk after 5 ns;
   dut : entity work.nds_vram generic map(is_simu=>'1') port map(
      clk=>clk,reset=>reset,vramcnt=>maps,
      cpu9_ena=>cpu_write,cpu9_rnw=>'0',cpu9_addr=>cpu_addr,cpu9_be=>"1111",cpu9_din=>x"AABBCCDD",
      cpu9_dout=>open,cpu9_done=>open,cpu9_welig=>open,cpu9_wok=>cpu_wok,cpu9_wpost=>'1',
      cpu7_ena=>'0',cpu7_rnw=>'1',cpu7_addr=>(others=>'0'),cpu7_be=>"0000",cpu7_din=>(others=>'0'),
      cpu7_dout=>open,cpu7_done=>open,
      srv_req=>srv_req,srv_rnw=>srv_rnw,srv_bank=>srv_bank,srv_addr=>srv_addr,srv_be=>open,srv_din=>srv_din,
      srv_dout=>(others=>'0'),srv_done=>srv_req,
      rdr_bg_req=>req,rdr_bg_lcdc=>lcdc,rdr_bg_addr=>addr,rdr_bg_accept=>accept,rdr_bg_done=>done,rdr_bg_dout=>data,
      rsrv_req=>rsreq,rsrv_ready=>rsready,rsrv_bank=>rsbank,rsrv_addr=>rsaddr,rsrv_done=>rsdone,rsrv_dout=>rsdata,
      clr_busy=>clear_busy,dbg_rbusy=>open);
   rsready<='1' when cycles mod 3/=1 and inflight<2 else '0';
   process(clk)
      type queue_t is array(0 to 7) of std_logic_vector(63 downto 0);
      type deadlines_t is array(0 to 7) of natural;
      variable queue : queue_t;
      variable deadlines : deadlines_t;
      variable head,tail,count,a : natural := 0;
      variable high_word : std_logic_vector(31 downto 0) := word(1);
      variable lo,hi : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         cycles<=cycles+1;rsdone<='0';
         if reset='1' then
            reads<=0;seen<=0;count:=0;head:=0;tail:=0;high_word:=word(1);
         else
            if srv_req='1' and srv_rnw='0' and clear_busy='0' and srv_bank="00" and srv_addr=1 then
               high_word:=srv_din;
            end if;
            if rsreq='1' and rsready='1' then
               a:=to_integer(rsaddr)*2;lo:=word(a);hi:=word(a+1);
               if a=0 then hi:=high_word;end if;
               assert rsbank="00" report "unexpected test bank" severity failure;
               queue(tail):=hi&lo;deadlines(tail):=cycles+40;
               tail:=(tail+1) mod 8;count:=count+1;reads<=reads+1;
            end if;
            if count>0 and cycles>=deadlines(head) then
               rsdata<=queue(head);rsdone<='1';head:=(head+1) mod 8;count:=count-1;
            end if;
            if done='1' then
               assert seen<16 report "extra response" severity failure;
               results(seen)<=data;seen<=seen+1;
            end if;
         end if;
         inflight<=count;
      end if;
   end process;
   process
      procedure ticks(n : positive) is
      begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
      procedure fresh(direct : boolean := true) is
      begin
         req<='0';cpu_write<='0';reset<='1';ticks(3);reset<='0';ticks(1);
         if clear_busy='1' then wait until clear_busy='0';end if;ticks(2);
         maps<=(others=>'0');
         if direct then maps(7 downto 0)<=x"80";lcdc<='1';
         else maps(7 downto 0)<=x"81";lcdc<='0';end if;
         ticks(2);
      end;
      procedure send(a : natural) is
      begin
         addr<=to_unsigned(a,17);req<='1';
         wait until rising_edge(clk) and accept='1';req<='0';ticks(1);
      end;
      procedure finish(n : positive) is
      begin
         if seen<n then wait until seen=n;end if;ticks(5);
         assert seen=n report "response count mismatch" severity failure;
      end;
      procedure write_high is
      begin
         cpu_addr<=to_unsigned(16#800004#/4,22);cpu_write<='1';
         wait until rising_edge(clk) and cpu_wok='1';cpu_write<='0';ticks(1);
      end;
   begin
      fresh;send(0);send(1);lcdc<='0';finish(2);
      assert results(0)=word(0) and results(1)=word(1) report "joined half/order mismatch" severity failure;
      if expect_join then assert reads=1 report "LCDC neighbors duplicated a memory read" severity failure;
      else assert reads=2 report "baseline read count changed" severity failure;end if;
      report "JOIN_PASS adjacent halves and live display-mode change" severity note;

      fresh(false);send(0);send(1);finish(2);
      assert results(0)=word(0) and results(1)=word(1) and reads=2
         report "normal BG path changed" severity failure;
      report "JOIN_PASS normal BG requests unchanged" severity note;

      fresh;send(0);send(3);finish(2);
      assert results(0)=word(0) and results(1)=word(3) and reads=2
         report "unrelated lines shared a read" severity failure;
      report "JOIN_PASS distinct lines remain separate" severity note;

      for wait_after_write in 0 to 1 loop
         fresh;send(0);ticks(6);write_high;
         if wait_after_write=1 then ticks(12);end if;
         send(1);finish(2);
         assert results(0)=word(0) and results(1)=x"AABBCCDD" and reads=2
            report "write between read requests returned stale high half" severity failure;
         report "JOIN_PASS posted write coherence variant=" & integer'image(wait_after_write) severity note;
      end loop;

      fresh;send(0);send(1);ticks(6);
      fresh;send(4);send(5);finish(2);
      assert results(0)=word(4) and results(1)=word(5) report "reset leaked pending pair" severity failure;
      report "JOIN_PASS reset cancels pending pair" severity note;
      stop;wait;
   end process;
   process begin wait for 100 ms;assert false report "join test timeout" severity failure;end process;
end;
