-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored real CPU pair with private monitor RAM and asynchronous clocks.
-- Memory responder/extra owners are synthetic; this is not whole-game resume.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_monitor_capture is
  generic(SCENARIO:string:="normal";SLEEP7:boolean:=false;SLEEP9:boolean:=false;
    STEP7:positive:=1;READ_DELAY:positive:=1;HOLD_RETURN:boolean:=false);
end;
architecture sim of tb_nds_checkpoint_monitor_capture is
  type words is array(0 to 1) of std_logic_vector(31 downto 0);
  type addresses is array(0 to 1) of std_logic_vector(7 downto 0);
  type counts is array(0 to 1) of natural;
  type image_type is array(0 to 1,0 to 77) of std_logic_vector(31 downto 0);
  signal clk:std_logic_vector(1 downto 0):="00";
  signal ctl,reset:std_logic:='0';
  signal clock7_run:boolean:=true;
  signal ce,req,active,paused,mready,merror,cont,rel,ena,rnw,done,halt,wake,newhalt,pending_bus:std_logic_vector(1 downto 0):="00";
  signal addr,din,dout,ram_data:words:=(others=>(others=>'0'));
  signal transport_addr,host_addr:addresses:=(others=>(others=>'0'));
  signal reference_addr:std_logic_vector(7 downto 0):=(others=>'0');
  signal reference_read:std_logic:='0';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal completed:counts:=(0,0);
  signal request,pair_req,ready,busy,held,timeout,stalled,expired,permit:std_logic:='0';
  signal epoch,rd_epoch,result_epoch:unsigned(31 downto 0):=(others=>'0');
  signal rd_strobe,rd_cpu,rd_ready,rd_done,rd_error:std_logic:='0';
  signal rd_address:std_logic_vector(7 downto 0):=(others=>'0');
  signal rd_data,format_id:std_logic_vector(31 downto 0);
  signal count9,count7:unsigned(7 downto 0);
  signal owner_loss:std_logic:='0';
  signal owners:std_logic_vector(1 downto 0);
  function instruction(cpu:natural;a:std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"02000000"=>return x"E321F0DF";
      when x"02000004"=>return x"E3A00301";
      when x"02000008"=>return x"E3A01000";
      when x"0200000C"=>return x"E2811001";
      when x"02000010"=>return x"E5801000";
      when x"02000014"=>if cpu=0 and SLEEP9 then return x"EE070F90";else return x"E1A00000";end if;
      when x"02000018"=>return x"EAFFFFFB";
      when others=>return x"EAFFFFFE";
    end case;
  end;
begin
  ctl<=not ctl after 5 ns;clk(0)<=not clk(0) after 7 ns;
  process begin wait for 11 ns;if clock7_run then clk(1)<=not clk(1);end if;end process;
  ce(0)<='1';
  process begin for i in 1 to STEP7 loop wait until falling_edge(clk(1));
    if i=STEP7 then ce(1)<='1';else ce(1)<='0';end if;end loop;end process;
  owners <= "11" when pair_req='1' and owner_loss='0' else "00";
  capture_unit:entity work.nds_checkpoint_monitor_capture
    generic map(TIMEOUT_CYCLES=>100000,LEASE_CYCLES=>20000,READ_TIMEOUT_CYCLES=>100,REQUIRE_OWNERS=>true)
    port map(clk=>ctl,clk9=>clk(0),clk7=>clk(1),reset=>reset,request=>request,
      keepalive=>'0',keepalive_epoch=>epoch,ready=>ready,busy=>busy,pair_paused=>held,
      timed_out=>timeout,release_stalled=>stalled,lease_expired=>expired,epoch=>epoch,hold_request=>pair_req,
      cpu_request9=>req(0),cpu_request7=>req(1),cpu_paused9=>paused(0),cpu_paused7=>paused(1),
      read_strobe=>rd_strobe,read_cpu=>rd_cpu,read_address=>rd_address,read_epoch=>rd_epoch,
      read_ready=>rd_ready,read_done=>rd_done,read_error=>rd_error,read_data=>rd_data,result_epoch=>result_epoch,
      cpu_address9=>transport_addr(0),cpu_address7=>transport_addr(1),cpu_data9=>ram_data(0),cpu_data7=>ram_data(1),
      cpu_valid9=>paused(0),cpu_valid7=>paused(1),owners_paused=>owners,owners_seen=>pair_req & pair_req,
      monitor_active=>active,monitor_ready=>mready,monitor_error=>merror,monitor_continue=>cont,monitor_release=>rel,
      return_permission=>permit,capture_format=>format_id,capture_words9=>count9,capture_words7=>count7);
  host_addr(0)<=reference_addr when reference_read='1' else transport_addr(0);
  host_addr(1)<=reference_addr when reference_read='1' else transport_addr(1);
  cpu9:entity work.nds_arm9_monitor_probe generic map(SLEEP_ENABLED=>true)
    port map(clk=>clk(0),ce=>ce(0),reset=>reset,preset=>ss,addr=>addr(0),rnw=>rnw(0),ena=>ena(0),seq=>open,code=>open,acc=>open,
      dout=>dout(0),din=>din(0),bus_done=>done(0),dma=>'0',irq=>'0',new_halt=>newhalt(0),unhalt=>wake(0),idle=>open,halted=>halt(0),
      memory_idle=>not pending_bus(0),cache_op_busy=>'0',request=>req(0),continue_run=>cont(0),restore=>'0',
      active=>active(0),paused=>paused(0),error=>merror(0),host_addr=>unsigned(host_addr(0)(6 downto 0)),host_write=>'0',host_din=>x"00000000",
      host_dout=>ram_data(0),release_run=>rel(0),ready=>mready(0));
  cpu7:entity work.nds_arm7_monitor_probe generic map(SLEEP_ENABLED=>true)
    port map(clk=>clk(1),ce=>ce(1),reset=>reset,preset=>ss,addr=>addr(1),rnw=>rnw(1),ena=>ena(1),seq=>open,code=>open,acc=>open,
      dout=>dout(1),din=>din(1),bus_done=>done(1),dma=>'0',irq=>'0',new_halt=>newhalt(1),unhalt=>wake(1),idle=>open,halted=>halt(1),
      request=>req(1),continue_run=>cont(1),restore=>'0',active=>active(1),paused=>paused(1),error=>merror(1),
      host_addr=>unsigned(host_addr(1)(5 downto 0)),host_write=>'0',host_din=>x"00000000",host_dout=>ram_data(1),release_run=>rel(1),ready=>mready(1));
  buses:for cpu in 0 to 1 generate
    process(clk(cpu))
      variable pending:boolean:=false;variable delay,expected:natural:=0;variable payload:std_logic_vector(31 downto 0);
    begin
      if rising_edge(clk(cpu)) then
        if ce(cpu)='1' then done(cpu)<='0';end if;
        if reset='0' then
          assert merror(cpu)='0' report "monitor fault" severity failure;
          assert active(cpu)='0' or not pending report "maintenance overlapped guest memory" severity failure;
          if pending then
            if delay=0 then done(cpu)<='1';din(cpu)<=payload;pending:=false;else delay:=delay-1;end if;
          end if;
          if ena(cpu)='1' then
            assert not pending and active(cpu)='0' report "guest bus ownership failure" severity failure;
            pending:=true;delay:=READ_DELAY-1;payload:=instruction(cpu,addr(cpu));
            if rnw(cpu)='0' then
              expected:=expected+1;
              assert addr(cpu)=x"04000000" and unsigned(dout(cpu))=expected report "guest counter skipped or duplicated" severity failure;
              completed(cpu)<=expected;
            end if;
          end if;
        end if;
        if pending then pending_bus(cpu)<='1';else pending_bus(cpu)<='0';end if;
      end if;
    end process;
  end generate;
  process(ctl) begin
    if rising_edge(ctl) and reset='0' then
      assert not (ready='1' and active/="00") report "barrier rearmed before maintenance finished" severity failure;
      if rel/="00" then
        assert (mready or not active)="11" report "one CPU escaped before other return was ready" severity failure;
      end if;
    end if;
  end process;
  process
    variable image:image_type;variable before:counts;variable old_epoch:unsigned(31 downto 0);variable a,limit:natural;
    procedure clocks(n:natural) is begin for i in 1 to n loop wait until falling_edge(ctl);end loop;end;
    procedure read_word(cpu,address:natural;bad:boolean:=false;stale:boolean:=false) is
    begin
      for i in 1 to 2000 loop clocks(1);exit when rd_ready='1';end loop;
      assert rd_ready='1' report "read port failed to drain" severity failure;
      if cpu=0 then rd_cpu<='0';else rd_cpu<='1';end if;
      rd_address<=std_logic_vector(to_unsigned(address,8));rd_epoch<=epoch;
      if stale then rd_epoch<=epoch-1;end if;
      rd_strobe<='1';clocks(1);rd_strobe<='0';
      for i in 1 to 2000 loop wait for 1 ns;exit when rd_done='1';clocks(1);end loop;
      assert rd_done='1' report "read did not terminate" severity failure;
      if bad or stale then assert rd_error='1' and rd_data=x"00000000" report "invalid read exposed monitor data" severity failure;
      else assert rd_error='0' and rd_data=image(cpu,address) and result_epoch=epoch
        report "monitor transport returned wrong word cpu="&integer'image(cpu)&" address="&integer'image(address) severity failure;end if;
      clocks(2);
    end;
  begin
    reset<='1';ss.rst<='1';clocks(20);ss.rst<='0';clocks(6);
    ss.Adr<=(others=>'0');ss.Din<=x"02000000";ss.ena<='1';clocks(30);ss.ena<='0';clocks(10);reset<='0';permit<='1';
    for i in 1 to 50000 loop clocks(1);exit when ready='1' and completed(0)>=1 and completed(1)>=3;end loop;
    assert ready='1' and completed(0)>=1 and completed(1)>=3 report "fixture did not start" severity failure;
    assert format_id=x"4D430001" and count9=78 and count7=59 report "wrong hybrid image identity" severity failure;
    for attempt in 1 to 3 loop
      wake<="00";
      if SLEEP7 then
        newhalt(1)<='1';for i in 1 to 50000 loop clocks(1);exit when halt(1)='1';end loop;
        assert halt(1)='1' report "ARM7 did not halt" severity failure;newhalt(1)<='0';
      end if;
      if SLEEP9 then for i in 1 to 50000 loop clocks(1);exit when halt(0)='1';end loop;
        assert halt(0)='1' report "ARM9 did not reach WFI" severity failure;end if;
      old_epoch:=epoch;request<='1';clocks(1);
      if SCENARIO="early_cancel" then request<='0';
      else
        if SCENARIO="mid_cancel" then
          for i in 1 to 50000 loop clocks(1);exit when active/="00";end loop;
          assert active/="00" report "maintenance did not start" severity failure;request<='0';
        else
          for i in 1 to 100000 loop clocks(1);exit when held='1';end loop;
          assert held='1' and paused="11" report "pair did not capture" severity failure;
          reference_read<='1';
          for address in 0 to 77 loop
            reference_addr<=std_logic_vector(to_unsigned(address,8));clocks(6);
            image(0,address):=ram_data(0);if address<59 then image(1,address):=ram_data(1);end if;
          end loop;reference_read<='0';clocks(6);
          if SLEEP7 then assert image(1,45)=x"00000001" report "HALT header absent" severity failure;end if;
          if SLEEP9 then assert image(0,64)=x"00000001" report "WFI header absent" severity failure;end if;
          for cpu in 0 to 1 loop
            if cpu=0 then limit:=78;else limit:=59;end if;
            for word in 0 to limit-1 loop a:=(word*17) mod limit;read_word(cpu,a);end loop;
            read_word(cpu,limit,true);read_word(cpu,127,true);read_word(cpu,128,true);read_word(cpu,255,true);read_word(cpu,0,false,true);
          end loop;
          if SCENARIO="lease" then
            for i in 1 to 21000 loop clocks(1);exit when expired='1';end loop;
            assert expired='1' and held='0' report "lease did not revoke capture" severity failure;
          elsif SCENARIO="owner_loss" then
            owner_loss<='1';clocks(1);owner_loss<='0';clocks(1);
            read_word(0,0,true);assert held='0' report "owner loss reopened permit" severity failure;
          elsif SCENARIO="read_cancel" then
            rd_cpu<='1';rd_address<=x"05";rd_epoch<=epoch;rd_strobe<='1';clocks(1);rd_strobe<='0';request<='0';
            for i in 1 to 200 loop clocks(1);exit when rd_done='1';end loop;
            assert rd_done='1' and rd_error='1' and rd_data=x"00000000" report "cancelled read exposed stale data" severity failure;
          elsif SCENARIO="read_stopped" then
            wait until falling_edge(clk(1));clock7_run<=false;clocks(4);
            rd_cpu<='1';rd_address<=x"05";rd_epoch<=epoch;rd_strobe<='1';clocks(1);rd_strobe<='0';
            for i in 1 to 200 loop clocks(1);exit when rd_done='1';end loop;
            assert rd_done='1' and rd_error='1' and rd_data=x"00000000" report "stopped read did not fail" severity failure;
            clocks(120);assert rd_ready='0' report "stopped read falsely rearmed" severity failure;
            request<='0';clocks(150);assert ready='0' report "stopped CPU falsely released" severity failure;clock7_run<=true;
          end if;
          request<='0';
        end if;
      end if;
      if HOLD_RETURN and SCENARIO/="early_cancel" then
        permit<='0';
        for i in 1 to 100000 loop clocks(1);exit when (mready or not active)="11" and pair_req='0';end loop;
        before:=completed;clocks(100);
        for cpu in 0 to 1 loop
          if active(cpu)='1' then assert completed(cpu)=before(cpu) report "guest escaped withheld common return" severity failure;end if;
        end loop;
        permit<='1';
      end if;
      for i in 1 to 100000 loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and active="00" and epoch=old_epoch+1 and stalled='0' report "maintenance failed to drain" severity failure;
      before:=completed;wake<="11";
      for i in 1 to 50000 loop clocks(1);exit when completed(0)>=before(0)+3 and completed(1)>=before(1)+3;end loop;
      assert completed(0)>=before(0)+3 and completed(1)>=before(1)+3 report "guest failed continuation after capture" severity failure;
    end loop;
    report "PASS: real hybrid monitor pair capture/return scenario="&SCENARIO&" three attempts";stop;wait;
  end process;
  process begin wait for 20 ms;assert false report "monitor capture watchdog" severity failure;end process;
end;
