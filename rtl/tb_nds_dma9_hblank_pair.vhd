-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real DMA + GX owner + reply-retention regression. A blocked CPU transaction
-- may not retire from DMA data or let a fast-lane request fall back to membus.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_dma9_hblank_pair is end;
architecture sim of tb_nds_dma9_hblank_pair is
 signal clk:std_logic:='0'; signal reset:std_logic:='1';
 signal regs:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"0000",'0');
 signal cpu_read,cpu_wait,cpu_idle,cpu_complete,gx_busy,gx_complete,fence,query,reply,selected:std_logic:='0';
 signal loader,peek,gx_trigger:std_logic:='0';
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
 signal pending_bits:std_logic_vector(3 downto 0);
 type words is array(0 to 127) of std_logic_vector(31 downto 0);
 type addresses is array(0 to 127) of std_logic_vector(27 downto 0);
 type masks is array(0 to 127) of std_logic_vector(3 downto 0);
 signal trace_data:words;signal trace_addr:addresses;signal trace_be:masks;
 function memword(a:natural) return std_logic_vector is
 begin return std_logic_vector(to_unsigned(a,32)) xor x"a5a55a5a";end;
 function halfword(a:natural) return std_logic_vector is
 variable d:std_logic_vector(31 downto 0);variable h:std_logic_vector(15 downto 0);
 begin d:=memword((a/4)*4);if a mod 4=0 then h:=d(15 downto 0);else h:=d(31 downto 16);end if;return h & h;end;

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
  trig_vblank=>vblank,trig_hblank=>hblank,trig_card=>'0',gx_supported=>'1',trig_gx=>gx_trigger,cpu_bus_idle=>cpu_idle,io_read_wait_grant=>allow_overlap,
  dma_on=>dma_on,dma_bus_on=>grant,dbg_pending=>pending_bits,gx_write_valid=>io_valid,gx_write_ready=>io_ready,io_write_capture=>'1',
  mb_ena=>mb_ena,mb_rnw=>open,mb_adr=>open,mb_acc=>open,mb_lowbits=>open,mb_dout=>open,mb_din=>x"DEADDEAD",mb_done=>'0',
  io_fast_ena=>io_ena,io_fast_rnw=>io_rnw,io_fast_adr=>io_addr,io_fast_acc=>open,io_fast_be=>io_be,io_fast_dout=>io_data,io_fast_din=>x"DEADDEAD",
  vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,vram_fast_din=>open,vram_fast_dout=>(others=>'0'),
  vram_fast_done=>'0',vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',
  mr_fast_ok=>mr_ok,mr_fast_ena=>mr_ena,mr_fast_rnw=>mr_rnw,mr_fast_addr=>mr_addr,mr_fast_be=>open,mr_fast_wdata=>open,mr_fast_pair=>mr_pair,
  mr_fast_done=>mr_done,mr_fast_rdata=>mr_lo,mr_fast_rdata_hi=>mr_hi,irq_dma=>irq);

 process(clk)
  variable pending:boolean:=false;variable ticks,addr:natural:=0;
 begin
  if rising_edge(clk) then
   mr_done<='0';
   if reset='1' then cpu_wait<='0';writes<=0;reads<=0;completions<=0;pending:=false;ready_delay<=0;
   else
    if cpu_read='1' then cpu_wait<='1';end if;
    if cpu_complete='1' then cpu_wait<='0';completions<=completions+1;end if;
    if grant='0' then ready_delay<=0;elsif ready_delay<8 then ready_delay<=ready_delay+1;end if;
    assert mb_ena='0' report "parked CPU membus stolen" severity failure;
    if pending then
     assert grant='1' report "outstanding RAM ownership dropped" severity failure;
     if ticks=0 then mr_lo<=memword(addr);mr_hi<=memword(addr+4);mr_done<='1';pending:=false;
     else ticks:=ticks-1;end if;
    end if;
    if mr_ena='1' then
     assert grant='1' and mr_ok='1' and not pending and mr_rnw='1' and mr_pair='1' report "invalid RAM transaction" severity failure;
     pending:=true;ticks:=11;addr:=to_integer(unsigned(mr_addr))*4;reads<=reads+1;
    end if;
    if io_ena='1' then
     assert grant='1' and io_rnw='0' and io_ready='1' and writes<128 report "invalid IO acceptance" severity failure;
     trace_addr(writes)<=io_addr;trace_data(writes)<=io_data;trace_be(writes)<=io_be;writes<=writes+1;
    end if;
   end if;
  end if;
 end process;
 process
  procedure cycles(n:natural) is begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
  procedure reg(a:natural;d:std_logic_vector(31 downto 0)) is
  begin cycles(1);regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=d;regs.ena<='1';regs.rnw<='0';regs.bEna<="1111";cycles(1);regs.ena<='0';regs.rnw<='1';end;
  procedure init is
  begin reset<='1';gx_trigger<='0';cpu_read<='0';reply<='0';hblank<='0';vblank<='0';loader<='0';peek<='0';query_ready<='1';cache_idle<='1';locked<='0';io_ready<='1';ram_enabled<='1';cycles(3);reset<='0';cycles(2);end;
  procedure park_cpu is
  begin cpu_read<='1';cycles(1);cpu_read<='0';cycles(12);assert gx_busy='1' and cpu_wait='1' report "GX CPU wait missing" severity failure;end;
  variable source,destination:natural;variable ctrl:unsigned(31 downto 0);
 begin
  -- NSMB's exit uses a paired-halfword BG3X channel above BG1HOFS priority.
  -- Exercise both with and without an older, lower-priority GX request.
  for queued_gx in 0 to 1 loop
   init;
   reg(16#BC#,x"02001004");reg(16#C0#,x"04000038");reg(16#C4#,x"92600002");
   reg(16#C8#,x"02002000");reg(16#CC#,x"04000014");reg(16#D0#,x"92600001");
   if queued_gx=1 then reg(16#D4#,x"02003000");reg(16#D8#,x"04000400");reg(16#DC#,x"BC400004");end if;
   park_cpu;
   if queued_gx=1 then gx_trigger<='1';cycles(1);gx_trigger<='0';cycles(12);assert dma_on='1' and grant='0' severity failure;end if;
   for frame in 0 to 7 loop
    io_ready<='0';hblank<='1';cycles(1);hblank<='0';cycles(80);
    assert writes=frame*3 and cpu_wait='1' and completions=0 report "IO backpressure lost an update" severity failure;
    io_ready<='1';cycles(200);
    assert writes=(frame+1)*3 and reads=(frame+1)*2 report "paired HBlank blocked/dropped a channel" severity failure;
    assert trace_addr(frame*3)=x"0000038" and trace_be(frame*3)="0011" and trace_data(frame*3)=halfword(16#1004#+frame*4) report "BG3X low half mismatch" severity failure;
    assert trace_addr(frame*3+1)=x"0000038" and trace_be(frame*3+1)="1100" and trace_data(frame*3+1)=halfword(16#1006#+frame*4) report "BG3X high half mismatch" severity failure;
    assert trace_addr(frame*3+2)=x"0000014" and trace_be(frame*3+2)="0011" and trace_data(frame*3+2)=halfword(16#2000#+frame*2) report "BG1HOFS priority/pointer mismatch" severity failure;
    assert cpu_wait='1' and completions=0 report "fabricated CPU reply" severity failure;
    if queued_gx=1 then assert pending_bits(3)='1' report "preempted GX request lost" severity failure;end if;
   end loop;
  end loop;
  -- A real GX reply arriving between the pair's units must wait until
  -- both halfwords retire and the IO mux is returned to the CPU.
  init;
  reg(16#BC#,x"02001004");reg(16#C0#,x"04000038");reg(16#C4#,x"92600002");
  park_cpu;io_ready<='0';hblank<='1';cycles(1);hblank<='0';cycles(80);
  assert io_valid='1' and writes=0 and grant='1' severity failure;
  reply_id<=token;reply<='1';cycles(1);reply<='0';cycles(20);
  assert cpu_wait='1' and completions=0 report "reply escaped while paired IO stalled" severity failure;
  io_ready<='1';cycles(200);
  assert writes=2 and reads=1 and completions=1 and cpu_wait='0' and grant='0' report "paired transfer lost true CPU completion" severity failure;
  -- A pair must cover one aligned RAM word and one aligned 2D register.
  for bad in 0 to 6 loop
   init;source:=16#02001000#;destination:=16#04000038#;ctrl:=unsigned'(x"92600002");
   case bad is
    when 0=>source:=source+2;
    when 1=>destination:=destination+2;
    when 2=>ctrl(26):='1';
    when 3=>ctrl(24 downto 23):="01";
    when 4=>ctrl(22 downto 21):="10";
    when 5=>destination:=16#04000060#;
    when others=>ctrl(20 downto 0):=to_unsigned(3,21);
   end case;
   reg(16#BC#,std_logic_vector(to_unsigned(source,32)));reg(16#C0#,std_logic_vector(to_unsigned(destination,32)));reg(16#C4#,std_logic_vector(ctrl));
   park_cpu;hblank<='1';cycles(1);hblank<='0';cycles(150);
   assert grant='0' and reads=0 and writes=0 report "unsafe multi-unit overlap granted" severity failure;
  end loop;
  report "PASS: NSMB BG3X pair plus BG1 HBlank, repeated pointers/priority/backpressure, pending GX retention, unsafe pair rejection";
  stop;wait;
 end process;
end;
