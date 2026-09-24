# Disconnected Wi-Fi can stall the hybrid graphics service

On the tested MiSTer 5.15.1 kernel (`CONFIG_PREEMPT_NONE`), the Realtek
8188eu adapter repeatedly reinitialized while looking for an unavailable
wireless network. A scheduler trace recorded `wpa_supplicant` occupying
CPU1 for 100.066 ms. The FIFO-priority graphics publication worker was
already runnable but waited 99.919 ms; packet intake waited 99.860 ms.
Raising the renderer priority cannot preempt this kernel work.

The FPGA retains 512 HBlank events, approximately 32.5 ms at the current
line cadence. A longer interruption can exhaust that queue and latch
source fault `0x100`, stopping the game. The same fault bit also covers the
256-entry frame queue, so a public crash report alone cannot identify the
individual queue. The much larger private ARM replay queue does not protect
the FPGA from an interruption before packets reach ARM memory.

## Reproduction and mitigation

On the accepted v0.4.0-beta.5 core and ARM helper, Lunar Knights' opening
sequence faulted about 15 seconds into a monitored run with wireless retries
active. Stopping only the disconnected wireless service, then loading the
same ROM again, completed a three-minute capture with zero FPGA/HPS faults.
Paired frame acknowledgements averaged 59.54 per second in that capture.
The user independently reported substantially smoother playback. The core,
ARM executable, write-combining mode, 1 GHz clock and game settings were
unchanged. These figures describe that movie test, not every game.

Kickstart now checks wlan0 and wlan1 once before starting or adopting the
resident service. It stops retries only if the adapter has neither carrier
nor a global IP address and is not completing an association/key handshake. This
applies to wired and completely offline play. A verified PID, executable,
start time and single-interface command line are required; stale PID files
and multi-interface daemons are skipped. The link is lowered only after the
verified process exits and the disconnected checks still pass.

Connected Wi-Fi remains active. Saved wireless configuration is never edited;
normal Wi-Fi startup resumes after reboot. There is no networking monitor
or added work in the gameplay loop. Failure to establish a safe match leaves
the adapter alone rather than preventing the core from starting.

`tools/test_h3d_wifi_guard.py` exercises offline/wired operation, connected
and transitioning Wi-Fi, IPv4/IPv6 addresses, absent control sockets, stale
and reused PIDs, multi-interface daemons, unsuccessful shutdown and repeated
Kickstart calls. It and the existing supervisor regression pass on the host
and under BusyBox 1.33.1. This avoids the observed wireless-triggered stall;
it does not make the FPGA queues immune to unrelated long host/kernel stalls.
