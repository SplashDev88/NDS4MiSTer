-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored dual-CPU program and real checkpoint endpoints on unrelated clocks.
-- This tests a CPU-pair barrier, not memory/device/renderer state persistence.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_checkpoint_coordinator is
  generic (SCENARIO : string := "normal"; READ_DELAY : positive := 1;
           STEP_PERIOD : positive := 1; REQUEST_PHASE : natural := 0;
           HALT_PIPELINE : boolean := false; USE_CAPTURE : boolean := false);
end;

architecture sim of tb_nds_checkpoint_coordinator is
  constant DEADLINE : positive := 1200;
  type words is array(0 to 1) of std_logic_vector(31 downto 0);
  type state_buses is array(0 to 1) of proc_bus_gb_type;
  type state_addresses is array(0 to 1) of std_logic_vector(7 downto 0);
  type counts is array(0 to 1) of natural;
  signal clk : std_logic_vector(1 downto 0) := "00";
  signal control_clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal ce, dma, req, paused, seen, ena, done, rnw, idle, halt, wake, newhalt :
    std_logic_vector(1 downto 0) := "00";
  signal addr, din, dout, ssout : words;
  signal ss : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal cpu_ss : state_buses;
  signal state_address : state_addresses;
  signal state_valid : std_logic_vector(1 downto 0);
  signal keepalive, expired : std_logic := '0';
  signal keepalive_epoch : unsigned(31 downto 0) := (others => '0');
  signal rd_strobe, rd_cpu, rd_ready, rd_done, rd_error : std_logic := '0';
  signal rd_address : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_epoch, result_epoch : unsigned(31 downto 0) := (others => '0');
  signal rd_data : std_logic_vector(31 downto 0);
  constant LEASE : positive := 800;
  signal completed : counts := (0,0);
  signal request, pair_req, ready, busy, pair_paused, timeout, stalled : std_logic := '0';
  signal epoch : unsigned(31 downto 0);
  signal pending_bus : std_logic_vector(1 downto 0) := "00";
  signal clock7_run : boolean := true;
  signal force_ack, force_seen : std_logic := '0';
  signal ack_input, seen_input : std_logic_vector(1 downto 0);
begin
  control_clk <= not control_clk after 5 ns;
  clk(0) <= not clk(0) after 7 ns;
  process
  begin
    wait for 11 ns;
    if clock7_run then clk(1) <= not clk(1); end if;
  end process;
  ack_input <= paused or (force_ack & '0');
  seen_input <= seen or (force_seen & '0');
  old_controller : if not USE_CAPTURE generate
  coordinator : entity work.nds_checkpoint_coordinator
    generic map(TIMEOUT_CYCLES=>DEADLINE)
    port map(clk=>control_clk,reset=>reset,request=>request,
      cpu_paused_async=>ack_input,request_seen_async=>seen_input,
      cpu_request=>pair_req,ready=>ready,busy=>busy,pair_paused=>pair_paused,
      timed_out=>timeout,release_stalled=>stalled,epoch=>epoch);
  end generate;

  capture_controller : if USE_CAPTURE generate
    capture : entity work.nds_checkpoint_cpu_capture
      generic map(TIMEOUT_CYCLES=>DEADLINE, LEASE_CYCLES=>LEASE, READ_TIMEOUT_CYCLES=>100)
      port map(clk=>control_clk,clk9=>clk(0),clk7=>clk(1),reset=>reset,
        request=>request,keepalive=>keepalive,keepalive_epoch=>keepalive_epoch,
        ready=>ready,busy=>busy,pair_paused=>pair_paused,timed_out=>timeout,
        release_stalled=>stalled,lease_expired=>expired,epoch=>epoch,
        cpu_request9=>req(0),cpu_request7=>req(1),cpu_paused9=>paused(0),cpu_paused7=>paused(1),
        read_strobe=>rd_strobe,read_cpu=>rd_cpu,read_address=>rd_address,read_epoch=>rd_epoch,
        read_ready=>rd_ready,read_done=>rd_done,read_error=>rd_error,read_data=>rd_data,
        result_epoch=>result_epoch,cpu_address9=>state_address(0),cpu_address7=>state_address(1),
        cpu_data9=>ssout(0),cpu_data7=>ssout(1),cpu_valid9=>state_valid(0),cpu_valid7=>state_valid(1));
    seen <= req; -- observable endpoint delivery for the common test helpers
  end generate;

  endpoints : for i in 0 to 1 generate
    old_endpoint : if not USE_CAPTURE generate
    endpoint : entity work.nds_checkpoint_endpoint
      port map(clk=>clk(i),reset=>reset,request_async=>pair_req,
        cpu_request=>req(i),request_seen=>seen(i));
    end generate;
    process(all) begin
      cpu_ss(i) <= ss;
      if USE_CAPTURE and reset='0' then
        cpu_ss(i).Adr <= std_logic_vector(resize(unsigned(state_address(i)),ss.Adr'length));
        cpu_ss(i).ena <= '0'; cpu_ss(i).rnw <= '1'; cpu_ss(i).bEna <= "0000";
      end if;
    end process;
    process
    begin
      for n in 1 to STEP_PERIOD loop
        wait until falling_edge(clk(i));
        if n=STEP_PERIOD then ce(i)<='1'; else ce(i)<='0'; end if;
      end loop;
    end process;
    memory : process(clk(i))
      variable pending : boolean := false;
      variable remaining, count : natural := 0;
      variable payload : std_logic_vector(31 downto 0);
    begin
      if rising_edge(clk(i)) then
        if ce(i)='1' then done(i)<='0';newhalt(i)<='0';end if;
        if reset='1' then
          assert not pending report "reset discarded bus operation" severity failure;
          count:=0;completed(i)<=0;
        else
          if pending then
            if remaining=0 then done(i)<='1';din(i)<=payload;pending:=false;
            else remaining:=remaining-1;end if;
          end if;
          if ena(i)='1' then
            assert not pending report "overlapping CPU bus requests" severity failure;
            assert paused(i)='0' report "paused CPU issued a bus request" severity failure;
            pending:=true;remaining:=READ_DELAY-1;payload:=x"E1A00000";
            if rnw(i)='0' then
              if addr(i)=x"04000000" then
                count:=count+1;
                assert unsigned(dout(i))=count
                  report "pair cancellation skipped or duplicated a store" severity failure;
                completed(i)<=count;
              elsif addr(i)=x"0400000C" then
                if i=1 and SCENARIO="halt7" then newhalt(i)<='1';end if;
              else assert false report "unexpected program store" severity failure;end if;
            else
              case addr(i) is
                when x"02000000"=>payload:=x"E321F09F"; -- masked system mode
                when x"02000004"=>payload:=x"E3A00301"; -- IO output address
                when x"02000008"=>payload:=x"E3A01000"; -- counter
                when x"0200000C"=>payload:=x"E2811001"; -- increment
                when x"02000010"=>payload:=x"E5801000"; -- publish
                when x"02000014"=>
                  if i=0 and SCENARIO="wfi9" then payload:=x"EE070F90";end if;
                when x"02000018"=>payload:=x"E580100C"; -- HALTCNT model on ARM7
                -- This toy HALTCNT adapter is not the console IO bus. Leave
                -- NOPs after its store so its response phase does not make
                -- the counter depend on an unrelated HALT-prefetch detail.
                when x"02000024"=>
                  if i/=0 or SCENARIO/="no_branch9" then payload:=x"EAFFFFF8";end if;
                when others=>null;
              end case;
            end if;
          end if;
        end if;
        if pending then pending_bus(i)<='1';else pending_bus(i)<='0';end if;
      end if;
    end process;
  end generate;

  cpu9 : entity work.nds_cpu9
    generic map(is_simu=>'0',SS_PRESET_ONLY=>'0',EXPERIMENTAL_CHECKPOINT=>true,
      EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
    port map(clk=>clk(0),ce=>ce(0),reset=>reset,savestate_bus=>cpu_ss(0),
      ss_wired_out=>ssout(0),ss_wired_done=>state_valid(0),
      gb_bus_Adr=>addr(0),gb_bus_rnw=>rnw(0),gb_bus_ena=>ena(0),gb_bus_seq=>open,
      gb_bus_code=>open,gb_bus_acc=>open,gb_bus_dout=>dout(0),gb_bus_din=>din(0),
      gb_bus_done=>done(0),dma_on=>dma(0),CPU_bus_idle=>idle(0),PC_in_BIOS=>open,
      cpu_halt=>halt(0),lastread=>open,jump_out=>open,IRQ_in=>'0',unhalt=>wake(0),
      new_halt=>newhalt(0),cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,
      cp15_itcm_load=>open,cp15_dtcm_ena=>open,cp15_dtcm_load=>open,
      cp15_dtcm_base=>open,cp15_dtcm_size=>open,cp15_itcm_size=>open,
      bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0',
      checkpoint_req=>req(0),checkpoint_paused=>paused(0));
  cpu7 : entity work.gba_cpu
    generic map(is_simu=>'0',SS_PRESET_ONLY=>'0',EXPERIMENTAL_CHECKPOINT=>true,
      EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
    port map(clk=>clk(1),ce=>ce(1),reset=>reset,savestate_bus=>cpu_ss(1),
      ss_wired_out=>ssout(1),ss_wired_done=>state_valid(1),
      gb_bus_Adr=>addr(1),gb_bus_rnw=>rnw(1),gb_bus_ena=>ena(1),gb_bus_seq=>open,
      gb_bus_code=>open,gb_bus_acc=>open,gb_bus_dout=>dout(1),gb_bus_din=>din(1),
      gb_bus_done=>done(1),dma_on=>dma(1),CPU_bus_idle=>idle(1),PC_in_BIOS=>open,
      cpu_halt=>halt(1),lastread=>open,jump_out=>open,IRQ_in=>'0',unhalt=>wake(1),
      new_halt=>newhalt(1),checkpoint_req=>req(1),checkpoint_paused=>paused(1));

  process
    variable before : counts;
    variable old_epoch : unsigned(31 downto 0);
    variable first, second : words;
    variable nwords, word_address : natural;
    variable expected_cpu, expected_address : natural;
    variable saw_paused_peer : boolean := false;
    procedure clocks(n : natural) is
    begin for i in 1 to n loop wait until falling_edge(control_clk);end loop;end;
    procedure wait_ready is
    begin
      for i in 1 to DEADLINE+100 loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and paused="00" and seen="00" and busy='0'
        report "rearmed before both endpoints released" severity failure;
    end;
    procedure await_pair is
    begin
      for i in 1 to DEADLINE+1 loop clocks(1);exit when pair_paused='1' or timeout='1';end loop;
      assert pair_paused='1' and timeout='0'
        report "running CPU pair did not reach barrier" severity failure;
      assert paused="11" and idle="11" and ena="00" and pending_bus="00"
        report "pair barrier accepted outstanding bus work" severity failure;
    end;
    procedure progress is
    begin
      before:=completed;
      for i in 1 to 10000 loop
        clocks(1);exit when completed(0)>=before(0)+3 and completed(1)>=before(1)+3;
      end loop;
      assert completed(0)>=before(0)+3 and completed(1)>=before(1)+3
        report "CPU pair did not continue after release" severity failure;
    end;
    procedure pulse_keepalive(stale : boolean := false) is
    begin
      keepalive_epoch <= epoch;
      if stale then keepalive_epoch <= epoch-1; end if;
      keepalive <= '1';clocks(1);keepalive <= '0';clocks(1);
    end;
    procedure start_read(cpu, address : natural; stale : boolean := false) is
    begin
      for i in 1 to DEADLINE loop clocks(1);exit when rd_ready='1';end loop;
      assert rd_ready='1' report "read transport failed to rearm" severity failure;
      expected_cpu:=cpu;expected_address:=address;
      if cpu=0 then rd_cpu<='0';else rd_cpu<='1';end if;
      rd_address<=std_logic_vector(to_unsigned(address,8));rd_epoch<=epoch;
      if stale then rd_epoch<=epoch-1;end if;
      rd_strobe<='1';clocks(1);rd_strobe<='0';
      -- Inputs need not stay stable after acceptance.
      rd_address<=x"FE";rd_cpu<=not rd_cpu;rd_epoch<=not epoch;
    end;
    procedure finish_read(cpu : natural; valid : boolean := true) is
    begin
      for i in 1 to DEADLINE loop
        exit when rd_done='1';clocks(1);
      end loop;
      assert rd_done='1' report "read transport missed completion/deadline" severity failure;
      if valid then
        assert cpu=expected_cpu and unsigned(state_address(cpu))=expected_address
          report "CPU capture used a different address/selection" severity failure;
        assert rd_error='0' and result_epoch=epoch and rd_data=ssout(cpu)
          report "CPU capture read returned wrong or stale data" severity failure;
        if expected_address=0 then
          assert rd_data=x"0200000C" report "CPU capture returned incorrect branch PC" severity failure;
        end if;
      else
        assert rd_error='1' and rd_data=x"00000000"
          report "invalid CPU capture returned usable state" severity failure;
      end if;
      clocks(1);
      assert rd_done='0' report "read completion was repeated" severity failure;
    end;
  begin
    assert SCENARIO="normal" or SCENARIO="dma9" or SCENARIO="dma7" or
      SCENARIO="halt7" or SCENARIO="wfi9" or SCENARIO="no_branch9" or
      SCENARIO="early_cancel" or SCENARIO="stuck_release" or SCENARIO="stopped_clock" or
      SCENARIO="transport" or SCENARIO="read_cancel" or SCENARIO="read_stopped" or
      SCENARIO="lease" or SCENARIO="stale_keepalive" or SCENARIO="stuck_keepalive" or
      SCENARIO="read_lease" or SCENARIO="common_reset"
      report "unknown scenario" severity failure;
    ss.rst<='1';clocks(30);ss.rst<='0';clocks(10);
    ss.Din<=x"02000000";ss.ena<='1';clocks(10);ss.ena<='0';clocks(10);reset<='0';
    wait_ready;
    for i in 1 to 10000 loop clocks(1);exit when completed(0)>0 and completed(1)>0;end loop;
    assert completed(0)>0 and completed(1)>0 report "program failed to start" severity failure;
    if SCENARIO="wfi9" or SCENARIO="halt7" then
      for i in 1 to 1000 loop clocks(1);exit when halt/="00";end loop;
      assert halt/="00" report "CPU did not sleep" severity failure;
    elsif SCENARIO/="no_branch9" then progress;end if;
    if SCENARIO="dma9" then dma(0)<='1';end if;
    if SCENARIO="dma7" then dma(1)<='1';end if;
    clocks(REQUEST_PHASE);
    old_epoch:=epoch;request<='1';clocks(1);
    assert epoch=old_epoch+1 report "request did not allocate exactly one epoch" severity failure;

    if SCENARIO="transport" then
      assert USE_CAPTURE and HALT_PIPELINE report "transport needs full capture format" severity failure;
      await_pair;before:=completed;
      for cpu in 0 to 1 loop
        if cpu=0 then nwords:=80;else nwords:=60;end if;
        for word in 0 to nwords-1 loop
          if word<47 then word_address:=word;
          elsif cpu=0 and word<68 then word_address:=128+word-47;
          elsif cpu=1 and word=47 then word_address:=148;
          else word_address:=160+word-(nwords-12);end if;
          pulse_keepalive;start_read(cpu,word_address);finish_read(cpu);
        end loop;
        start_read(cpu,255);finish_read(cpu,false);
        start_read(cpu,0,true);finish_read(cpu,false);
      end loop;
      assert completed=before and expired='0' report "capture lost its live lease" severity failure;
      request<='0';wait_ready;progress;
      start_read(0,0);finish_read(0,false); -- reject reads outside a hold
    elsif SCENARIO="read_lease" then
      await_pair;pulse_keepalive;clocks(LEASE-4);
      start_read(1,0);finish_read(1,false);
      assert expired='1' and pair_paused='0' report "expired read retained hold" severity failure;
      request<='0';wait_ready;progress;
      request<='1';await_pair;start_read(1,0);finish_read(1);
      request<='0';wait_ready;progress;
    elsif SCENARIO="common_reset" then
      await_pair;start_read(0,0);reset<='1';request<='0';clocks(30);
      assert rd_done='0' and pair_paused='0' and expired='0'
        report "common reset retained pending capture" severity failure;
      reset<='0';wait_ready;progress;
      request<='1';await_pair;start_read(0,0);finish_read(0);
      request<='0';wait_ready;progress;
    elsif SCENARIO="read_cancel" or SCENARIO="read_stopped" then
      await_pair;
      if SCENARIO="read_stopped" then clock7_run<=false;end if;
      start_read(1,0);
      if SCENARIO="read_cancel" then request<='0';end if;
      finish_read(1,false);
      if SCENARIO="read_stopped" then
        clocks(120);assert rd_ready='0' report "stopped read falsely rearmed" severity failure;
        request<='0';clock7_run<=true;
      end if;
      wait_ready;progress;
      clocks(100);assert rd_done='0' report "late reply escaped cancellation" severity failure;
      request<='1';await_pair;start_read(1,0);finish_read(1);
      request<='0';wait_ready;progress;
    elsif SCENARIO="lease" or SCENARIO="stale_keepalive" or SCENARIO="stuck_keepalive" then
      await_pair;before:=completed;
      -- Correct epoch strobes keep a long hold alive beyond one lease.
      for i in 1 to 6 loop clocks(LEASE/3);pulse_keepalive;end loop;
      assert pair_paused='1' and expired='0' and completed=before
        report "valid keepalive failed to renew hold" severity failure;
      if SCENARIO="stuck_keepalive" then keepalive<='1';keepalive_epoch<=epoch;end if;
      for i in 1 to LEASE*2 loop
        if SCENARIO="stale_keepalive" then
          if i mod 10=0 then keepalive<='1';keepalive_epoch<=epoch-1;else keepalive<='0';end if;
        end if;
        clocks(1);exit when expired='1';
      end loop;
      assert expired='1' and timeout='1' and pair_paused='0'
        report "lost host failed to expire CPU hold" severity failure;
      keepalive<='0';clocks(100);
      assert paused="00" and ready='0' report "expired hold did not release / falsely rearmed" severity failure;
      progress;old_epoch:=epoch;clocks(LEASE);
      assert epoch=old_epoch report "stale host request retried itself" severity failure;
      request<='0';wait_ready;request<='1';await_pair;
      assert expired='0' and epoch=old_epoch+1 report "fresh attempt did not reset lease" severity failure;
      request<='0';wait_ready;progress;
    elsif HALT_PIPELINE and (SCENARIO="wfi9" or SCENARIO="halt7") then
      await_pair;before:=completed;clocks(200);
      assert completed=before and halt/="00" report "halted pair did not stay asleep" severity failure;
      request<='0';wait_ready;wake<="11";
      for i in 1 to 10000 loop
        clocks(1);exit when completed(0)>before(0) and completed(1)>before(1);
      end loop;
      assert completed(0)>before(0) and completed(1)>before(1)
        report "halted pair did not resume after release" severity failure;
    elsif SCENARIO="early_cancel" or SCENARIO="stopped_clock" then
      -- Cancel before the high phase can return from both CPU domains.
      if SCENARIO="stopped_clock" then clock7_run<=false;end if;
      request<='0';clocks(1);
      assert pair_paused='0' report "cancelled request reported success" severity failure;
      if SCENARIO="stopped_clock" then
        clocks(DEADLINE+20);
        assert stalled='1' and busy='1' and ready='0'
          report "stopped endpoint clock falsely reported release" severity failure;
        clock7_run<=true;
      end if;
      wait_ready;progress;
      old_epoch:=epoch;request<='1';await_pair;
      assert epoch=old_epoch+1 report "cancel/retry reused an epoch" severity failure;
      request<='0';wait_ready;progress;
    elsif SCENARIO="normal" or SCENARIO="stuck_release" then
      await_pair;
      before:=completed;clocks(200);
      assert completed=before report "held pair continued execution" severity failure;
      for a in 0 to 46 loop
        ss.Adr<=std_logic_vector(to_unsigned(a,ss.Adr'length));ss.rnw<='1';clocks(3);
        first:=ssout;clocks(3);second:=ssout;
        assert first=second report "CPU state changed at pair barrier" severity failure;
        if a=0 then assert first(0)=x"0200000C" and first(1)=x"0200000C"
          report "pair resume PC is incorrect" severity failure;end if;
      end loop;
      if SCENARIO="stuck_release" then force_ack<='1';force_seen<='1';clocks(4);end if;
      request<='0';
      if SCENARIO="stuck_release" then
        clocks(DEADLINE+20);
        assert stalled='1' and busy='1' and ready='0' and pair_req='0'
          report "stale acknowledgement allowed unsafe rearm" severity failure;
        force_ack<='0';force_seen<='0';
      end if;
      wait_ready;progress;
      -- A fresh attempt must observe fresh acknowledgements from BOTH CPUs.
      old_epoch:=epoch;request<='1';await_pair;
      assert epoch=old_epoch+1 report "retry did not advance epoch" severity failure;
      request<='0';wait_ready;progress;
    else
      for i in 1 to DEADLINE+1 loop
        clocks(1);
        if paused/="00" then saw_paused_peer:=true;end if;
        assert pair_paused='0' report "unsupported CPU state accepted" severity failure;
        exit when timeout='1';
      end loop;
      assert timeout='1' report "pause attempt exceeded deadline" severity failure;
      assert saw_paused_peer report "timeout case never paused the running peer" severity failure;
      clocks(100);
      assert paused="00" and pair_req='0' and busy='0' and ready='0'
        report "timeout failed to release a paused peer" severity failure;
      old_epoch:=epoch;clocks(DEADLINE+20);
      assert epoch=old_epoch and timeout='1' report "held request retried after timeout" severity failure;
      request<='0';dma<="00";wait_ready;
      if SCENARIO="wfi9" or SCENARIO="halt7" then
        before:=completed;wake<="11";
        for i in 1 to 10000 loop
          clocks(1);exit when completed(0)>before(0) and completed(1)>before(1);
        end loop;
        assert completed(0)>before(0) and completed(1)>before(1)
          report "timeout damaged sleep/wake continuation" severity failure;
      elsif SCENARIO/="no_branch9" then progress;
      else
        before:=completed;clocks(1000);
        assert completed(1)>before(1) report "branchless peer stranded ARM7" severity failure;
      end if;
    end if;
    report "PASS: CPU-pair coordinator " & SCENARIO & " delay=" & integer'image(READ_DELAY) &
      " step=" & integer'image(STEP_PERIOD) & " phase=" & integer'image(REQUEST_PHASE) &
      " halted-format=" & boolean'image(HALT_PIPELINE);
    stop;wait;
  end process;
  process begin wait for 5 ms;assert false report "test watchdog" severity failure;end process;
end;
