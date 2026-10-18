-- SPDX-License-Identifier: GPL-3.0-or-later
-- Experimental owner pause barrier. Default owners are the two CPUs.
-- Additional owners require their own real drain/hold and delivery receipts.
-- Not instantiated by the production console. Keep this clock running while
-- CPUs are paused. request is synchronous here; acknowledgements are levels
-- from the CPU clock domains. nds_checkpoint_endpoint synchronizes requests.
-- Reset must cover the coordinator, endpoints and CPUs together for at least
-- three rising edges in every domain. This is not an independent host reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_checkpoint_coordinator is
  generic (TIMEOUT_CYCLES : positive := 1048576;
           LEASE_CYCLES : positive := 33513982;
           OWNER_COUNT : positive := 2);
  port (
    clk, reset        : in std_logic;
    request           : in std_logic;
    -- Synchronous host strobes, tagged with this attempt's epoch. A held-high
    -- keepalive is NOT repeated progress. Acquisition has its own deadline.
    keepalive         : in std_logic := '0';
    keepalive_epoch   : in unsigned(31 downto 0) := (others => '0');
    cpu_paused_async  : in std_logic_vector(OWNER_COUNT-1 downto 0);
    request_seen_async : in std_logic_vector(OWNER_COUNT-1 downto 0);
    cpu_request       : out std_logic;
    ready             : out std_logic;
    busy              : out std_logic;
    pair_paused       : out std_logic;
    timed_out         : out std_logic;
    release_stalled   : out std_logic;
    lease_expired     : out std_logic := '0';
    epoch             : out unsigned(31 downto 0);
    cpus_observed     : out std_logic := '0'
  );
end;

architecture rtl of nds_checkpoint_coordinator is
  constant ALL_HIGH : std_logic_vector(OWNER_COUNT-1 downto 0) := (others => '1');
  constant ALL_LOW : std_logic_vector(OWNER_COUNT-1 downto 0) := (others => '0');
  type phase_type is (DRAIN, IDLE, ACQUIRE, HELD, CANCEL_DELIVERY, WAIT_LOW);
  signal phase : phase_type := DRAIN;
  signal ack_meta, ack_sync : std_logic_vector(OWNER_COUNT-1 downto 0) := (others => '0');
  signal seen_meta, seen_sync : std_logic_vector(OWNER_COUNT-1 downto 0) := (others => '0');
  signal elapsed : natural range 0 to TIMEOUT_CYCLES - 1 := 0;
  signal epoch_i : unsigned(31 downto 0) := (others => '0');
  signal timeout_i, stalled_i : std_logic := '0';
  signal lease_i, keepalive_d : std_logic := '0';
  signal lease_elapsed : natural range 0 to LEASE_CYCLES - 1 := 0;
  attribute async_reg : string;
  attribute async_reg of ack_meta, ack_sync : signal is "true";
  attribute async_reg of seen_meta, seen_sync : signal is "true";
begin
  assert OWNER_COUNT >= 2 report "checkpoint requires both CPU owners" severity failure;
  -- Observation for final timestamp acquisition; never a capture permit.
  cpus_observed <= '1' when (phase = ACQUIRE or phase = HELD) and request = '1' and
    ack_sync(1 downto 0) = "11" and seen_sync(1 downto 0) = "11" else '0';
  cpu_request <= '1' when phase = ACQUIRE or phase = HELD or phase = CANCEL_DELIVERY else '0';
  pair_paused <= '1' when phase = HELD and request = '1' and ack_sync = ALL_HIGH else '0';
  ready <= '1' when phase = IDLE else '0';
  busy <= '0' when phase = IDLE or phase = WAIT_LOW else '1';
  timed_out <= timeout_i;
  release_stalled <= stalled_i;
  lease_expired <= lease_i;
  epoch <= epoch_i;

  process(clk)
  begin
    if rising_edge(clk) then
      ack_meta <= cpu_paused_async;
      ack_sync <= ack_meta;
      seen_meta <= request_seen_async;
      seen_sync <= seen_meta;
      keepalive_d <= keepalive;
      if reset = '1' then
        phase <= DRAIN;
        elapsed <= 0;
        timeout_i <= '0';
        stalled_i <= '0';
        epoch_i <= (others => '0');
        lease_i <= '0';
        keepalive_d <= '0';
        lease_elapsed <= 0;
      else
        case phase is
          when DRAIN =>
            -- Rearm only after the low request AND CPU release return from
            -- both domains. Each attempt first observes the high request,
            -- so an old low acknowledgement cannot satisfy this phase.
            if ack_sync = ALL_LOW and seen_sync = ALL_LOW then
              if request = '0' then phase <= IDLE; else phase <= WAIT_LOW; end if;
              elapsed <= 0;
              stalled_i <= '0';
            elsif elapsed = TIMEOUT_CYCLES - 1 then
              stalled_i <= '1';
            else
              elapsed <= elapsed + 1;
            end if;
          when IDLE =>
            if request = '1' then
              epoch_i <= epoch_i + 1;
              timeout_i <= '0';
              lease_i <= '0';
              stalled_i <= '0';
              elapsed <= 0;
              phase <= ACQUIRE;
            end if;
          when ACQUIRE =>
            if request = '0' then
              phase <= CANCEL_DELIVERY;
              elapsed <= 0;
            elsif ack_sync = ALL_HIGH and seen_sync = ALL_HIGH then
              phase <= HELD;
              elapsed <= 0;
              lease_elapsed <= 0;
            elsif elapsed = TIMEOUT_CYCLES - 1 then
              timeout_i <= '1';
              phase <= CANCEL_DELIVERY;
              elapsed <= 0;
            else
              elapsed <= elapsed + 1;
            end if;
          when HELD =>
            if request = '0' or ack_sync /= ALL_HIGH or seen_sync /= ALL_HIGH then
              -- An unexpected lost acknowledgement invalidates the pair.
              -- Release the remaining CPU; never leave it silently held.
              if request = '1' then timeout_i <= '1'; end if;
              phase <= CANCEL_DELIVERY;
              elapsed <= 0;
            elsif keepalive = '1' and keepalive_d = '0' and keepalive_epoch = epoch_i then
              lease_elapsed <= 0;
            elsif lease_elapsed = LEASE_CYCLES - 1 then
              -- Host disappeared. Invalidate the checkpoint and use the same
              -- delivery/release handshake as an explicit cancellation.
              lease_i <= '1';
              timeout_i <= '1';
              phase <= CANCEL_DELIVERY;
              elapsed <= 0;
            else
              lease_elapsed <= lease_elapsed + 1;
            end if;
          when CANCEL_DELIVERY =>
            -- Finish the high phase even if cancellation precedes request
            -- arrival. Dropping it early could let a late CPU ack satisfy a
            -- later attempt. This receipt does NOT wait for CPU pause.
            -- A stopped clock cannot be promised a successful release.
            if seen_sync = ALL_HIGH then
              phase <= DRAIN;
              elapsed <= 0;
            elsif elapsed = TIMEOUT_CYCLES - 1 then
              stalled_i <= '1';
            else
              elapsed <= elapsed + 1;
            end if;
          when WAIT_LOW =>
            -- A timed-out request must be withdrawn before another attempt.
            -- Keeping the button/host request high cannot retry indefinitely.
            if request = '0' then phase <= IDLE; end if;
        end case;
      end if;
    end if;
  end process;
end;
