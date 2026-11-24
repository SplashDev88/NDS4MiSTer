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
background pixels, and all 24 command/mode gates. Full-core synthesis/fitting
is in progress.

No new FPGA image has been qualified for hardware or public release.
