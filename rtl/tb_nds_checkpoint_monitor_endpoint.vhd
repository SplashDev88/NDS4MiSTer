-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real ARM7 monitor plus the existing barrier. An early cancel cannot rearm the
-- barrier while private capture/reload is still executing. Authored code only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_monitor_endpoint is
  generic(SLEEP_MODE:boolean:=false;CANCEL_PHASE:natural:=0; STEP_PERIOD:positive:=1; READ_DELAY:positive:=1;
    EXPIRE_LEASE:boolean:=false; HOLD_RETURN:boolean:=false; ACQUIRE_TIMEOUT:boolean:=false);
end;
architecture sim of tb_nds_checkpoint_monitor_endpoint is
  signal clk:std_logic:='0';signal ce:std_logic:='0';signal reset:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout:std_logic_vector(31 downto 0):=(others=>'0');
  signal ena,rnw,done,request,pair_request,ready,busy,pair_paused,timedout,stalled,expired:std_logic:='0';
  signal mon_req,mon_continue,mon_release,active,paused,return_ready,err,ack,seen:std_logic:='0';
  signal permit:std_logic:='1';
  signal other_ack:std_logic;
  signal epoch:unsigned(31 downto 0);
  signal counter:natural:=0;
  function instruction(a:std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"02000000"=>return x"E321F0DF";
      when x"02000004"=>return x"E3A00301";
      when x"02000008"=>return x"E3A01000";
      when x"0200000C"=>return x"E2811001";
      when x"02000010"=>return x"E5801000";
      when x"02000014"=>return x"EAFFFFFC";
      when others=>return x"EAFFFFFE";
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  other_ack<='0' when ACQUIRE_TIMEOUT else pair_request;
  process begin
    for i in 1 to STEP_PERIOD loop
      wait until falling_edge(clk);if i=STEP_PERIOD then ce<='1';else ce<='0';end if;
    end loop;
  end process;
  coordinator:entity work.nds_checkpoint_coordinator
    generic map(TIMEOUT_CYCLES=>10000,LEASE_CYCLES=>80)
    port map(clk=>clk,reset=>reset,request=>request,
      cpu_paused_async=>ack & other_ack,request_seen_async=>seen & pair_request,
      cpu_request=>pair_request,ready=>ready,busy=>busy,pair_paused=>pair_paused,
      timed_out=>timedout,release_stalled=>stalled,lease_expired=>expired,epoch=>epoch);
  endpoint:entity work.nds_checkpoint_monitor_endpoint
    port map(clk=>clk,reset=>reset,request_async=>pair_request,
      monitor_active=>active,monitor_paused=>paused,monitor_ready=>return_ready,monitor_error=>err,
      return_permission=>permit,monitor_request=>mon_req,monitor_continue=>mon_continue,
      monitor_release=>mon_release,capture_paused=>ack,request_seen=>seen);
  cpu:entity work.nds_arm7_monitor_probe generic map(SLEEP_ENABLED=>SLEEP_MODE)
    port map(clk=>clk,ce=>ce,reset=>reset,preset=>ss,addr=>addr,rnw=>rnw,ena=>ena,seq=>open,
      code=>open,acc=>open,dout=>dout,din=>din,bus_done=>done,dma=>'0',irq=>'0',new_halt=>'0',unhalt=>'0',
      idle=>open,halted=>open,request=>mon_req,continue_run=>mon_continue,restore=>'0',
      active=>active,paused=>paused,error=>err,host_addr=>to_unsigned(0,6),host_write=>'0',
      host_din=>x"00000000",host_dout=>open,release_run=>mon_release,ready=>return_ready);
  process(clk)
    variable pending:boolean:=false;variable remaining,expected:natural:=0;
    variable payload:std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      if ce='1' then done<='0';end if;
      if reset='0' then
        assert err='0' report "monitor error" severity failure;
        assert not (ready='1' and active='1') report "barrier rearmed before maintenance finished" severity failure;
        if pending then
          if remaining=0 then din<=payload;done<='1';pending:=false;
          else remaining:=remaining-1;end if;
        end if;
        if ena='1' then
          assert active='0' and not pending report "guest bus ownership failure" severity failure;
          pending:=true;remaining:=READ_DELAY-1;payload:=instruction(addr);
          if rnw='0' then
            expected:=expected+1;
            assert addr=x"04000000" and unsigned(dout)=expected report "cancel skipped or duplicated guest counter" severity failure;
            counter<=expected;
          end if;
        end if;
      end if;
    end if;
  end process;
  process
    variable before:natural;variable prior_epoch:unsigned(31 downto 0);
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
  begin
    ss.rst<='1';clocks(4);ss.rst<='0';clocks(2);
    ss.Adr<=(others=>'0');ss.Din<=x"02000000";ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(4);
    reset<='0';
    for i in 1 to 10000 loop clocks(1);exit when ready='1' and counter>=5;end loop;
    assert ready='1' and counter>=5 report "fixture did not start" severity failure;
    for attempt in 1 to 3 loop
      prior_epoch:=epoch;request<='1';clocks(1);
      if CANCEL_PHASE=0 and not EXPIRE_LEASE then request<='0';
      else
        for i in 1 to 50000 loop clocks(1);exit when active='1';end loop;
        assert active='1' report "maintenance did not start" severity failure;
        if CANCEL_PHASE=1 and not EXPIRE_LEASE then request<='0';
        else
          if ACQUIRE_TIMEOUT then
            for i in 1 to 50000 loop clocks(1);exit when timedout='1';end loop;
            assert timedout='1' and pair_paused='0' report "missing-owner acquisition did not time out" severity failure;
          else
            for i in 1 to 50000 loop clocks(1);exit when pair_paused='1';end loop;
            assert pair_paused='1' and ack='1' report "no coherent capture acknowledgement" severity failure;
          end if;
          if EXPIRE_LEASE then
            for i in 1 to 1000 loop clocks(1);exit when expired='1';end loop;
            assert expired='1' report "lease did not expire" severity failure;
          end if;
          request<='0';
        end if;
      end if;
      if HOLD_RETURN and CANCEL_PHASE/=0 then
        permit<='0';
        for i in 1 to 50000 loop clocks(1);exit when return_ready='1';end loop;
        assert return_ready='1' report "missing return barrier" severity failure;
        before:=counter;clocks(100);
        assert ready='0' and active='1' and seen='1' and counter=before report "return barrier escaped" severity failure;
        permit<='1';
      end if;
      for i in 1 to 50000 loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and active='0' and seen='0' and ack='0' and epoch=prior_epoch+1 and stalled='0'
        report "cancel/lease did not drain before rearm" severity failure;
      before:=counter;
      for i in 1 to 50000 loop clocks(1);exit when counter>=before+5;end loop;
      assert counter>=before+5 report "cancel did not resume guest" severity failure;
    end loop;
    report "PASS: three monitor cancel/lease attempts drain before barrier rearm";
    stop;wait;
  end process;
  process begin wait for 20 ms;assert false report "endpoint watchdog" severity failure;end process;
end;
