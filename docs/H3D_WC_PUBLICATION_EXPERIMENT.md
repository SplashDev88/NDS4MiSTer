# Write-combined publication A/B candidate — 2026-09-16

This software-only experiment starts from accepted helper source
`b2b8f12fd1f0ccdfd2f82916d74abda1dcc73f67`. It changes no FPGA RTL, emulated
CPU behavior, clocks, rendering math, Engine B/TATE policy, audio, saves,
frame admission or pacing. Hardware improvement is not yet established.

The accepted helper already had WC/NEON pixel publication and a Device-memory
fallback. The module was absent from the inspected installation and recent
release packages. This candidate restores its tracked source and provides a
controlled test of that existing path.

## Mapping change

The physical helper now owns two nonoverlapping mappings:

- Device control/packet memory: `0x3fc00000`, length `0x100000`.
- Pixel memory: `0x3fd00000`, length `0x300000`, mapped either WC or Device.

The old four-MiB Device mapping is never created on physical hardware, so it
cannot alias the WC pixel pages. The singleton lock is acquired before any
mapping, including on rejected duplicate startup. A missing or rejected WC
node falls back to a separate Device pixel mapping. File-backed tests retain
the original contiguous four-MiB file layout and never open physical devices.

The existing `dsb sy` publication completion, aligned control accesses,
descriptor ACK ownership and session/quiesce checks are unchanged. Do not
add a second CPU mapping with different attributes to inspect pixel pages.

## Same-binary A/B

The private test control is `NDS4MISTER_H3D_DISABLE_WC`:

- `0` or unset: try restricted `/dev/nds_mem_wc`, then `/dev/mem_wc`, with
  Device fallback. The enabled startup message must be observed before
  calling this a WC test.
- `1`: explicitly use Device pixel memory even if the module is installed.
- Other values are rejected by the helper rather than ambiguously selecting
  a test mode.

Kickstart forwards the choice. It only takes effect when starting a fresh
helper; an idempotent start of an already-running helper does not change it.
Both runs use the same candidate binary, module, launcher, accepted FPGA,
stock 1 GHz, Engine B/rotation settings, unchanged private ROM and isolated save.
Keep `NDS4MISTER_H3D_DIAGNOSTICS=0`: the existing diagnostic mode disables the
direct-publication path and would change the workload being compared.

After a normal backed-up return to MENU and helper stop, the operator can
start the chosen side using the ordinary launcher:

```sh
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  NDS4MISTER_H3D_DIAGNOSTICS=0 NDS4MISTER_H3D_DISABLE_WC=1 \
  /media/fat/Scripts/NDS_Kickstart.sh start
```

Use `0` for WC, confirm its startup log and `/proc/PID/maps`, then follow the
normal core/ROM lifecycle. This document does not itself install or execute
anything on the board. The private payload is not a release installer.

Observe the same movie/3D scene for at least two minutes and use an A/B/A
comparison. Evaluate complete-frame progress, image correctness, audio,
published/acknowledged frame cadence and available backpressure telemetry;
do not report a memory microbenchmark as game FPS. For Strange Journey the
unchanged game must complete the intro and respond afterward. WC does not
directly change its FPGA ARM9 MainRAM copy loops or queue-underflow guard.

Rollback uses a normal MENU transition and helper stop, restores the backed-up
helper/launcher/hash files and original absence/presence of the optional
module pair, then reloads the accepted core normally. Do not overwrite saves,
change settings or force-kill MiSTer.

## Offline verification

The physical mapping test uses real shared temporary files with syscall
injection, never `/dev/mem`. It covers both WC nodes, rejected/absent nodes,
forced Device, true mapping bounds and backing offsets, short files, syscall
failures and complete cleanup. Restoring the old overlapping Device extent
is a negative control that the test detects.

The service self-test expands Engine B policy coverage to 24 combinations:
contiguous baseline/split Device/split WC, Engine B Off/On, direct/queued
publication and sync/async replay. It checks descriptor/pixel correctness,
unwritten legacy alias storage, exterior guards and session invalidation.
Existing ABI/bank tests, fake-memory lifecycle, duplicate startup, launcher
module/hash handling and the accepted display-capture oracle remain required.
The launcher test verifies that both A/B choices arrive with diagnostics Off
and direct publication On. Host and emulated ARM results are not hardware
throughput measurements.
