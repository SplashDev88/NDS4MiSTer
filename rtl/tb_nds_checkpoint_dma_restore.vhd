-- SPDX-License-Identifier: GPL-3.0-or-later
-- Fresh-process DMA continuations. External backing is an authored, immutable
-- source fixture; this is not a whole-memory checkpoint or game save state.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_dma_restore is
 generic(ARM9:boolean:=true;RESTORING:boolean:=false;SCENARIO:natural range 0 to 7:=0;
         LATENCY:positive:=2;WRITE_ORDER:natural range 0 to 2:=0);
end;
architecture sim of tb_nds_checkpoint_dma_restore is
 function image_size return positive is begin if ARM9 then return 37;else return 26;end if;end;
 constant N:positive:=image_size;
 constant FAST:boolean:=ARM9 and (SCENARIO=0 or SCENARIO=3 or SCENARIO=4);
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal regs:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal request,stopped,running,owned,cpu_idle,restore,cp_write,cp_valid,cp_ready,cp_error:std_logic:='0';
 signal cp_address:unsigned(5 downto 0):=(others=>'0');
 signal cp_data,cp_write_data,reg_data:std_logic_vector(31 downto 0):=(others=>'0');
 signal vblank,hblank,card,gx,credit,fast_ok:std_logic:='0';
 signal irq:std_logic_vector(3 downto 0);
 signal mb_ena,mb_rnw,mb_done,mr_ena,mr_rnw,mr_done,mr_pair,io_ena,io_rnw:std_logic:='0';
 signal mb_addr,mb_out,mb_in,mr_out,mr_lo,mr_hi,io_out:std_logic_vector(31 downto 0):=(others=>'0');
 signal mb_acc,mb_lowbits,io_acc:std_logic_vector(1 downto 0);
 signal mr_addr:std_logic_vector(21 downto 2);signal mr_be,io_be:std_logic_vector(3 downto 0);
 signal io_addr:std_logic_vector(27 downto 0);
 signal busy:std_logic_vector(0 to 1):="00";
 signal reset_counts:std_logic:='0';signal reads,writes,interrupts:natural:=0;
 function contents(a:natural) return std_logic_vector is
  variable aligned:natural:=a-a mod 4;variable w:std_logic_vector(31 downto 0);
 begin
  w:=std_logic_vector(to_unsigned((aligned/2+16#1234#) mod 65536,16)) & std_logic_vector(to_unsigned((aligned/2+16#ABCD#) mod 65536,16));
  return std_logic_vector(rotate_right(unsigned(w),(a mod 4)*8));
 end;
begin
 clk<=not clk after 5 ns;
 fast_ok<=owned when FAST else '0';
 nine:if ARM9 generate
  dut:entity work.nds_dma9 generic map(EXPERIMENTAL_CHECKPOINT=>true)
   port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>reg_data,wired_done=>open,
    checkpoint_stop=>request,checkpoint_stopped=>stopped,checkpoint_address=>cp_address,
    checkpoint_data=>cp_data,checkpoint_valid=>cp_valid,checkpoint_restore=>restore,checkpoint_write=>cp_write,
    checkpoint_write_data=>cp_write_data,checkpoint_restore_ready=>cp_ready,checkpoint_restore_error=>cp_error,
    trig_vblank=>vblank,trig_hblank=>hblank,trig_card=>card,gx_supported=>'1',trig_gx=>gx,gx_write_ready=>credit,
    cpu_bus_idle=>cpu_idle,dma_on=>running,dma_bus_on=>owned,
    mb_ena=>mb_ena,mb_rnw=>mb_rnw,mb_adr=>mb_addr,mb_acc=>mb_acc,mb_lowbits=>mb_lowbits,
    mb_dout=>mb_out,mb_din=>mb_in,mb_done=>mb_done,
    io_fast_ena=>io_ena,io_fast_rnw=>io_rnw,io_fast_adr=>io_addr,io_fast_acc=>io_acc,
    io_fast_be=>io_be,io_fast_dout=>io_out,io_fast_din=>x"12345678",
    vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,vram_fast_din=>open,
    vram_fast_dout=>(others=>'0'),vram_fast_done=>'0',vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',
    mr_fast_ok=>fast_ok,mr_fast_ena=>mr_ena,mr_fast_rnw=>mr_rnw,mr_fast_addr=>mr_addr,
    mr_fast_be=>mr_be,mr_fast_wdata=>mr_out,mr_fast_pair=>mr_pair,mr_fast_done=>mr_done,
    mr_fast_rdata=>mr_lo,mr_fast_rdata_hi=>mr_hi,irq_dma=>irq);
 end generate;
 seven:if not ARM9 generate
  mr_ena<='0';io_ena<='0';
  dut:entity work.nds_dma7 generic map(EXPERIMENTAL_CHECKPOINT=>true)
   port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>reg_data,wired_done=>open,
    checkpoint_stop=>request,checkpoint_stopped=>stopped,checkpoint_address=>cp_address,
    checkpoint_data=>cp_data,checkpoint_valid=>cp_valid,checkpoint_restore=>restore,checkpoint_write=>cp_write,
    checkpoint_write_data=>cp_write_data,checkpoint_restore_ready=>cp_ready,checkpoint_restore_error=>cp_error,
    trig_vblank=>vblank,trig_card=>card,cpu_bus_idle=>cpu_idle,dma_on=>running,dma_bus_on=>owned,
    mb_ena=>mb_ena,mb_rnw=>mb_rnw,mb_adr=>mb_addr,mb_acc=>mb_acc,mb_lowbits=>mb_lowbits,
    mb_dout=>mb_out,mb_din=>mb_in,mb_done=>mb_done,irq_dma=>irq);
 end generate;
 memory:process(clk)
  type bools is array(0 to 1) of boolean;
  type naturals is array(0 to 1) of natural;
  variable pending,reading:bools:=(others=>false);
  variable delay,address:naturals:=(others=>0);
  variable read_total,write_total,irq_total:natural:=0;
  type channel_counts is array(0 to 3) of natural;
  variable copied:channel_counts:=(others=>0);
  variable channel,width,source_address,dest_address:natural;
  variable payload,expected_copy:std_logic_vector(31 downto 0);
 begin
  if rising_edge(clk) then
   mb_done<='0';mr_done<='0';
   if reset='1' or reset_counts='1' then
    assert not pending(0) and not pending(1) report "fixture reset discarded accepted DMA work" severity failure;
    read_total:=0;write_total:=0;irq_total:=0;copied:=(others=>0);
   else
    for p in 0 to 1 loop
     if pending(p) then
      if delay(p)=0 then
       if reading(p) then
        if p=0 then mb_in<=contents(address(p));else mr_lo<=contents(address(p));mr_hi<=contents(address(p)+4);end if;
        read_total:=read_total+1;
       else write_total:=write_total+1;end if;
       if p=0 then mb_done<='1';else mr_done<='1';end if;pending(p):=false;
      else delay(p):=delay(p)-1;end if;
     end if;
     if (p=0 and mb_ena='1') or (p=1 and mr_ena='1') then
      assert not pending(p) and owned='1' report "overlapping/unowned DMA memory request" severity failure;
      pending(p):=true;
      if p=0 then address(p):=to_integer(unsigned(mb_addr));reading(p):=mb_rnw='1';
      else
       address(p):=16#02000000#+to_integer(unsigned(mr_addr))*4;reading(p):=mr_rnw='1';
       if reading(p) then assert mr_pair='1' and address(p) mod 8=0 report "invalid DMA pair read" severity failure;end if;
      end if;
      if SCENARIO=0 and not reading(p) then
       assert address(p)>=16#02008080# and address(p)<16#02008400# report "independent DMA destination range failed" severity failure;
       channel:=(address(p)-16#02008080#+128)/256;
       if channel mod 2=0 then width:=4;else width:=2;end if;
       source_address:=16#02001080#+channel*256;
       if channel mod 3=0 then source_address:=source_address+copied(channel)*width;
       elsif channel mod 3=1 then source_address:=source_address-copied(channel)*width;end if;
       dest_address:=16#02008080#+channel*256;
       if channel mod 3=0 then dest_address:=dest_address+copied(channel)*width;
       elsif channel mod 3=1 then dest_address:=dest_address-copied(channel)*width;end if;
       if p=0 then assert address(p)=dest_address report "independent DMA destination step failed" severity failure;
       else assert address(p)=dest_address-dest_address mod 4 report "independent fast DMA destination step failed" severity failure;end if;
       expected_copy:=contents(source_address);
       if p=0 then payload:=mb_out;else payload:=mr_out;end if;
       if width=4 then assert payload=expected_copy report "independent DMA word copy check failed" severity failure;
       else
        if p=0 then
         assert payload=expected_copy(15 downto 0)&expected_copy(15 downto 0) report "independent DMA halfword copy/replication failed" severity failure;
        elsif dest_address mod 4=0 then
         assert mr_be="0011" and payload(15 downto 0)=expected_copy(15 downto 0) report "DMA low halfword lane/data failed" severity failure;
        else
         assert mr_be="1100" and payload(31 downto 16)=expected_copy(15 downto 0) report "DMA high halfword lane/data failed" severity failure;
        end if;
       end if;
       copied(channel):=copied(channel)+1;
      end if;
      if SCENARIO=7 and not reading(p) then
       source_address:=(2-integer(copied(0))*2) mod 16#10000000#;
       dest_address:=16#03000002#-copied(0)*2;
       expected_copy:=contents(source_address);
       assert p=0 and address(p)=dest_address and mb_out=expected_copy(15 downto 0)&expected_copy(15 downto 0)
        report "independent DMA decrement/wrap copy failed" severity failure;
       copied(0):=copied(0)+1;
      end if;
      delay(p):=LATENCY-1+(address(p)/4) mod 3;
     end if;
    end loop;
    if io_ena='1' then
     assert owned='1' and io_rnw='0' and io_addr=x"0000400" and credit='1' report "invalid/uncredited GX write" severity failure;
     write_total:=write_total+1;
    end if;
    for c in 0 to 3 loop if irq(c)='1' then irq_total:=irq_total+1;end if;end loop;
   end if;
   if stopped='1' then
    assert not pending(0) and not pending(1) and owned='0' and running='0' and mb_ena='0' and mr_ena='0' and io_ena='0' and irq="0000"
     report "DMA falsely acknowledged outstanding backing work" severity failure;
   end if;
   if restore='1' and reset='1' then
    assert owned='0' and running='0' and mb_ena='0' and mr_ena='0' and io_ena='0' and irq="0000"
     report "DMA executed an incomplete restore" severity failure;
   end if;
   for p in 0 to 1 loop if pending(p) then busy(p)<='1';else busy(p)<='0';end if;end loop;
   reads<=read_total;writes<=write_total;interrupts<=irq_total;
  end if;
 end process;
 stimulus:process
  file state_file,trace_file:text;variable line_buffer:line;
  type words is array(natural range <>) of std_logic_vector(31 downto 0);
  variable image:words(0 to N-1);variable observation:words(0 to 10);
  variable expected,actual:std_logic_vector(351 downto 0);
  variable observed:natural:=0;variable mutation:std_logic_vector(31 downto 0);
  procedure step(n:positive:=1) is begin for k in 1 to n loop wait until rising_edge(clk);wait for 1 ns;end loop;end;
  procedure reg(a:natural;d:std_logic_vector(31 downto 0)) is
  begin
   regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=d;regs.ena<='1';regs.rnw<='0';regs.bEna<="1111";
   step;regs.ena<='0';regs.rnw<='1';step;
  end;
  procedure setup(c:natural;source,dest:natural;count:positive;timing:natural:=0;repeat_mode:boolean:=false;word32:boolean:=true;src_mode:natural:=0;dst_mode:natural:=0) is
   variable control:unsigned(31 downto 0);
  begin
   reg(16#B0#+c*12,std_logic_vector(to_unsigned(source,32)));reg(16#B4#+c*12,std_logic_vector(to_unsigned(dest,32)));
   control:=unsigned'(x"C0000000") or to_unsigned(count,32) or shift_left(to_unsigned(src_mode,32),23) or shift_left(to_unsigned(dst_mode,32),21);
   if ARM9 then control:=control or shift_left(to_unsigned(timing,32),27);else control:=control or shift_left(to_unsigned(timing,32),28);end if;
   if repeat_mode then control(25):='1';end if;if word32 then control(26):='1';end if;
   reg(16#B8#+c*12,std_logic_vector(control));
  end;
  procedure await_hold is
  begin
   for k in 1 to 40000 loop step;exit when stopped='1' and busy="00";end loop;
   assert stopped='1' and busy="00" report "DMA fixture failed to drain" severity failure;step(4);
  end;
  procedure load_word(a:natural;v:std_logic_vector(31 downto 0)) is
  begin cp_address<=to_unsigned(a,6);cp_write_data<=v;cp_write<='1';step;cp_write<='0';step(2+a mod 3);end;
  procedure load_image is variable a:natural;
  begin
   for slot in 0 to N-1 loop
    case WRITE_ORDER is when 0=>a:=slot;when 1=>a:=N-1-slot;when others=>a:=(slot*5) mod N;end case;
    load_word(a,image(a));
    if slot<N-1 then assert cp_ready='0' report "incomplete DMA restore accepted" severity failure;end if;
   end loop;
   assert cp_ready='1' and cp_error='0' report "complete DMA restore never ready" severity failure;
  end;
  procedure read_image(compare:boolean) is
  begin
   for a in 0 to N-1 loop
    cp_address<=to_unsigned(a,6);wait for 1 ns;
    assert cp_valid='1' report "DMA component image unavailable" severity failure;
    if compare then assert cp_data=image(a) report "DMA restored word differs at " & integer'image(a) severity failure;
    else image(a):=cp_data;end if;
   end loop;
   for a in N to 63 loop
    cp_address<=to_unsigned(a,6);wait for 1 ns;
    assert cp_valid='0' and cp_data=x"00000000" report "undefined DMA address exposed state" severity failure;
   end loop;
  end;
  procedure capture_guards is
   variable old_gx:std_logic;
  begin
   cp_address<=(others=>'0');old_gx:=gx;
   -- Sub-cycle probes never deliver a new trigger to the state machine.
   wait until falling_edge(clk);regs.ena<='1';regs.rnw<='1';wait for 1 ns;
   assert cp_valid='0' and cp_data=x"00000000" report "DMA exposed unstable bus capture" severity failure;regs.ena<='0';
   wait until falling_edge(clk);vblank<='1';wait for 1 ns;
   assert cp_valid='0' and cp_data=x"00000000" report "DMA exposed unstable trigger capture" severity failure;vblank<='0';
   wait until falling_edge(clk);card<='1';wait for 1 ns;
   assert cp_valid='0' report "DMA exposed unstable card capture" severity failure;card<='0';
   if ARM9 then
    wait until falling_edge(clk);hblank<='1';wait for 1 ns;
    assert cp_valid='0' report "DMA exposed unstable HBlank capture" severity failure;hblank<='0';
    wait until falling_edge(clk);gx<=not old_gx;wait for 1 ns;
    assert cp_valid='0' report "DMA exposed unsettled GX history" severity failure;gx<=old_gx;
   end if;
   step(3);
  end;
  procedure observe is
  begin
   observation:=(others=>(others=>'0'));
   observation(0)(11 downto 0):=irq&"00"&stopped&owned&running&io_ena&mr_ena&mb_ena;
   observation(1):=reg_data;
   if mb_ena='1' then
    observation(2):=mb_addr;if mb_rnw='0' then observation(3):=mb_out;end if;
    observation(4)(4 downto 0):=mb_lowbits&mb_acc&mb_rnw;
   end if;
   if mr_ena='1' then
    observation(5)(21 downto 2):=mr_addr;if mr_rnw='0' then observation(6):=mr_out;end if;
    observation(7)(5 downto 0):=mr_be&mr_pair&mr_rnw;
   end if;
   if io_ena='1' then
    observation(8)(27 downto 0):=io_addr;if io_rnw='0' then observation(9):=io_out;end if;
    observation(10)(6 downto 0):=io_be&io_acc&io_rnw;
   end if;
   for w in 0 to 10 loop actual((11-w)*32-1 downto (10-w)*32):=observation(w);end loop;
   if RESTORING then
    assert not endfile(trace_file) report "DMA trace truncated" severity failure;readline(trace_file,line_buffer);hread(line_buffer,expected);
    assert actual=expected report "DMA continuation differs at observation " & integer'image(observed) & " actual=" & to_hstring(actual) & " expected=" & to_hstring(expected) severity failure;
   else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
   observed:=observed+1;
  end;
 begin
  request<='1';cpu_idle<='1';credit<='1';step(4);
  if RESTORING then
   file_open(state_file,"dma.state",read_mode);
   for a in 0 to N-1 loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
   assert endfile(state_file) report "invalid DMA image length" severity failure;file_close(state_file);
   restore<='1';vblank<='1';hblank<='1';card<='1';if SCENARIO/=3 then gx<='1';end if;
   regs.ena<='1';regs.rnw<='0';regs.Adr<=x"00000B8";regs.Din<=x"FFFFFFFF";step;
   load_image;read_image(true);
   for bad in 0 to 5 loop
    mutation:=(others=>'0');
    case bad is
     when 0=>load_word(N,mutation);
     when 1=>load_word(63,mutation);
     when 2=>load_word(0,x"10000000");
     when 3=>load_word(5,x"20000000");
     when 4=>if ARM9 then load_word(5,x"00200001");else load_word(5,x"00004001");end if;
     when others=>if ARM9 then load_word(28,x"00000E20");else load_word(2,x"08000000");end if;
    end case;
    assert cp_error='1' and cp_ready='0' and cp_valid='0' and cp_data=x"00000000" report "invalid DMA image accepted" severity failure;
    load_word(0,image(0));assert cp_error='1' and cp_ready='0' report "invalid DMA attempt silently recovered" severity failure;
    restore<='0';step;restore<='1';step;assert cp_ready='0' report "DMA attempt retained old coverage" severity failure;
    load_image;read_image(true);
   end loop;
   regs.ena<='0';regs.rnw<='1';vblank<='0';hblank<='0';card<='0';
   if SCENARIO=3 then gx<='1';else gx<='0';end if;
   restore<='0';reset<='0';await_hold;read_image(true);
   for a in 0 to N-1 loop
    restore<='1';load_word(a,(31 downto 0=>'0'));
    assert cp_error='1' and cp_ready='0' and cp_valid='0' report "live DMA restore accepted" severity failure;
    restore<='0';step(3);read_image(true);
   end loop;
   file_open(trace_file,"dma.trace",read_mode);
  else
   reset<='0';step(4);
   if ARM9 and SCENARIO/=6 then for c in 0 to 3 loop reg(16#E0#+c*4,std_logic_vector(unsigned'(x"F1110000")+c));end loop;end if;
   case SCENARIO is
    when 0=>for c in 0 to 3 loop setup(c,16#02001080#+c*256,16#02008080#+c*256,5+c,0,false,c mod 2=0,c mod 3,c mod 3);end loop;
    when 1=>
     setup(0,16#02001000#,16#02008000#,8,1,true,true,0,3);
     request<='0';vblank<='1';step;vblank<='0';
     for k in 1 to 10000 loop step;exit when writes>=2;end loop;
     assert writes>=2 report "repeat fixture failed to start" severity failure;
     request<='1';vblank<='1';step;vblank<='0';await_hold;
    when 2=>
     if ARM9 then setup(0,16#02001002#,16#02008002#,5,5,true,false,0,2);
     else setup(0,16#02001002#,16#02008002#,5,2,true,false,0,2);end if;
     card<='1';step;card<='0';
    when 3=>
     assert ARM9 report "GX fixture only supports ARM9" severity failure;
     setup(0,16#02001000#,16#04000400#,230,7,false,true,0,2);gx<='1';request<='0';
     for k in 1 to 10000 loop step;exit when writes>=2;end loop;request<='1';await_hold;
     assert writes=112 report "GX fixture missed partial slice boundary" severity failure;
    when 4=>
     assert FAST report "prefetch fixture requires ARM9 fast lane" severity failure;
     setup(0,16#02001000#,16#03008000#,17,1,true,true,0,3);
     request<='0';vblank<='1';step;vblank<='0';
     for k in 1 to 10000 loop step;exit when writes>=2;end loop;
     request<='1';vblank<='1';step;vblank<='0';await_hold;
    when 5=>if ARM9 then setup(0,16#02001000#,16#02008000#,7,2,true);else setup(0,16#02001000#,16#02008000#,7,1,true);end if;
    when 6=>null;
    when 7=>setup(0,2,16#03000002#,3,0,false,false,1,1);
   end case;
   await_hold;read_image(false);
   if SCENARIO=3 then assert image(5)=x"80000076" and image(28)(2)='1' report "GX image lacks remaining count/history" severity failure;end if;
   if SCENARIO=4 then assert image(28)(4 downto 3)/="00" report "fixture lacks retained prefetch" severity failure;end if;
   if SCENARIO=6 then for a in 0 to N-1 loop assert image(a)=x"00000000" report "fixture lacks all-zero DMA image" severity failure;end loop;end if;
   file_open(state_file,"dma.state",write_mode);for a in 0 to N-1 loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
   file_open(trace_file,"dma.trace",write_mode);
  end if;
  capture_guards;
  if SCENARIO=6 then setup(0,16#02001000#,16#02008000#,4);end if;
  reset_counts<='1';step;reset_counts<='0';
  for i in 0 to 8191 loop
   request<='0';if (i>=300 and i<325) or i>=7500 then request<='1';end if;
   credit<='1';if i mod 11<3 then credit<='0';end if;
   cpu_idle<='1';if i mod 13<2 then cpu_idle<='0';end if;
   vblank<='0';hblank<='0';card<='0';
   if i=100 or i=1000 or i=3000 or i=5000 then vblank<='1';hblank<='1';card<='1';end if;
   regs.Adr<=std_logic_vector(to_unsigned(16#B0#+(i mod 16)*4,28));
   wait for 1 ns;observe;step;observe;
  end loop;
  assert stopped='1' and busy="00" and reads>0 and writes>0 and interrupts>0 report "restored DMA failed to complete useful work" severity failure;
  if RESTORING then assert endfile(trace_file) report "DMA trace has trailing data" severity failure;end if;file_close(trace_file);
  report "CHECKPOINT_DMA_RESTORE_PASS ARM9=" & boolean'image(ARM9) & " restoring=" & boolean'image(RESTORING) &
   " scenario=" & integer'image(SCENARIO) & " latency=" & integer'image(LATENCY) & " order=" & integer'image(WRITE_ORDER) &
   " observations=" & integer'image(observed) & " reads=" & integer'image(reads) & " writes=" & integer'image(writes) & " IRQs=" & integer'image(interrupts);
  std.env.stop;wait;
 end process;
 process begin wait for 3 ms;assert false report "DMA restore watchdog" severity failure;end process;
end;
