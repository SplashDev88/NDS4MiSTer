# Pixel Grid experiment on v1.0.3

Base: release tag `v1.0.3`, commit `6eadde791669feef6cdbbcfb1be36403519ab23c`.
This experiment carries forward the beta18 LCD Grid 2 approximation and host
controls while preserving the v1.0.3 runtime, touchpad support and HBlank queue.

The user approved using DSP resources and allowing visual simplification if
needed. The first candidate preserves all existing gains, rounding and
saturation. Three unsigned 8-by-7 DSP multiplications replace the shift/add
trees. RGB and sync both take four enabled clock cycles rather than six.
Scale detection reuses one adder and comparator per axis over at most four
enabled clocks after the start of vertical sync. The existing 720p/1080p
blanking interval provides this time before the first picture pixel.
No framebuffer or additional block RAM is used. The grid remains after the
HDMI scaler and before OSD, and supports 2x through 5x integer scales at 720p
and 1080p. Off, 1x, noninteger scaling, unsupported modes and borders bypass
the effect with the same pipeline delay. Controls latch at frame boundaries;
pixels bypass the effect whenever live geometry differs from the geometry
captured at the last frame boundary.

The option appears in Display options only when the FPGA advertises support
for the current output mode. System > Save settings persists the choice;
Reset settings restores Off. The setting is separate from existing FPGA
status bits and touchpad settings. Old cores never receive grid writes.

## Routing approach

The beta18 attempt 13 finished with routing congestion, despite the old handoff
still describing it as running. Its fit report used 41,296/41,910 ALMs,
539/553 RAM blocks and 80/112 DSP blocks. The grid accounted for about 247
ALMs and 394 registers. Earlier fitted images failed game startup, including
with the grid Off; a core-only swap to original beta18 restored gameplay.
The physical cause of that regression is not established.

The actual v1.0.3 release build (`df7d7097...735be8c`) is a better baseline:
39,075/41,910 ALMs (93%), 540/553 RAM blocks and 80/112 DSP blocks, with
58.5% average interconnect use. Its build receipt is
`../../evidence/golden-cabin-idle-fault-20261122/build.json`. These numbers
describe the released core, before adding the grid.

This candidate uses v1.0.3 placement and timing settings. It does not inherit
the experimental beta18 register-location locks or added transfer constraints.
Only the grid, scaler geometry outputs, host control and diagnostic timing
reports are added. Synthesis and fitting must verify DSP inference and report
whole-core resources; isolated grid results cannot establish routability.
Hardware startup, gameplay and grid behavior determine acceptance. Static
timing remains diagnostic, as requested, and is retained with build results.

The fitter's estimated **ALMs needed** must not be confused with physical
placement occupancy. The released core reports 39,074.8 needed but 40,949.4
used in final placement; Test 2 reports 40,909.8 needed and 40,916.4 placed.
Most of that increase in the estimate comes from a lower estimate of logic
recoverable by dense packing (2,840.1 versus 935.6 ALMs). Both placements are
already dense. The grid's isolated area reduction is real, but whole-core
estimated utilization alone does not measure routing headroom.

## Reproduce the checks

From the experiment root:

```sh
python3 tools/test_pixel_grid.py --output build-pixel-grid/pixel
python3 tools/test_pixel_grid_scaler.py --output build-pixel-grid/scaler
python3 tools/test_pixel_grid_integration.py --output build-pixel-grid/integration
python3 -m unittest discover -s tools/standalone_host -p test_install_layout.py
```

The C++ tests `test_host_pixel_grid`, `test_host_touchpad`,
`test_host_display_menu`, `test_host_display`, `test_host_split_output`,
`test_host_dv_target` and `test_host` are built with C++17, optimization and
warnings treated as errors in the existing Linux host toolchain container.

`tools/fpga3d/measure_pixel_grid.py --reference OLD_RTL --shim COMPAT_LIBRARY
--output build-pixel-grid/area-v1` compares isolated virtual-pin fits under
identical device, area, seed and 148.5 MHz constraints. It saves source hashes,
stage exit codes, fit summaries and timing reports. Full-core compilation
uses `tools/fpga3d/build_fpga.py map fit asm sta` and the existing Quartus 17
compatibility library at `build-fpga3d/quartus/quartus_udev_compat.so`.

After map, fit and assembly pass, `tools/fpga3d/collect_pixel_grid_build.py`
binds the fresh RBF to source hashes and offline validation. Timing reports
are collected when ready and do not gate packaging. `tools/package_pixel_grid.py`
uses the SHA-verified v1.0.3 release archive to produce a separate launcher
and private kit, preserving the release renderer and guest patches. It verifies
every package checksum and marks hardware qualification pending.

## Status

Matched isolated Quartus 17 area measurements on the same Cyclone V device:

| Implementation | ALMs needed | Registers | DSP blocks | RAM blocks |
| --- | ---: | ---: | ---: | ---: |
| Original beta18 shift/add | 324 | 406 | 0 | 0 |
| DSP, parallel scale detection | 267 | 215 | 3 | 0 |
| DSP, shared scale detection (selected) | 231 | 263 | 3 | 0 |

The selected implementation reduces ALMs needed by 28.7% and registers by
35.2% relative to the original in this harness. Raw reports are in
`build-pixel-grid/area-v1` and `area-v2`. These are virtual-pin area probes,
including a virtual clock; their timing results are not representative of the
integrated HDMI path. Do not compare their absolute ALM counts directly with
the historical full-core grid hierarchy numbers.

The selected RTL passed 1,215,978 pixel/sync checks and 192 layout, gap, FPS,
rotation and resolution combinations. Tests cover all 256 channel values,
every supported scale/strength, malformed geometry, clock-enable stalls,
interrupted scale searches, reset and mid-frame changes. Real-scaler tests
passed 2x/3x/4x/5x. Seven host C++ suites and nine settings-migration tests
passed, and the ARM host binary built successfully. Final grid/OSD integration
passed 1,843,200 pixels, including 196,608 letter pixels and 196,608 menu
background pixels, and all 24 command/mode gates.

The first v1.0.3 full build passed synthesis, fitting/routing and assembly.
FPGA source: `2346c18acadc39e2e6ab0c93a3de960431a188c2`.
RBF SHA-256: `a84668c634299f3d5156af85fdfae59a350a925aba946f801a5131d662e1d24d`.
The later report-selector change is recorded separately in BUILD_INPUTS.json;
it does not change HDL or fitting constraints.

| Full-core fitted resource | Used | Available |
| --- | ---: | ---: |
| ALMs needed | 40,840 | 41,910 |
| RAM blocks | 540 | 553 |
| DSP blocks | 83 | 112 |

The grid hierarchy uses 152.6 ALMs needed (156.3 placed), 259 combinational
ALUTs, 235 dedicated logic registers, three DSP blocks and no RAM. The whole
core remains at 97% logic utilization: smaller module logic does not guarantee
equally dense packing elsewhere. Final average interconnect use is 62.5%;
peak total use is 88.5%, with peak vertical use 95.9%. These final report values
supersede the router's lower preliminary estimates.

All four timing corners were reported. The grid's worst setup slack is
-0.022 ns in the slow 1100 mV, -40 C model, from gain_q[1] to the blue-channel
DSP product register. Its worst hold slack is +0.122 ns. The full core also
has timing violations (worst reported setup -14.897 ns, hold -0.763 ns and
recovery -9.936 ns). Successful timing-tool execution does not mean timing
closure. Reports and slacks are retained as diagnostics; this candidate is
ready for the requested hardware acceptance tests.

Hardware Test 1 failed NSMB startup with the grid Off. A core-only swap to the
released v1.0.3 RBF, retaining the candidate host, renderer, ROM and isolated
save, restored the title screen and gameplay. The diagnostic ROM does run on
Test 1 and shows all four strengths at 3x and 4x, so visible grid operation is
not sufficient evidence of a working beta. Test 1 is not qualified.

Attempt 2 replaces raw-source/delayed-history edge detectors on the ARM9
WRAM, VRAM, main-RAM and IO completion paths, and the DMA request path, with
two receiver-clock capture stages plus history. Both inputs to each edge
detector are now receiver-clock registers. The held payload has extra time
to settle before the consumer observes completion. This addresses a hazard
reproduced in the earlier clock-skew model; hardware causation remains
unproven until the new FPGA image passes the same commercial-game tests.

The production receiver passed 160 pulse/toggle payload checks, 40 reset
arrival phases, eight real-membus IO/palette/OAM phase tests, and the complete
cache/main-RAM line-stream suite (128 matched streamed/nonstreamed misses,
ARM7 arbitration, warm hits and reset recovery, with detecting negative
controls). A real DMA producer also passed 108 transfer cases through the
new receiver, covering 16/32-bit transfers, fixed/incrementing/decrementing
addresses and three endpoint delays. Restoring the former detector makes
that scoreboard fail when payload routing delay is modeled. Full console
VHDL analysis also passed. Reproduce the added tests
with `bash tools/test_nds_related_clock_event.sh` and
`bash tools/test_nds_cache_line_stream.sh`, and
`bash tools/test_nds_dma9_request_bridge.sh`.

Hardware capture uses an isolated kit and save copies. The RetroTINK's LCD
function is disabled for comparison. At 1080p, Side by Side is a useful 3x
layout; Top/Bottom with 90-degree rotation gives 4x. A single unrotated screen
can use the core's 320x240 canvas and therefore bypass the grid at noninteger
DS pixel scaling. This is intentional bypass behavior, not a stronger setting.

No new FPGA image has yet been qualified for hardware or public release.

Attempt 2 routed but still failed NSMB startup after more than a minute, with
both published screens black. Return-event settling alone was insufficient.
Attempt 3 additionally receives the ARM9 IO request through the settled
peripheral-clock detector. This ensures `io9_lat_1x` has captured the payload
before `io9_ena` enables a peripheral. Other memory request paths are unchanged.
The real-membus regression passes 20 relative clock phases with modeled payload
routing delay; the previous raw-toggle request detector fails its payload
scoreboard. This remains a modeled hazard pending the third hardware build.
