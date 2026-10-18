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
           HALT_PIPELINE : boolean := false);
end;

architecture sim of tb_nds_checkpoint_coordinator is
  constant DEADLINE : positive := 1200;
  type words is array(0 to 1) of std_logic_vector(31 downto 0);
  type counts is array(0 to 1) of natural;
  signal clk : std_logic_vector(1 downto 0) := "00";
  signal control_clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal ce, dma, req, paused, seen, ena, done, rnw, idle, halt, wake, newhalt :
    std_logic_vector(1 downto 0) := "00";
  signal addr, din, dout, ssout : words;
  signal ss : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
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
  coordinator : entity work.nds_checkpoint_coordinator
    generic map(TIMEOUT_CYCLES=>DEADLINE)
    port map(clk=>control_clk,reset=>reset,request=>request,
      cpu_paused_async=>ack_input,request_seen_async=>seen_input,
      cpu_request=>pair_req,ready=>ready,busy=>busy,pair_paused=>pair_paused,
      timed_out=>timeout,release_stalled=>stalled,epoch=>epoch);

  endpoints : for i in 0 to 1 generate
    endpoint : entity work.nds_checkpoint_endpoint
      port map(clk=>clk(i),reset=>reset,request_async=>pair_req,
        cpu_request=>req(i),request_seen=>seen(i));
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
    port map(clk=>clk(0),ce=>ce(0),reset=>reset,savestate_bus=>ss,
      ss_wired_out=>ssout(0),ss_wired_done=>open,
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
    port map(clk=>clk(1),ce=>ce(1),reset=>reset,savestate_bus=>ss,
      ss_wired_out=>ssout(1),ss_wired_done=>open,
      gb_bus_Adr=>addr(1),gb_bus_rnw=>rnw(1),gb_bus_ena=>ena(1),gb_bus_seq=>open,
      gb_bus_code=>open,gb_bus_acc=>open,gb_bus_dout=>dout(1),gb_bus_din=>din(1),
      gb_bus_done=>done(1),dma_on=>dma(1),CPU_bus_idle=>idle(1),PC_in_BIOS=>open,
      cpu_halt=>halt(1),lastread=>open,jump_out=>open,IRQ_in=>'0',unhalt=>wake(1),
      new_halt=>newhalt(1),checkpoint_req=>req(1),checkpoint_paused=>paused(1));

  process
    variable before : counts;
    variable old_epoch : unsigned(31 downto 0);
    variable first, second : words;
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
  begin
    assert SCENARIO="normal" or SCENARIO="dma9" or SCENARIO="dma7" or
      SCENARIO="halt7" or SCENARIO="wfi9" or SCENARIO="no_branch9" or
      SCENARIO="early_cancel" or SCENARIO="stuck_release" or SCENARIO="stopped_clock"
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

    if HALT_PIPELINE and (SCENARIO="wfi9" or SCENARIO="halt7") then
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
