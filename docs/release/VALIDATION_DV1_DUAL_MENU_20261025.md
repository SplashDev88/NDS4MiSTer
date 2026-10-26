# Dual-screen DV1 menu width (private beta, 2026-10-25)

The user selected the legacy finer menu, confirmed that Main-only DV1 looked correct, and requested double width only in dual-screen DV1.

Implementation: `e4a6d7ea7895349fb26e34f39ba099d75a447980`, on the legacy-menu rollback `2720b8d6ae5d9b1ba24c9d82e88f4a90127b4b13`. The superseded all-dual build was stopped during fitting; its source and logs are retained. Only `sys/osd.v` and `sys/sys_top.v` differ from the retained stock-loading beta's frozen FPGA source inputs. The host is retained byte-for-byte (SHA-256 `d6e789772cc238e626b2b6dedaea1159142ffa02a8cfe3f231a9fa2f82dcd6c6`, source `ee6ac636cdba4dfc1b1492d5766cd3eff2354b22`), as is the renderer (`bb13597d032d9d365b9763efa3866594c8562e5476b4c02b93ba55754f9f7570`). FMV caching, stock loading progress, RTC and Right Stick Range remain in that host. No Speed Hacks menu was added.

The digital OSD uses legacy font sampling, with an optional larger horizontal sampling period. Hardware comparison showed that side-by-side and native-rotated Top/Bottom already had normal or wide menus. The final enable gate therefore requires native DV1 with metadata, a stacked source canvas, and no applied native rotation. Main, Touch, Side-by-side, native-rotated modes, CRT-target, scaled HDMI, DV2/DVI and the independent analog OSD retain their previous sampling. The host continues sending the legacy OSD sampling flag to the receiver.

Widening is capped at the available transport width so all 256 bitmap columns remain visible and centered. `floor(line_clocks/264)` provides room for the bitmap plus legacy centering/pipeline margins. For native lines below 4096 clocks, shifts plus one correction calculate this bound without a hardware divider. The requested width is twice the original period, limited to that bound, and never narrower than the original. The RGB/sync pipeline, bitmap storage, menu height and game video are unchanged.

Representative simulation cases:

| Canvas and transport repeat | Legacy period | New period | Width factor |
|---|---:|---:|---:|
| Top/Bottom, 256x392, repeat 3 | 1 | 2 | 2.00 |
| Main, 320x240, repeat 10 | 6 | 6 | 1.00 |
| Side-by-side, 512 or 520 wide, repeat 6 | 6 | 6 | 1.00 |
| Side-by-side, 536 wide, repeat 6 | 6 | 6 | 1.00 |
| Rotated stacked canvas, 392x256, repeat 3 | 2 | 2 | 1.00 |
| Narrow rotated side-by-side, 192x520, repeat 2 | 1 | 1 | 1.00 (fit cap) |

The initial all-dual implementation passed 2,269,184 output/layout gate cases and 26,820,240 raster samples, but was superseded after the additional hardware comparisons. The final narrower gate passed 4,538,368 output/layout/rotation cases and 28,546,536 raster samples across 21 cases. The actual 3-clock repeat used for native-rotated stacked output is included. The raster oracle starts from the original MiSTer OSD and uses a separate integer-division width specification. It checks complete RGB/sync output, visible width, centering, hidden-menu passthrough, single-screen/legacy equivalence and simultaneous independent analog output. The first test attempt exposed a Verilator testbench variable optimization issue (a write-only counter was localized between coroutines); the measurement was corrected before the successful run. No production behavior was changed to accommodate it.

Reproduce with `python3 tools/test_dv1_dual_menu_gate.py --output <directory>` and `python3 tools/test_dv1_legacy_width.py --output <directory>`. Both use the existing `nds4mister-rtl-verilator:24.04` Docker image. Test output and exact build inputs are archived with the private package.

Quartus 17.0.2 map, fit, assembly and timing-report stages completed with exit code 0. Core SHA-256: `7d8f1a06d9009f9e0cc7223c0d30f5895eb044c0dbf85c29a20b3e25eea10d3a`. The fit uses 34,769 / 41,910 ALMs, 538 / 553 RAM blocks and 27 / 112 DSP blocks. Reported worst setup/hold/recovery slack: -14.918 / +0.066 / -13.054 ns. The prior stock-loading core had -14.912 / +0.086 / -13.841 ns. These builds do not close static timing.

Live capture through the unchanged RetroTINK-4K profile measured the unrotated stacked menu at 228 pixels wide, compared with 113 before (capture edge rounding), with height unchanged at 342 pixels and center preserved. Main-only stayed exactly 409 by 342 pixels; the static menu crop was pixel-for-pixel identical. Side-by-side and CCW-rotated stacked output retained the prior metadata packets and legacy menu widths. The legacy upright menu is intentional.

NSMB cold-booted from an isolated ROM alias/save copy with its lookup+bones runtime patches active. Testing reached the World 3 map and World 3-1, exercised bounded jump input, opened and closed the menu, and exited cleanly. Opening the menu preserved captured game bounds `(470, 102, 810, 623)` and all geometry metadata; only the expected receiver OSD flag changed. Two host sessions exited cleanly. No new FPS or input-to-photon measurement was performed.

All 17 protected configuration/launcher files and 1,120 pre-existing save records were unchanged. Only a separate test save was added. The RetroTINK profile was not altered. HDMI, DV2/DVI and independent analog isolation were checked in simulation, not a new physical cable sweep. The package is a private beta for bounded menu testing, not a broader release qualification.

Limits: the legacy menu remains upright in the core while native game rotation remains available. Only unrotated Top/Bottom is widened; all native-rotated layouts and side-by-side retain their original width. Height is unchanged, so this is a width correction rather than a promise of identical physical menu dimensions in every layout. Receiver profiles can react to the legacy OSD sampling flag. FPGA static timing closure remains unresolved. This change adds no framebuffer or video pipeline stage, but it is not an input-to-photon latency measurement.
