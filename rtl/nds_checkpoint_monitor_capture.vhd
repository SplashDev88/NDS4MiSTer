-- SPDX-License-Identifier: GPL-3.0-or-later
-- CPU-assisted hybrid image transport; not yet wired into the product console.
-- Both monitors must enable their HALT/WFI extension (78 ARM9 / 59 ARM7 words).
-- Capture only: image loading, exact runtime identity and memory state are separate.
-- Experimental CPU state transport. Optional two additional owner groups
-- qualify the same acquisition/lease/release handshake. Their implementations
-- must freeze/drain real devices and host work; tying inputs high is invalid.
-- Host inputs are synchronous to clk; read_strobe is a one-cycle request.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_checkpoint_monitor_capture is
  generic (TIMEOUT_CYCLES : positive := 1048576;
           LEASE_CYCLES : positive := 33513982;
           READ_TIMEOUT_CYCLES : positive := 1024;
           REQUIRE_OWNERS : boolean := false);
  port (
    clk, clk9, clk7, reset : in std_logic;
    request, keepalive : in std_logic;
    keepalive_epoch : in unsigned(31 downto 0);
    ready, busy, pair_paused, timed_out, release_stalled, lease_expired : out std_logic;
    epoch : out unsigned(31 downto 0);
    hold_request : out std_logic := '0'; -- includes acquisition and cancellation delivery
    cpu_request9, cpu_request7 : out std_logic;
    cpu_paused9, cpu_paused7 : in std_logic;
    read_strobe, read_cpu : in std_logic; -- 0 = ARM9, 1 = ARM7
    read_address : in std_logic_vector(7 downto 0);
    read_epoch : in unsigned(31 downto 0);
    read_ready, read_done, read_error : out std_logic;
    read_data : out std_logic_vector(31 downto 0);
    result_epoch : out unsigned(31 downto 0);
    cpu_address9, cpu_address7 : out std_logic_vector(7 downto 0);
    cpu_data9, cpu_data7 : in std_logic_vector(31 downto 0);
    cpu_valid9, cpu_valid7 : in std_logic;
    -- Synchronous to clk. An outer CDC handshake must deliver host status.
    -- bit0 = local devices including final RTC sample; bit1 = external owners.
    owners_paused, owners_seen : in std_logic_vector(1 downto 0) := "00";
    cpus_observed : out std_logic := '0';
    -- active/ready/error are local to each CPU clock, bit0 ARM9 / bit1 ARM7.
    monitor_active, monitor_ready, monitor_error : in std_logic_vector(1 downto 0);
    monitor_continue, monitor_release : out std_logic_vector(1 downto 0);
    -- Synchronous to clk. Keep low for a fresh restore until all owners agree.
    return_permission : in std_logic := '0';
    capture_format : out std_logic_vector(31 downto 0);
    capture_words9, capture_words7 : out unsigned(7 downto 0)
  );
end;

architecture rtl of nds_checkpoint_monitor_capture is
  function owner_count return positive is
  begin if REQUIRE_OWNERS then return 4; else return 2; end if; end;
  signal pair_request, held, permit, common_return : std_logic;
  signal capture_ack, return_waiting : std_logic_vector(1 downto 0);
  signal wait_meta, wait_sync, return_meta, return_sync : std_logic_vector(1 downto 0) := "00";
  attribute async_reg : string;
  attribute async_reg of wait_meta, wait_sync, return_meta, return_sync : signal is "true";
  signal owner_violation : std_logic := '0';
  signal all_paused, all_seen : std_logic_vector(3 downto 0);
  signal seen, rdready, rddone, rderror, rdrequest : std_logic_vector(1 downto 0);
  signal epoch_i, ep9, ep7 : unsigned(31 downto 0);
  signal data9, data7 : std_logic_vector(31 downto 0);
begin
  -- MC version1 always means the hybrid monitor images, never the old direct
  -- register format. The host still needs exact ROM/runtime identity checks.
  capture_format <= x"4D430001";
  capture_words9 <= to_unsigned(78,8); capture_words7 <= to_unsigned(59,8);
  epoch <= epoch_i;
  common_return <= '1' when return_permission='1' and pair_request='0' and
    wait_sync="11" and reset='0' else '0';
  process(clk) begin
    if rising_edge(clk) then
      if reset='1' then wait_meta<="00";wait_sync<="00";
      else wait_meta<=return_waiting;wait_sync<=wait_meta;end if;
    end if;
  end process;
  process(clk9) begin
    if rising_edge(clk9) then
      if reset='1' then return_meta(0)<='0';return_sync(0)<='0';
      else return_meta(0)<=common_return;return_sync(0)<=return_meta(0);end if;
    end if;
  end process;
  process(clk7) begin
    if rising_edge(clk7) then
      if reset='1' then return_meta(1)<='0';return_sync(1)<='0';
      else return_meta(1)<=common_return;return_sync(1)<=return_meta(1);end if;
    end if;
  end process;
  hold_request <= pair_request;
  -- Withdraw permission immediately on a synchronous owner loss, including
  -- a reply arriving on this edge, before coordinator synchronization catches up.
  permit <= held and not reset and not owner_violation and owners_paused(0) and owners_paused(1) and
    owners_seen(0) and owners_seen(1) when REQUIRE_OWNERS else held and not reset;
  process(clk) begin
    if rising_edge(clk) then
      if reset = '1' or pair_request = '0' then owner_violation <= '0';
      elsif REQUIRE_OWNERS and held = '1' and (owners_paused /= "11" or owners_seen /= "11") then
        -- A one-cycle owner loss poisons this epoch even if it recovers before
        -- the coordinator receives the synchronized low acknowledgement.
        owner_violation <= '1';
      end if;
    end if;
  end process;
  pair_paused <= permit;
  all_paused <= owners_paused & capture_ack;
  all_seen <= owners_seen & seen;
  coordinator : entity work.nds_checkpoint_coordinator
    generic map(TIMEOUT_CYCLES => TIMEOUT_CYCLES, LEASE_CYCLES => LEASE_CYCLES, OWNER_COUNT => owner_count)
    port map(clk => clk, reset => reset, request => request,
      keepalive => keepalive, keepalive_epoch => keepalive_epoch,
      cpu_paused_async => all_paused(owner_count-1 downto 0),
      request_seen_async => all_seen(owner_count-1 downto 0),
      cpu_request => pair_request, ready => ready, busy => busy, pair_paused => held,
      timed_out => timed_out, release_stalled => release_stalled,
      lease_expired => lease_expired, epoch => epoch_i, cpus_observed => cpus_observed);
  endpoint9 : entity work.nds_checkpoint_monitor_endpoint
    port map(clk=>clk9,reset=>reset,request_async=>pair_request,
      monitor_active=>monitor_active(0),monitor_paused=>cpu_paused9,
      monitor_ready=>monitor_ready(0),monitor_error=>monitor_error(0),
      return_permission=>return_sync(0),monitor_request=>cpu_request9,
      monitor_continue=>monitor_continue(0),monitor_release=>monitor_release(0),
      capture_paused=>capture_ack(0),request_seen=>seen(0),return_waiting=>return_waiting(0));
  endpoint7 : entity work.nds_checkpoint_monitor_endpoint
    port map(clk=>clk7,reset=>reset,request_async=>pair_request,
      monitor_active=>monitor_active(1),monitor_paused=>cpu_paused7,
      monitor_ready=>monitor_ready(1),monitor_error=>monitor_error(1),
      return_permission=>return_sync(1),monitor_request=>cpu_request7,
      monitor_continue=>monitor_continue(1),monitor_release=>monitor_release(1),
      capture_paused=>capture_ack(1),request_seen=>seen(1),return_waiting=>return_waiting(1));
  read_ready <= rdready(0) and rdready(1);
  rdrequest(0) <= read_strobe and rdready(0) and rdready(1) and not read_cpu;
  rdrequest(1) <= read_strobe and rdready(0) and rdready(1) and read_cpu;
  read_done <= rddone(0) or rddone(1);
  read_error <= rderror(0) when rddone(0) = '1' else rderror(1);
  read_data <= data9 when rddone(0) = '1' else data7;
  result_epoch <= ep9 when rddone(0) = '1' else ep7;
  reader9 : entity work.nds_checkpoint_read_port
    generic map(TIMEOUT_CYCLES => READ_TIMEOUT_CYCLES, RAM_READ_LATENCY=>1, WORD_COUNT=>78)
    port map(clk => clk, cpu_clk => clk9, reset => reset, permit => permit, epoch => epoch_i,
      read_request => rdrequest(0), read_address => read_address, read_epoch => read_epoch,
      ready => rdready(0), done => rddone(0), error => rderror(0), data => data9,
      result_epoch => ep9, cpu_paused => capture_ack(0), cpu_address => cpu_address9,
      cpu_data => cpu_data9, cpu_valid => cpu_valid9);
  reader7 : entity work.nds_checkpoint_read_port
    generic map(TIMEOUT_CYCLES => READ_TIMEOUT_CYCLES, RAM_READ_LATENCY=>1, WORD_COUNT=>59)
    port map(clk => clk, cpu_clk => clk7, reset => reset, permit => permit, epoch => epoch_i,
      read_request => rdrequest(1), read_address => read_address, read_epoch => read_epoch,
      ready => rdready(1), done => rddone(1), error => rderror(1), data => data7,
      result_epoch => ep7, cpu_paused => capture_ack(1), cpu_address => cpu_address7,
      cpu_data => cpu_data7, cpu_valid => cpu_valid7);
end;
