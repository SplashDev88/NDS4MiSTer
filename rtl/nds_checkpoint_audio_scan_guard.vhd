-- SPDX-License-Identifier: GPL-3.0-or-later
-- Private rotation-access experiment. This guards channel ordering only;
-- image identity/coverage, external ownership and host validation remain required.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity nds_checkpoint_audio_scan_guard is
 port(capture_request,capture_held,restore_active:in std_logic;
      channel_order_ready,outer_return_permission:in std_logic;
      requested_address:in unsigned(8 downto 0);
      device_hold,return_permission:out std_logic;
      sound_address:out unsigned(8 downto 0));
end;
architecture rtl of nds_checkpoint_audio_scan_guard is
begin
 -- channel_order_ready must depend only on registered channel position;
 -- feeding the selected-address/step decision back here creates a logic loop.
 -- Keep ALL device owners held, not only the CPU return path. DMA and timers
 -- must not resume while hidden audio fields are temporarily rotated.
 device_hold <= capture_request or restore_active or not channel_order_ready;
 return_permission <= outer_return_permission and channel_order_ready and not restore_active;
 -- A global word requires canonical channel ordering. Force cleanup before
 -- acquisition is complete, on owner loss, and throughout cancellation.
 sound_address <= requested_address when (capture_request='1' and capture_held='1') or restore_active='1' else to_unsigned(256,9);
end;
