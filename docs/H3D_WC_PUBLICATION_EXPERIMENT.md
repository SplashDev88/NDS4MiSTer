# Write-combined publication — v0.4.0-beta.3

This software-only release builds on the accepted v0.4.0-beta.2 FPGA and ARM
renderer. The FPGA binary is unchanged. It changes no emulated CPU behavior,
clocks, rendering math, Engine B/TATE policy, audio, saves or frame pacing.

The earlier helper already had a WC/NEON pixel path, but recent releases did
not include the driver. This release includes a restricted driver, prevents
Device/WC aliases, and acquires singleton ownership before any physical mapping.

## Measured result and limits

A controlled Device → WC → Device test at stock 1 GHz measured the complete
production pixel-publication routine with deterministic Engine A+B images:

| Changed pixels | Device 1 | WC | Device 2 | Mean time reduction |
| --- | ---: | ---: | ---: | ---: |
| All | 9.294 ms | 1.823 ms | 9.286 ms | 80.4% |
| One in sixteen blocks | 1.724 ms | 1.172 ms | 1.667 ms | 29.7–32.0% |

Each workload had 8 warmups and 48 measured publications per run. All 336 pixel
readbacks matched. The gain includes the existing bulk/NEON pixel writer;
it is not a pure DDR-bandwidth or game-FPS result. Descriptor/ACK storage was
private heap memory, so real FPGA ACK waiting was excluded. Sparse WC worst-case
latency exceeded one Device run despite lower mean and p95; universal hitch
reduction is not established.

Normal NSMB tests reached animated menus, its movie and world map. The user
reported a large perceived speed gain on a WC test with experimental FPGA
arbitration; that comparison does not isolate WC-only game FPS. This package
uses the accepted stability FPGA, excluding that experimental arbitration.
Broad gameplay/audio and reset/ROM-switch qualification on the final WC pair
remains limited. Strange Journey still freezes during the intro in both modes.

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
normal core/ROM lifecycle. These commands are for developer comparison; ordinary users just run the
release Kickstart launcher. The driver is optional and kernel rejection falls
back to Device publication. There is no forced loading or kernel replacement.

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

## Verification

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

Normal module insertion, restricted aperture checks and unloading also passed
on the physical MiSTer running Linux 5.15.1. See kernel/nds_mem_wc for the exact
source, kernel configuration, build instructions, provenance and GPL-2.0 license.
