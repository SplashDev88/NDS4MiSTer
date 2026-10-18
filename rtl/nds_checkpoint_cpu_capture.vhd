-- SPDX-License-Identifier: GPL-3.0-or-later
-- Experimental CPU-only capture controller. This does NOT freeze devices,
-- memory, caches or the renderer and cannot certify a whole-game checkpoint.
-- Host inputs are synchronous to clk; read_strobe is a one-cycle request.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_checkpoint_cpu_capture is
  generic (TIMEOUT_CYCLES : positive := 1048576;
           LEASE_CYCLES : positive := 33513982;
           READ_TIMEOUT_CYCLES : positive := 1024);
  port (
    clk, clk9, clk7, reset : in std_logic;
    request, keepalive : in std_logic;
    keepalive_epoch : in unsigned(31 downto 0);
    ready, busy, pair_paused, timed_out, release_stalled, lease_expired : out std_logic;
    epoch : out unsigned(31 downto 0);
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
    cpu_valid9, cpu_valid7 : in std_logic
  );
end;

architecture rtl of nds_checkpoint_cpu_capture is
  signal pair_request, held : std_logic;
  signal seen, rdready, rddone, rderror, rdrequest : std_logic_vector(1 downto 0);
  signal epoch_i, ep9, ep7 : unsigned(31 downto 0);
  signal data9, data7 : std_logic_vector(31 downto 0);
begin
  epoch <= epoch_i;
  pair_paused <= held;
  coordinator : entity work.nds_checkpoint_coordinator
    generic map(TIMEOUT_CYCLES => TIMEOUT_CYCLES, LEASE_CYCLES => LEASE_CYCLES)
    port map(clk => clk, reset => reset, request => request,
      keepalive => keepalive, keepalive_epoch => keepalive_epoch,
      cpu_paused_async => cpu_paused7 & cpu_paused9, request_seen_async => seen,
      cpu_request => pair_request, ready => ready, busy => busy, pair_paused => held,
      timed_out => timed_out, release_stalled => release_stalled,
      lease_expired => lease_expired, epoch => epoch_i);
  endpoint9 : entity work.nds_checkpoint_endpoint
    port map(clk => clk9, reset => reset, request_async => pair_request,
      cpu_request => cpu_request9, request_seen => seen(0));
  endpoint7 : entity work.nds_checkpoint_endpoint
    port map(clk => clk7, reset => reset, request_async => pair_request,
      cpu_request => cpu_request7, request_seen => seen(1));
  read_ready <= rdready(0) and rdready(1);
  rdrequest(0) <= read_strobe and rdready(0) and rdready(1) and not read_cpu;
  rdrequest(1) <= read_strobe and rdready(0) and rdready(1) and read_cpu;
  read_done <= rddone(0) or rddone(1);
  read_error <= rderror(0) when rddone(0) = '1' else rderror(1);
  read_data <= data9 when rddone(0) = '1' else data7;
  result_epoch <= ep9 when rddone(0) = '1' else ep7;
  reader9 : entity work.nds_checkpoint_read_port
    generic map(TIMEOUT_CYCLES => READ_TIMEOUT_CYCLES)
    port map(clk => clk, cpu_clk => clk9, reset => reset, permit => held, epoch => epoch_i,
      read_request => rdrequest(0), read_address => read_address, read_epoch => read_epoch,
      ready => rdready(0), done => rddone(0), error => rderror(0), data => data9,
      result_epoch => ep9, cpu_paused => cpu_paused9, cpu_address => cpu_address9,
      cpu_data => cpu_data9, cpu_valid => cpu_valid9);
  reader7 : entity work.nds_checkpoint_read_port
    generic map(TIMEOUT_CYCLES => READ_TIMEOUT_CYCLES)
    port map(clk => clk, cpu_clk => clk7, reset => reset, permit => held, epoch => epoch_i,
      read_request => rdrequest(1), read_address => read_address, read_epoch => read_epoch,
      ready => rdready(1), done => rddone(1), error => rderror(1), data => data7,
      result_epoch => ep7, cpu_paused => cpu_paused7, cpu_address => cpu_address7,
      cpu_data => cpu_data7, cpu_valid => cpu_valid7);
end;
