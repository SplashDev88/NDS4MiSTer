-- SPDX-License-Identifier: GPL-3.0-or-later
-- Final local acquisition stage. Status inputs do not stop producers: the
-- caller must hold them through the common request/delivery/release handshake.
-- External status is already synchronous to clk and covers host ownership.
library ieee;
use ieee.std_logic_1164.all;
entity nds_checkpoint_console_guard is
  generic(LOCAL_OWNERS : positive := 14);
  port(clk, reset, hold, cpus_observed : in std_logic;
    local_ready : in std_logic_vector(LOCAL_OWNERS-1 downto 0);
    island_idle_async : in std_logic;
    external_seen, external_paused, rtc_ready : in std_logic;
    local_seen, local_paused, local_idle, rtc_request : out std_logic);
end;
architecture rtl of nds_checkpoint_console_guard is
  signal island_meta, island_sync : std_logic := '0';
  signal eligible, sample : std_logic;
  signal quiet : integer range 0 to 3 := 0;
  attribute async_reg : string;
  attribute async_reg of island_meta, island_sync : signal is "true";
begin
  local_idle <= '1' when reset = '0' and island_sync = '1' and
    local_ready = (local_ready'range => '1') else '0';
  eligible <= hold and cpus_observed and local_idle and external_seen and external_paused;
  sample <= '1' when eligible = '1' and quiet = 3 else '0';
  rtc_request <= sample;
  local_paused <= sample and rtc_ready;
  process(clk) begin
    if rising_edge(clk) then
      if reset = '1' then
        island_meta <= '0'; island_sync <= '0'; local_seen <= '0'; quiet <= 0;
      else
        island_meta <= island_idle_async; island_sync <= island_meta;
        -- Receipt is independent of completion, so timeout cleanup never
        -- waits for a device which cannot finish its transaction.
        local_seen <= hold;
        if eligible = '0' then quiet <= 0;
        elsif quiet < 3 then quiet <= quiet + 1; end if;
      end if;
    end if;
  end process;
end;
