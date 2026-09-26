-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real DMA + GX owner + reply-retention regression. A blocked CPU transaction
-- may not retire from DMA data or let a fast-lane request fall back to membus.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_dma9_gx_overlap is end;
architecture sim of tb_nds_dma9_gx_overlap is
 signal clk:std_logic:='0'; signal reset:std_logic:='1';
 signal regs:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"0000",'0');
 signal cpu_read,cpu_wait,cpu_idle,cpu_complete,gx_busy,gx_complete,fence,query,reply,selected:std_logic:='0';
 signal loader,peek:std_logic:='0';
 signal query_ready:std_logic:='1';
 signal token:std_logic_vector(31 downto 0);signal reply_id:std_logic_vector(31 downto 0):=(others=>'0');
 signal gx_data:std_logic_vector(31 downto 0);signal cache_index:std_logic_vector(4 downto 0);
 signal cache_idle,locked,allow_overlap,hblank,vblank,grant,dma_on,mb_ena,io_ena,io_rnw,io_valid,io_ready:std_logic:='0';
 signal io_addr:std_logic_vector(27 downto 0);signal io_data:std_logic_vector(31 downto 0);signal io_be:std_logic_vector(3 downto 0);
 signal mr_ok,mr_ena,mr_done,mr_rnw,mr_pair:std_logic:='0';signal mr_addr:std_logic_vector(21 downto 2);
 signal mr_lo,mr_hi:std_logic_vector(31 downto 0):=(others=>'0');
 signal irq:std_logic_vector(3 downto 0);
 signal ready_delay:natural:=0;signal writes,reads,completions:natural:=0;
 signal src,dst:natural:=16#02001000#;signal word32:boolean:=false;
 signal expect_fast:boolean:=true;signal ram_enabled:std_logic:='1';
 signal accepted_reply:boolean:=false;
begin
 clk<=not clk after 5 ns;
 cpu_idle<=not cpu_wait;
 allow_overlap<=gx_busy and not fence and not query and cache_idle and not locked and not loader and not peek;
 mr_ok<=grant and ram_enabled when ready_delay>=8 else '0';
 owner:entity work.nds_h3d_gx_readback_owner port map(
  clk=>clk,reset=>reset,service_ready=>'1',cpu_read=>cpu_read,address=>x"0000640",geometry_write=>'0',
  selected=>selected,busy=>gx_busy,complete=>gx_complete,read_data=>gx_data,
  fence_valid=>fence,request_valid=>query,request_ready=>query_ready,request_id=>token,
  response_valid=>reply,response_id=>reply_id,response_status=>x"00000000",cache_index=>cache_index,cache_data=>x"CAFEBABE");
 completion:entity work.nds_h3d_gx_dma_completion port map(clk=>clk,reset=>reset,gx_complete=>gx_complete,dma_bus_on=>grant,cpu_complete=>cpu_complete);
 dut:entity work.nds_dma9 port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
  trig_vblank=>vblank,trig_hblank=>hblank,trig_card=>'0',gx_supported=>'1',trig_gx=>'0',cpu_bus_idle=>cpu_idle,io_read_wait_grant=>allow_overlap,
  dma_on=>dma_on,dma_bus_on=>grant,gx_write_valid=>io_valid,gx_write_ready=>io_ready,io_write_capture=>'1',
  mb_ena=>mb_ena,mb_rnw=>open,mb_adr=>open,mb_acc=>open,mb_lowbits=>open,mb_dout=>open,mb_din=>x"DEADDEAD",mb_done=>'0',
  io_fast_ena=>io_ena,io_fast_rnw=>io_rnw,io_fast_adr=>io_addr,io_fast_acc=>open,io_fast_be=>io_be,io_fast_dout=>io_data,io_fast_din=>x"DEADDEAD",
  vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,vram_fast_din=>open,vram_fast_dout=>(others=>'0'),
  vram_fast_done=>'0',vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',
  mr_fast_ok=>mr_ok,mr_fast_ena=>mr_ena,mr_fast_rnw=>mr_rnw,mr_fast_addr=>mr_addr,mr_fast_be=>open,mr_fast_wdata=>open,mr_fast_pair=>mr_pair,
  mr_fast_done=>mr_done,mr_fast_rdata=>mr_lo,mr_fast_rdata_hi=>mr_hi,irq_dma=>irq);
 process(clk)
  variable pending:boolean:=false;variable ticks:natural:=0;variable expected:std_logic_vector(31 downto 0);
 begin
  if rising_edge(clk) then
   mr_done<='0';
   if reset='1' then
    cpu_wait<='0';writes<=0;reads<=0;completions<=0;pending:=false;ready_delay<=0;accepted_reply<=false;
   else
    if cpu_read='1' then cpu_wait<='1';end if;
    if reply='1' then accepted_reply<=true;end if;
    if cpu_complete='1' then
     assert accepted_reply and cpu_wait='1' report "fabricated/duplicate CPU reply" severity failure;
     assert grant='0' and gx_data=x"CAFEBABE" report "CPU retired against DMA IO mux or wrong GX word" severity failure;
     cpu_wait<='0';completions<=completions+1;
    end if;
    if grant='0' then ready_delay<=0;elsif ready_delay<8 then ready_delay<=ready_delay+1;end if;
    assert mb_ena='0' report "parked CPU membus was stolen by fallback" severity failure;
    if pending then
     assert grant='1' report "RAM fast ownership dropped while outstanding" severity failure;
     if ticks=0 then mr_lo<=x"22221111";mr_hi<=x"44443333";mr_done<='1';pending:=false;
     else ticks:=ticks-1;end if;
    end if;
    if mr_ena='1' then
     assert expect_fast and grant='1' and mr_ok='1' and not pending report "invalid RAM fast request" severity failure;
     assert mr_rnw='1' and mr_pair='1' and to_integer(unsigned(mr_addr))*4=(src-16#02000000#)/8*8 report "wrong RAM pair request" severity failure;
     pending:=true;ticks:=11;reads<=reads+1;
    end if;
    if io_ena='1' then
     assert expect_fast and grant='1' and io_rnw='0' and io_ready='1' report "unaccepted IO write" severity failure;
     assert to_integer(unsigned(io_addr))=(dst-16#04000000#)/4*4 report "wrong IO address" severity failure;
     if word32 then
      if src mod 8=0 then expected:=x"22221111";else expected:=x"44443333";end if;
      assert io_be="1111" and io_data=expected report "word payload mismatch" severity failure;
     else
      case src mod 8 is
       when 0=>expected:=x"11111111";when 2=>expected:=x"22222222";
       when 4=>expected:=x"33333333";when others=>expected:=x"44444444";
      end case;
      assert io_data=expected report "halfword payload mismatch" severity failure;
      if dst mod 4=0 then assert io_be="0011" report "low-half BE" severity failure;
      else assert io_be="1100" report "high-half BE" severity failure;end if;
     end if;
     writes<=writes+1;
    end if;
   end if;
  end if;
 end process;
 process
  procedure cycles(n:natural) is begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
  procedure reg(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cycles(1);regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=d;regs.ena<='1';regs.rnw<='0';regs.bEna<="1111";cycles(1);regs.ena<='0';regs.rnw<='1';end;
  procedure init is
  begin reset<='1';cpu_read<='0';reply<='0';hblank<='0';vblank<='0';loader<='0';peek<='0';query_ready<='1';cache_idle<='1';locked<='0';io_ready<='1';ram_enabled<='1';cycles(3);reset<='0';cycles(2);end;
  procedure read_and_trigger is
  begin cpu_read<='1';cycles(1);cpu_read<='0';if query/='1' then wait until query='1' for 1 us;end if;assert query='1' report "GX query missing" severity failure;cycles(3);hblank<='1';vblank<='1';cycles(1);hblank<='0';vblank<='0';end;
  procedure respond is
  begin cycles(1);reply_id<=token;reply<='1';cycles(1);reply<='0';end;
  variable ctrl:unsigned(31 downto 0);variable cases:natural:=0;
 begin
  for w in 0 to 1 loop
   for align in 0 to 1 loop
    for phase in 0 to 3 loop
     for gate in 0 to 5 loop
      expect_fast<=true;word32<=w=1;
      if w=1 then src<=16#02001000#+align*4;dst<=16#04000014#;
      else src<=16#02001002#+align*4;dst<=16#04000014#+align*2;end if;
      init;
      reg(16#B0#,std_logic_vector(to_unsigned(src,32)));reg(16#B4#,std_logic_vector(to_unsigned(dst,32)));
      ctrl:=unsigned'(x"D2400001") or shift_left(to_unsigned(w,32),26);reg(16#B8#,std_logic_vector(ctrl));
      if gate=1 then cache_idle<='0';elsif gate=2 then locked<='1';elsif gate=3 then query_ready<='0';elsif gate=4 then loader<='1';elsif gate=5 then peek<='1';end if;
      io_ready<='0';read_and_trigger;
      if gate/=0 then cycles(20);assert grant='0' and reads=0 report "cache/lock/unposted-query guard bypassed" severity failure;cache_idle<='1';locked<='0';query_ready<='1';loader<='0';peek<='0';end if;
      if grant/='1' then wait until grant='1' for 2 us;end if;assert grant='1' report "HBlank did not preempt GX wait" severity failure;
      if phase=0 then respond;end if;
      if mr_ena/='1' then wait until mr_ena='1' for 2 us;end if;assert mr_ena='1' report "RAM request missing" severity failure;
      if phase=1 then respond;end if;
      if io_valid/='1' then wait until io_valid='1' for 2 us;end if;assert io_valid='1' report "IO request missing" severity failure;
      if phase=2 then respond;end if;
      cycles(20);assert writes=0 and completions=0 and cpu_wait='1' report "backpressure lost request or retired CPU" severity failure;
      io_ready<='1';wait until grant='0' for 2 us;assert grant='0' report "DMA ownership stuck" severity failure;
      if phase=3 then respond;end if;
      cycles(10);assert writes=1 and reads=1 and completions=1 report "wrong transaction counts w=" & integer'image(w) & " align=" & integer'image(align) & " phase=" & integer'image(phase) & " gate=" & integer'image(gate) & " writes=" & integer'image(writes) & " reads=" & integer'image(reads) & " completions=" & integer'image(completions) severity failure;cases:=cases+1;
     end loop;
    end loop;
   end loop;
  end loop;
  -- Many HBlanks can arrive during one real ARM reply wait. Each must
  -- advance exactly once without releasing the CPU or using its membus.
  init;expect_fast<=true;word32<=false;src<=16#02001002#;dst<=16#04001014#;cycles(1);
  reg(16#B0#,std_logic_vector(to_unsigned(src,32)));reg(16#B4#,std_logic_vector(to_unsigned(dst,32)));
  reg(16#B8#,x"D3400001");read_and_trigger;
  for repeat_index in 1 to 8 loop
   cycles(100);
   assert writes=repeat_index and reads=repeat_index and completions=0 and cpu_wait='1'
    report "repeated HBlank lost/duplicated while GX reply waited" severity failure;
   if repeat_index<8 then hblank<='1';cycles(1);hblank<='0';end if;
  end loop;
  respond;cycles(10);assert completions=1 report "late reply after repeated HBlanks lost" severity failure;
  -- Non-HBlank, multi-unit, non-RAM, non-2D and reload-from-unsupported source
  -- transfers must not borrow the parked CPU bus. Reset instead of granting
  -- normal fallback, which is covered by the standalone transfer matrix.
  for bad in 0 to 5 loop
   init;expect_fast<=false;src<=16#02001000#;dst<=16#04000014#;cycles(1);
   if bad=0 then src<=16#03000000#;elsif bad=1 then dst<=16#04000400#;elsif bad=2 then dst<=16#05000000#;end if;cycles(1);
   reg(16#B0#,std_logic_vector(to_unsigned(src,32)));reg(16#B4#,std_logic_vector(to_unsigned(dst,32)));
   ctrl:=unsigned'(x"D2400001");if bad=3 then ctrl(20 downto 0):=to_unsigned(2,21);elsif bad=4 then ctrl(29 downto 27):="001";elsif bad=5 then ctrl(24 downto 23):="11";end if;
   reg(16#B8#,std_logic_vector(ctrl));read_and_trigger;cycles(50);
   assert grant='0' and reads=0 and writes=0 and completions=0 report "unsupported parked-bus grant" severity failure;
  end loop;
  -- Reset while a true reply is retained behind a blocked IO write. A stale
  -- completion must not escape into the new guest session after DMA resets.
  init;expect_fast<=true;word32<=false;src<=16#02001002#;dst<=16#04000014#;cycles(1);
  reg(16#B0#,std_logic_vector(to_unsigned(src,32)));reg(16#B4#,std_logic_vector(to_unsigned(dst,32)));reg(16#B8#,x"D2400001");io_ready<='0';read_and_trigger;
  if io_valid/='1' then wait until io_valid='1' for 3 us;end if;assert io_valid='1' severity failure;respond;cycles(10);assert completions=0 severity failure;
  reset<='1';cycles(3);reset<='0';cycles(10);assert completions=0 and cpu_complete='0' and grant='0' report "stale completion after reset" severity failure;
  report "PASS: GX-wait fast DMA; reply timing/cache/lock/backpressure/lanes, unsupported grants, reset; cases=" & integer'image(cases);
  stop;wait;
 end process;
end;
