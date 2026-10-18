-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pending IRQ at maintenance entry, capture park, reload, or return hold.
-- Authored guest counter and real ARM exception return are the oracle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_arm9_monitor_irq is
  generic(OPERATION:string:="capture"; THUMB:boolean:=false; MASKED:boolean:=false;
    HIGH_VECTOR:boolean:=true; IRQ_PHASE:natural:=0; STEP_PERIOD:positive:=1; READ_DELAY:positive:=1);
end;
architecture sim of tb_nds_arm9_monitor_irq is
  signal clk:std_logic:='0';signal ce:std_logic:='0';signal reset:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,hdin,hdout:std_logic_vector(31 downto 0):=(others=>'0');
  signal ha:unsigned(5 downto 0):=(others=>'0');
  signal ena,rnw,code,done,req,cont,restoring,active,paused,err,idle,hw,ready,release_run:std_logic:='0';
  signal irq,raise_irq,irq_acked:std_logic:='0';
  signal counter,initial_count,irq_count,traffic:natural:=0;
  signal saved_cpsr,saved_pc:std_logic_vector(31 downto 0):=(others=>'0');
  type snapshot_type is array(0 to 63) of std_logic_vector(31 downto 0);
  function instruction(a:std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"01FFFFF4"=>if HIGH_VECTOR then return x"E3A06A02";else return x"E3A06000";end if;
      when x"01FFFFF8"=>return x"EE016F10"; -- mcr control (no cache operation)
      when x"01FFFFFC"=>return x"EAFFFFFF";
      when x"02000000"=>if MASKED then return x"E321F0DF";else return x"E321F05F";end if;
      when x"02000004"=>return x"E3A00301"; -- output address
      when x"02000008"=>return x"E3A01000";
      when x"0200000C"=>return x"E3A02000";
      when x"02000010"=>return x"E3A03055";
      when x"02000014"=>return x"E10F4000";
      when x"02000018"=>if THUMB then return x"E28F5021";else return x"EA000000";end if;
      when x"0200001C"=>return x"E12FFF15";
      when x"02000020"=>return x"E2811001";
      when x"02000024"=>return x"E5801000";
      when x"02000028"=>return x"E5803004";
      when x"0200002C"=>return x"EAFFFFFB";
      when x"02000040"=>return x"00003101";
      when x"02000042"=>return x"00006001";
      when x"02000044"=>return x"00006043";
      when x"02000046"=>return x"0000E7FB";
      when x"00000018" | x"FFFF0018"=>return x"E580E010"; -- str lr,[r0,#16]
      when x"0000001C" | x"FFFF001C"=>return x"E14FD000"; -- mrs sp,spsr
      when x"00000020" | x"FFFF0020"=>return x"E580D014";
      when x"00000024" | x"FFFF0024"=>return x"E3A0D001";
      when x"00000028" | x"FFFF0028"=>return x"E580D018"; -- acknowledge external IRQ
      when x"0000002C" | x"FFFF002C"=>return x"E25EF004"; -- subs pc,lr,#4
      when others=>return x"EAFFFFFE";
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  irq<=raise_irq and not irq_acked;
  process begin
    for i in 1 to STEP_PERIOD loop
      wait until falling_edge(clk);if i=STEP_PERIOD then ce<='1';else ce<='0';end if;
    end loop;
  end process;
  dut:entity work.nds_arm9_monitor_probe
    port map(clk=>clk,ce=>ce,reset=>reset,preset=>ss,addr=>addr,rnw=>rnw,ena=>ena,seq=>open,
      code=>code,acc=>open,dout=>dout,din=>din,bus_done=>done,dma=>'0',irq=>irq,
      new_halt=>'0',unhalt=>'0',idle=>idle,halted=>open,request=>req,continue_run=>cont,
      memory_idle=>'1',cache_op_busy=>'0',restore=>restoring,active=>active,paused=>paused,error=>err,host_addr=>ha,
      host_write=>hw,host_din=>hdin,host_dout=>hdout,release_run=>release_run,ready=>ready);
  process(clk)
    variable pending:boolean:=false;
    variable remaining,expected:natural:=0;
    variable payload:std_logic_vector(31 downto 0);
    variable irq_lane:natural:=0;
  begin
    if rising_edge(clk) then
      if ce='1' then done<='0';end if;
      if reset='1' then expected:=initial_count;counter<=initial_count;irq_acked<='0';
      else
        assert err='0' report "monitor protocol error" severity failure;
        if pending then
          if remaining=0 then done<='1';din<=payload;pending:=false;
          else remaining:=remaining-1;end if;
        end if;
        if ena='1' then
          assert active='0' and not pending report "guest bus not isolated/drained" severity failure;
          if rnw='1' and (addr(31 downto 16)=x"0000" or addr(31 downto 16)=x"FFFF") then
            assert (addr(31 downto 16)=x"FFFF")=HIGH_VECTOR
              report "IRQ used wrong CP15 vector base" severity failure;
          end if;
          pending:=true;remaining:=READ_DELAY-1;payload:=instruction(addr);traffic<=traffic+1;
          if rnw='0' then
            case addr is
              when x"04000000"=>
                expected:=expected+1;
                assert unsigned(dout)=expected report "IRQ resume skipped or duplicated counter" severity failure;
                counter<=expected;
              when x"04000004"=>assert dout=x"00000055" report "IRQ damaged ordinary register" severity failure;
              when x"04000010"=>
                assert not MASKED and irq_lane=0 and irq_count=0 report "spurious or repeated IRQ" severity failure;
                assert unsigned(dout)=unsigned(saved_pc)+4 report "IRQ LR used stale maintenance PC: "&to_hstring(dout) severity failure;
                irq_lane:=1;
              when x"04000014"=>
                assert irq_lane=1 and dout=saved_cpsr report "IRQ SPSR lost original flags/mode" severity failure;
                irq_lane:=2;
              when x"04000018"=>
                assert irq_lane=2 and dout=x"00000001" report "IRQ acknowledgement sequence" severity failure;
                irq_lane:=3;irq_count<=irq_count+1;irq_acked<='1';
              when others=>assert false report "unexpected guest write" severity failure;
            end case;
          end if;
        end if;
        if active='1' then assert not pending report "maintenance entered before bus drained" severity failure;end if;
      end if;
    end if;
  end process;
  process
    file f:text;variable l:line;variable image:snapshot_type;variable before,base_count:natural;
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure await_ready is
    begin
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and paused='1' and active='1' and idle='1' report "missing coordinated return hold" severity failure;
    end;
  begin
    ss.rst<='1';clocks(4);ss.rst<='0';clocks(2);
    ss.Adr<=(others=>'0');ss.Din<=x"01FFFFF4";ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(4);
    if OPERATION="capture" then
      reset<='0';
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when counter>=5;end loop;
      assert counter>=5 report "guest failed to start" severity failure;
      req<='1';
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when active='1';end loop;
      assert active='1' report "capture failed to enter" severity failure;
      if IRQ_PHASE=0 then raise_irq<='1';end if;
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when paused='1';end loop;
      assert paused='1' report "capture failed to park" severity failure;
      if IRQ_PHASE=1 then raise_irq<='1';end if;
      for i in image'range loop ha<=to_unsigned(i,6);clocks(2);image(i):=hdout;end loop;
      file_open(f,"irq.state",write_mode);
      for i in image'range loop hwrite(l,image(i));writeline(f,l);end loop;file_close(f);
      saved_pc<=image(42);saved_cpsr<=image(43);base_count:=counter;
      req<='0';cont<='1';clocks(1);cont<='0';
    else
      file_open(f,"irq.state",read_mode);restoring<='1';clocks(2);
      for i in image'range loop
        readline(f,l);hread(l,image(i));ha<=to_unsigned(i,6);hdin<=image(i);hw<='1';clocks(1);
      end loop;hw<='0';file_close(f);
      saved_pc<=image(42);saved_cpsr<=image(43);initial_count<=to_integer(unsigned(image(1)));
      base_count:=to_integer(unsigned(image(1)));clocks(4);reset<='0';clocks(1);restoring<='0';
      if IRQ_PHASE<=1 then raise_irq<='1';end if;
    end if;
    if IRQ_PHASE=2 then clocks(10*STEP_PERIOD);raise_irq<='1';end if;
    await_ready;
    if IRQ_PHASE=3 then raise_irq<='1';end if;
    before:=traffic;clocks(100*STEP_PERIOD);
    assert traffic=before and irq_count=0 and ready='1' and active='1'
      report "IRQ or guest execution escaped return hold" severity failure;
    release_run<='1';clocks(1);release_run<='0';
    for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when counter>=base_count+20;end loop;
    assert counter>=base_count+20 report "IRQ return failed to resume guest" severity failure;
    if MASKED then assert irq_count=0 and irq='1' report "masked IRQ lost or delivered" severity failure;
    else assert irq_count=1 and irq='0' report "pending IRQ not delivered exactly once" severity failure;end if;
    report "PASS: pending IRQ held through maintenance and guest continuation preserved";
    stop;wait;
  end process;
  process begin wait for 20 ms;assert false report "IRQ monitor watchdog" severity failure;end process;
end;
