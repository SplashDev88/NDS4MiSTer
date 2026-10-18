-- SPDX-License-Identifier: GPL-3.0-or-later
-- Request crossing for the experimental CPU-pair pause barrier.
-- Both clocks must keep running. CPU acknowledgement remains asserted until
-- this synchronized request is withdrawn; the coordinator synchronizes it.
library ieee;
use ieee.std_logic_1164.all;

entity nds_checkpoint_endpoint is
  port (
    clk, reset    : in std_logic;
    request_async : in std_logic;
    cpu_request   : out std_logic;
    request_seen  : out std_logic
  );
end;

architecture rtl of nds_checkpoint_endpoint is
  signal request_meta, request_sync : std_logic := '0';
  attribute async_reg : string;
  attribute async_reg of request_meta, request_sync : signal is "true";
begin
  cpu_request <= request_sync;
  request_seen <= request_sync;
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        request_meta <= '0';
        request_sync <= '0';
      else
        request_meta <= request_async;
        request_sync <= request_meta;
      end if;
    end if;
  end process;
end;
