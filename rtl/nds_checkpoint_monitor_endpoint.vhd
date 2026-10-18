-- SPDX-License-Identifier: GPL-3.0-or-later
-- CPU-assisted maintenance endpoint for the existing four-phase pause barrier.
-- Keep the delivery receipt high until maintenance has actually returned: a
-- capture can still be running after an acquisition timeout withdraws request.
-- No product console instantiates this adapter yet. Reset must also cover CPU.
library ieee;
use ieee.std_logic_1164.all;
entity nds_checkpoint_monitor_endpoint is
  port(clk,reset,request_async:in std_logic;
    monitor_active,monitor_paused,monitor_ready,monitor_error:in std_logic;
    -- Explicit common release permission; normal cancellation may tie high,
    -- but fresh restore must hold it low until every machine owner is ready.
    return_permission:in std_logic;
    monitor_request,monitor_continue,monitor_release:out std_logic;
    capture_paused,request_seen:out std_logic);
end;
architecture rtl of nds_checkpoint_monitor_endpoint is
  signal request_sync:std_logic;
  signal seen:std_logic:='0';
begin
  synchronizer:entity work.nds_checkpoint_endpoint
    port map(clk=>clk,reset=>reset,request_async=>request_async,
      cpu_request=>request_sync,request_seen=>open);
  monitor_request<=request_sync;
  monitor_continue<=not reset and not request_sync and monitor_paused and not monitor_ready and not monitor_error;
  monitor_release<=not reset and not request_sync and monitor_ready and not monitor_error and return_permission;
  capture_paused<=monitor_paused and not monitor_ready and not monitor_error and not reset;
  request_seen<=seen;
  process(clk) begin
    if rising_edge(clk) then
      if reset='1' then seen<='0';
      else seen<=request_sync or monitor_active;end if;
    end if;
  end process;
end;
