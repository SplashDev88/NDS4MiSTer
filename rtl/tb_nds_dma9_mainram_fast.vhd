-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored transfer matrix. Independent byte-lane/address scoreboard, with
-- delayed pair reads, posted writes and memory ownership checks.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_dma9_mainram_fast is
 generic(LATENCY:positive:=1);
end;
architecture sim of tb_nds_dma9_mainram_fast is
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal regs:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"0000",'0');
 signal dma_on,grant,mb_ena,mb_rnw,mb_done,mr_ena,mr_rnw,mr_done,mr_pair:std_logic:='0';
 signal mb_addr,mb_out,mb_in,mr_out,mr_lo,mr_hi:std_logic_vector(31 downto 0):=(others=>'0');
 signal mr_addr:std_logic_vector(21 downto 2);signal mr_be:std_logic_vector(3 downto 0);
 signal mb_acc:std_logic_vector(1 downto 0);
 signal irq:std_logic_vector(3 downto 0);
 signal fast:boolean:=true;signal fast_ok:std_logic;
 signal words32:boolean:=true;
 signal source,dest:integer:=16#02001000#;
 signal src_mode,dst_mode:natural:=0;
 signal writes,reads,fast_requests:natural:=0;
 signal busy:boolean:=false;
 function mem(a:integer) return std_logic_vector is
  variable w:std_logic_vector(31 downto 0);
  variable aligned:integer:=a-a mod 4;
 begin
  w:=std_logic_vector(to_unsigned((aligned/2+16#1234#) mod 65536,16)) & std_logic_vector(to_unsigned((aligned/2+16#ABCD#) mod 65536,16));
  return std_logic_vector(rotate_right(unsigned(w),(a mod 4)*8));
 end;
 function offset(mode:natural; i:natural; width:positive) return integer is
 begin
  if mode=0 then return i*width;elsif mode=1 then return -integer(i*width);else return 0;end if;
 end;
begin
 clk<=not clk after 5 ns;
 fast_ok<=grant when fast else '0';
 dut:entity work.nds_dma9 port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
  trig_vblank=>'0',trig_hblank=>'0',trig_card=>'0',gx_supported=>'0',trig_gx=>'0',cpu_bus_idle=>'1',dma_on=>dma_on,dma_bus_on=>grant,
  mb_ena=>mb_ena,mb_rnw=>mb_rnw,mb_adr=>mb_addr,mb_acc=>mb_acc,mb_lowbits=>open,mb_dout=>mb_out,mb_din=>mb_in,mb_done=>mb_done,
  io_fast_ena=>open,io_fast_rnw=>open,io_fast_adr=>open,io_fast_acc=>open,io_fast_be=>open,io_fast_dout=>open,io_fast_din=>(others=>'0'),
  vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,vram_fast_din=>open,vram_fast_dout=>(others=>'0'),
  vram_fast_done=>'0',vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',
  mr_fast_ok=>fast_ok,mr_fast_ena=>mr_ena,mr_fast_rnw=>mr_rnw,mr_fast_addr=>mr_addr,mr_fast_be=>mr_be,mr_fast_wdata=>mr_out,mr_fast_pair=>mr_pair,
  mr_fast_done=>mr_done,mr_fast_rdata=>mr_lo,mr_fast_rdata_hi=>mr_hi,irq_dma=>irq);
 process(clk)
  variable pending:boolean:=false;variable delay:natural:=0;
  variable isfast,reading:boolean:=false;variable address:integer:=0;
  variable payload:std_logic_vector(31 downto 0);variable be:std_logic_vector(3 downto 0);
  variable width,sa,da:integer;variable expected:std_logic_vector(31 downto 0);
 begin
  if rising_edge(clk) then
   mr_done<='0';mb_done<='0';
   if reset='1' then pending:=false;busy<=false;writes<=0;reads<=0;fast_requests<=0;
   else
    if pending then
     if delay=0 then
      if reading then
       if isfast then mr_lo<=mem(address);mr_hi<=mem(address+4);
       else mb_in<=mem(address);end if;
       reads<=reads+1;
      else
       if words32 then width:=4;else width:=2;end if;
       sa:=source+offset(src_mode,writes,width);da:=dest+offset(dst_mode,writes,width);
       expected:=mem(sa);
       if isfast then
        assert address=da-da mod 4 report "fast destination address" severity failure;
        if width=4 then assert be="1111" and payload=expected report "fast word data" severity failure;
        elsif da mod 4=0 then assert be="0011" and payload(15 downto 0)=expected(15 downto 0) report "fast low halfword" severity failure;
        else assert be="1100" and payload(31 downto 16)=expected(15 downto 0) report "fast high halfword" severity failure;end if;
       else
        assert address=da report "fallback destination address" severity failure;
        if width=4 then assert payload=expected report "fallback word data" severity failure;
        else assert payload(15 downto 0)=expected(15 downto 0) report "fallback halfword data" severity failure;end if;
       end if;
       writes<=writes+1;
      end if;
      if isfast then mr_done<='1';else mb_done<='1';end if;
      pending:=false;busy<=false;
     else delay:=delay-1;end if;
    end if;
    if mr_ena='1' or mb_ena='1' then
     assert not pending and not (mr_ena='1' and mb_ena='1') report "overlapping memory access" severity failure;
     pending:=true;busy<=true;delay:=LATENCY-1+(reads+writes) mod 4;
     isfast:=mr_ena='1';
     if isfast then
      assert grant='1' report "fast access without ownership" severity failure;
      reading:=mr_rnw='1';address:=16#02000000#+to_integer(unsigned(mr_addr))*4;payload:=mr_out;be:=mr_be;
      fast_requests<=fast_requests+1;
      if reading then assert mr_pair='1' and address mod 8=0 report "unaligned/nonpair prefetch" severity failure;end if;
     else reading:=mb_rnw='1';address:=to_integer(unsigned(mb_addr));payload:=mb_out;be:="1111";end if;
    end if;
    if busy and isfast then assert grant='1' report "ownership dropped before completion" severity failure;end if;
   end if;
  end if;
 end process;
 process
  procedure reg(a:natural;d:std_logic_vector(31 downto 0)) is
  begin
   wait until falling_edge(clk);regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=d;regs.ena<='1';regs.rnw<='0';regs.bEna<="1111";
   wait until falling_edge(clk);regs.ena<='0';regs.rnw<='1';
  end;
  variable ctrl:unsigned(31 downto 0);variable width,count,cases:natural:=0;
 begin
  for f in 0 to 1 loop
   for w in 0 to 1 loop
    for s in 0 to 2 loop
     for d in 0 to 2 loop
      for align in 0 to 1 loop
       wait until falling_edge(clk);reset<='1';fast<=f=1;words32<=w=1;src_mode<=s;dst_mode<=d;
       if w=1 then width:=4;else width:=2;end if;
       source<=16#02001080#+align*width;dest<=16#02008080#+align*width;
       wait until falling_edge(clk);wait until falling_edge(clk);reset<='0';
       reg(16#B0#,std_logic_vector(to_unsigned(source,32)));reg(16#B4#,std_logic_vector(to_unsigned(dest,32)));
       count:=17;
       ctrl:=unsigned'(x"C0000000") or to_unsigned(count,32) or shift_left(to_unsigned(w,32),26) or shift_left(to_unsigned(s,32),23) or shift_left(to_unsigned(d,32),21);
       reg(16#B8#,std_logic_vector(ctrl));
       wait until irq(0)='1' for 200 us;
       assert irq(0)='1' report "DMA timeout" severity failure;
       assert writes=count and not busy report "early completion or missing/duplicated write" severity failure;
       if f=1 then assert fast_requests>0 report "fast lane not covered" severity failure;
       else assert fast_requests=0 report "fast lane used without grant" severity failure;end if;
       if f=1 and w=1 and s=0 and d=0 then
        assert reads<=10 report "pair buffer did not reduce physical reads" severity failure;
       end if;
       cases:=cases+1;
      end loop;
     end loop;
    end loop;
   end loop;
  end loop;
  report "PASS: main RAM fast/fallback, 16/32-bit, fixed/increment/decrement, pair offsets; cases=" & integer'image(cases);
  stop;wait;
 end process;
end;
