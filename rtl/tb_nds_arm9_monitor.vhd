-- SPDX-License-Identifier: GPL-3.0-or-later
-- Same authored program, ordinary bus trace, three separate processes:
-- disabled baseline; capture/continue; fresh-process restore from 64 words.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_arm9_monitor is
  generic(SLEEP_MODE:boolean:=false; OPERATION:string:="baseline"; READ_DELAY:positive:=1;
    STEP_PERIOD:positive:=1; EARLY_CAPTURE:boolean:=false;
    CORRUPT_WORD:integer:=-1; CANCEL_DMA:boolean:=false;
    EXPECT_REJECT:boolean:=false);
end;
architecture sim of tb_nds_arm9_monitor is
  type image_type is array(0 to 1023) of std_logic_vector(31 downto 0);
  impure function read_image return image_type is
    file f:text open read_mode is "guest.hex";
    variable l:line;variable a:image_type:=(others=>x"EAFFFFFE");variable i:natural:=0;
  begin
    while not endfile(f) loop readline(f,l);hread(l,a(i));i:=i+1;end loop;
    return a;
  end;
  constant rom:image_type:=read_image;
  signal clk:std_logic:='0';signal ce:std_logic:='0';signal reset:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,hdin,hdout:std_logic_vector(31 downto 0):=(others=>'0');
  signal ha:unsigned(5+boolean'pos(SLEEP_MODE) downto 0):=(others=>'0');
  signal ena,rnw,code,done,req,cont,restoring,active,paused,err,idle,hw,dma,halted:std_logic:='0';
  signal write_count,initial_count:natural:=0;
  signal release_run,ready:std_logic:='0';
  signal pending_bus:boolean:=false;
  signal memory_idle:std_logic:='1';signal cache_busy,cache_ena:std_logic:='0';
  type snapshot_type is array(0 to 63+14*boolean'pos(SLEEP_MODE)) of std_logic_vector(31 downto 0);
begin
  clk<=not clk after 5 ns;
  process begin
    for i in 1 to STEP_PERIOD loop
      wait until falling_edge(clk);
      if i=STEP_PERIOD then ce<='1';else ce<='0';end if;
    end loop;
  end process;
  dut:entity work.nds_arm9_monitor_probe generic map(ENABLED=>OPERATION/="baseline",SLEEP_ENABLED=>SLEEP_MODE)
    port map(clk=>clk,ce=>ce,reset=>reset,preset=>ss,addr=>addr,rnw=>rnw,ena=>ena,seq=>open,
      code=>code,acc=>open,dout=>dout,din=>din,bus_done=>done,dma=>dma,
      irq=>'0',new_halt=>'0',unhalt=>'0',idle=>idle,halted=>halted,
      memory_idle=>memory_idle,cache_op_busy=>cache_busy,cache_op_ena=>cache_ena,
      request=>req,continue_run=>cont,restore=>restoring,active=>active,paused=>paused,error=>err,
      host_addr=>ha,host_write=>hw,host_din=>hdin,host_dout=>hdout,release_run=>release_run,ready=>ready);
  process
    file trace:text;
    variable l:line;variable ea,ev:std_logic_vector(31 downto 0);
    variable pending:boolean:=false;
    variable remaining,index,count:natural:=0;
    variable payload:std_logic_vector(31 downto 0);
  begin
    if OPERATION="baseline" then file_open(trace,"baseline.trace",write_mode);
    else file_open(trace,"baseline.trace",read_mode);end if;
    wait until reset='0';
    if OPERATION="restore" then
      for i in 1 to initial_count loop readline(trace,l);end loop;
    end if;
    count:=initial_count;
    loop
      wait until rising_edge(clk);
      assert cache_ena='0' report "monitor issued destructive cache maintenance" severity failure;
      assert err='0' or EXPECT_REJECT report "monitor reported a protocol error" severity failure;
      if ce='1' then done<='0';end if;
      if pending then
        if remaining=0 then done<='1';din<=payload;pending:=false;
        else remaining:=remaining-1;end if;
      end if;
      if ena='1' then
        assert active='0' report "monitor touched guest bus" severity failure;
        assert not pending report "overlapping guest bus request" severity failure;
        pending:=true;remaining:=READ_DELAY-1;
        if rnw='1' then
          assert addr(31 downto 12)=x"02000" report "unexpected guest read "&to_hstring(addr) severity failure;
          index:=to_integer(unsigned(addr(11 downto 2)));payload:=rom(index);
          if addr(1)='1' then payload:=x"0000"&rom(index)(31 downto 16);end if;
        else
          assert code='0' and addr(31 downto 6)=std_logic_vector(to_unsigned(16#04000000#/64,26))
            report "unexpected guest store "&to_hstring(addr) severity failure;
          count:=count+1;write_count<=count;
          if OPERATION="baseline" then
            hwrite(l,addr);write(l,string'(" "));hwrite(l,dout);writeline(trace,l);
          else
            assert not endfile(trace) report "trace exhausted" severity failure;
            readline(trace,l);hread(l,ea);hread(l,ev);
            assert ea=addr and ev=dout
              report "guest continuation mismatch at store "&integer'image(count)&
                " expected "&to_hstring(ea)&"="&to_hstring(ev)&
                " got "&to_hstring(addr)&"="&to_hstring(dout) severity failure;
          end if;
          payload:=(others=>'0');
        end if;
      end if;
      if active='1' then assert not pending report "entry with outstanding guest bus operation" severity failure;end if;
      pending_bus<=pending;
    end loop;
  end process;
  process
    file f:text;variable l:line;variable saved,reread:snapshot_type;
    variable before,position:natural;
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure read_snapshot(variable v:out snapshot_type) is
    begin for i in v'range loop ha<=to_unsigned(i,ha'length);clocks(2);v(i):=hdout;end loop;end;
    procedure pause_cpu is
    begin
      req<='1';
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when paused='1';end loop;
      assert paused='1' report "monitor entry timed out" severity failure;
      assert active='1' and idle='1' and ena='0' and not pending_bus
        report "park before bus drained" severity failure;
    end;
    procedure release_return is
      variable held_count:natural;
    begin
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and paused='1' and active='1' and idle='1' and not pending_bus
        report "restored context was not held for common release" severity failure;
      held_count:=write_count;
      -- Continue is only a load command; it must not release a ready context.
      cont<='1';clocks(100*STEP_PERIOD);cont<='0';
      assert ready='1' and paused='1' and active='1' and write_count=held_count and ena='0'
        report "guest escaped before common release" severity failure;
      release_run<='1';clocks(1);release_run<='0';clocks(1);
      assert ready='0' and active='0' report "common release failed" severity failure;
    end;
  begin
    ss.rst<='1';clocks(4);ss.rst<='0';clocks(2);
    ss.Adr<=(others=>'0');ss.Din<=x"02000000";ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(4);
    if OPERATION="restore" then
      restoring<='1';clocks(2);
      file_open(f,"monitor.state",read_mode);
      readline(f,l);read(l,position);initial_count<=position;
      for i in saved'range loop
        readline(f,l);hread(l,saved(i));
        if i=CORRUPT_WORD then
          if EXPECT_REJECT and i=42 then saved(i)(0):='1';
          elsif EXPECT_REJECT and i=43 then saved(i)(4):='0';
          elsif i=43 then saved(i):=saved(i) xor x"08000000";
          elsif i=45 then saved(i):=saved(i) xor x"00001000";
          else saved(i):=saved(i) xor x"00000100";end if;
        end if;
        ha<=to_unsigned(i,ha'length);hdin<=saved(i);hw<='1';clocks(1);
      end loop;hw<='0';file_close(f);clocks(4);
      memory_idle<='0';reset<='0';clocks(1);restoring<='0';
      clocks(5000*STEP_PERIOD);
      assert active='1' and paused='0' and ready='0' and ena='0' and write_count=0
        report "fresh load ran before memory drained" severity failure;
      memory_idle<='1';
      if EXPECT_REJECT then
        for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when err='1';end loop;
        assert err='1' and active='1' report "invalid return state was not rejected" severity failure;
        clocks(100*STEP_PERIOD);
        assert write_count=0 and ena='0' report "invalid restore reached guest" severity failure;
        report "PASS: invalid return metadata rejected before guest execution";
        stop;wait;
      end if;
      release_return;
      for i in 1 to 500000*STEP_PERIOD loop clocks(1);exit when write_count>=position+800;end loop;
      assert write_count>=position+800 report "fresh restore made no progress" severity failure;
      report "PASS: fresh-process CPU-assisted restore matched 800 guest stores";
    else
      reset<='0';
      if OPERATION="cancel" then
        for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when write_count>=100;end loop;
        assert write_count>=100 report "straight-line guest did not start" severity failure;
        req<='1';clocks(100*STEP_PERIOD);
        assert active='0' and paused='0' report "monitor entered without a retired branch" severity failure;
        req<='0';before:=write_count;
        for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when write_count>=before+800;end loop;
        assert write_count>=before+800 report "cancelled straight-line request stalled CPU" severity failure;
        report "PASS: no-boundary request cancelled and 800 subsequent stores match baseline";
      elsif OPERATION="capture" then
        if not EARLY_CAPTURE then
          for i in 1 to 500000*STEP_PERIOD loop clocks(1);exit when write_count>=100;end loop;
          assert write_count>=100 report "guest did not start" severity failure;
        end if;
        if CANCEL_DMA then
          dma<='1';req<='1';clocks(100*STEP_PERIOD);
          assert active='0' report "monitor entered with DMA owning bus" severity failure;
          req<='0';dma<='0';before:=write_count;
          for i in 1 to 500000*STEP_PERIOD loop clocks(1);exit when write_count>=before+80;end loop;
          assert write_count>=before+80 report "cancelled request stalled CPU" severity failure;
        end if;
        if not EARLY_CAPTURE then
          -- Cache maintenance blocks the boundary. Background memory work
          -- instead drains AFTER the branch is retired and its fetch suppressed.
          cache_busy<='1';req<='1';clocks(300*STEP_PERIOD);
          assert active='0' report "monitor ignored cache operation" severity failure;
          req<='0';cache_busy<='0';memory_idle<='0';req<='1';
          for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when active='1';end loop;
          assert active='1' report "monitor failed to stop before draining" severity failure;
          before:=write_count;clocks(5000*STEP_PERIOD);
          assert paused='0' and write_count=before and ena='0'
            report "monitor ran before memory drained" severity failure;
          memory_idle<='1';
        end if;
        pause_cpu;position:=write_count;read_snapshot(saved);clocks(50);read_snapshot(reread);
        assert saved=reread and write_count=position report "parked state changed" severity failure;
        file_open(f,"monitor.state",write_mode);write(l,position);writeline(f,l);
        for i in saved'range loop hwrite(l,saved(i));writeline(f,l);end loop;file_close(f);
        -- An accidental live host write must not modify a captured slot.
        ha<=to_unsigned(0,ha'length);hdin<=x"DEADBEEF";hw<='1';clocks(2);hw<='0';read_snapshot(reread);
        assert saved=reread report "live host write changed snapshot" severity failure;
        req<='0';cont<='1';clocks(1);cont<='0';
        release_return;
        for i in 1 to 500000*STEP_PERIOD loop clocks(1);exit when write_count>=position+800;end loop;
        assert write_count>=position+800 report "continue made no progress" severity failure;
        pause_cpu;before:=write_count;read_snapshot(reread);
        assert saved(42)=reread(42) and saved(1)/=reread(1)
          report "second capture did not refresh its context" severity failure;
        req<='0';cont<='1';clocks(1);cont<='0';
        release_return;
        for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when write_count>=before+80;end loop;
        assert write_count>=before+80 report "second continue lost progress" severity failure;
        report "PASS: capture/continue matched disabled guest trace; snapshot stable and isolated";
      else
        for i in 1 to 500000*STEP_PERIOD loop clocks(1);exit when write_count>=4000;end loop;
        assert write_count>=4000 report "baseline made no progress" severity failure;
        report "PASS: disabled baseline produced 4000 guest stores";
      end if;
    end if;
    stop;wait;
  end process;
  process begin wait for 100 ms;assert false report "watchdog" severity failure;end process;
end;
