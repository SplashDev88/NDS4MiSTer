# Castlevania gray-gradient rendering — 16 October 2026

Castlevania Beta7 is a focused ARM experiment based on Castlevania Beta6. It reduces repeated work in the translucent gray gradient drawn over the cave and combat rooms. Fixed-input rendering costs and live delivery measurements are reported separately below. The 60 fps target is not met. Performance Beta6 remains the general baseline.

## Change and scope

The new path accepts only proven, untextured translucent rectangles with equal RGB channels at each vertex, constant depth and W, ordinary alpha blending and the required linear interpolation conditions. It computes the gray channel once instead of interpolating three identical color channels and unused texture coordinates for every pixel. Both original vertical interpolators remain in use. A clipped horizontal span starts with the exact DS ascending or descending rounding formula and advances across depth-rejected pixels.

The existing depth selection and translucent plotting functions retain polygon-ID rejection, fog attributes, optional depth writes and lower antialiasing-layer blending. Both polygon slopes and final-pass bounds advance as before. One-pixel rectangles and unproven shapes keep the previous path. The optimization is enabled only by the existing Dawn of Sorrow USA revision 0 cartridge profile.

The initial prototype passed the full rendering checks but regressed native NSMB rendering by 3.07% and 3.04% in the two control scenes. It was rejected. The final implementation routes the gray overlay through the existing rectangle dispatch; the generic polygon function is byte-for-byte identical as source to Beta6. Final native controls below determine whether other games retain performance. The rejected prototype is excluded from the package and live candidate results.

The FPGA, host, stock 1 GHz clock, frame admission, controller mapping, packed VRAM replay and offline RTC fallback are retained. No new FPGA build or routing result is claimed.

## Fresh Beta6 profiling

Physical-output profiles covered 22 active seconds on the cave platform and six seconds in the crowded combat room. At 499 Hz CPU-clock sampling, general polygon rendering accounted for 11.15% and 9.64% of statistical leaf samples; translucent plotting accounted for 5.14% and 4.57%. The captured room frames each contain one full-screen untextured gray gradient. These are CPU sample proportions, not inclusive costs or frame rates. All performance acceptance uses separate unprofiled runs.

## Native fixed-input measurements

Physical Cortex-A9 at 1 GHz, with one rendering thread pinned to one core and a stopped, verified Main menu on the other. Each scene uses baseline/candidate/candidate/baseline order, three samples per leg, 16 warmup renders and 100 measured renders per sample. Complete native color/depth/attribute hashes matched in all five scenes. Clock settings and menu affinity were restored. These are rendering CPU costs, not whole-game FPS.

| Saved scene | Beta6 ms/render | Beta7 ms/render | Change |
|---|---:|---:|---:|
| bat-live | 30.950 | 25.534 | -17.50% |
| combat-live | 29.648 | 24.344 | -17.89% |
| nsmb-castle | 11.877 | 11.908 | +0.26% |
| nsmb-castle-left | 11.640 | 11.656 | +0.14% |
| mario-kart-heavy | 35.899 | 35.921 | +0.06% |

The NSMB and Mario Kart controls do not enable the new game-specific path. Measured changes are within 0.3% of baseline and consistent with run-to-run variation; no optimization of those games is claimed.

## Unprofiled RetroTINK controls

Analog RGBS at approximately 59.64 Hz passed through the RetroTINK-4K and the retained 1080p60 capture chain. No new HDMI or DV1 qualification is claimed. No sampling profiler or SSH polling ran during measured gameplay windows. Accepted recordings had zero reported host/helper faults, zero OBS rendering/encoding drops and an audio signal. Audio presence does not establish the absence of hitches or clipping.

The service headers count completed screen-pair publications. They are not distinct visible animation FPS. Approximately 60 LCD tags per second does not mean 60 newly rendered pictures. Timelines are copied after the measured window; any raced timeline records are excluded while independently sampled, stable service-header counts remain usable.

| Trial | Build | Pairs | Seconds | Pairs/s | Median interval ms | p95 ms |
|---|---|---:|---:|---:|---:|---:|
| C13_BAT_BASE_CLEAN | Beta6 | 373 | 21.997 | 16.957 | 58.281 | 69.051 |
| C13_BAT_BASE_REPEAT | Beta6 | 374 | 21.980 | 17.015 | 58.631 | 67.247 |
| C13_BAT_CAND_CLEAN | Beta7 | 412 | 22.013 | 18.716 | 53.412 | 64.244 |
| C13_BAT_CAND_REPEAT | Beta7 | 416 | 21.949 | 18.953 | 53.081 | 62.488 |
| C13_FIGHT_BASE_IDLE | Beta6 | 100 | 6.036 | 16.568 | 59.898 | 75.780 |
| C13_FIGHT_BASE_REPEAT | Beta6 | 103 | 5.984 | 17.211 | 58.422 | 71.593 |
| C13_FIGHT_CAND_IDLE | Beta7 | 108 | 5.988 | 18.035 | 55.867 | 65.996 |
| C13_FIGHT_CAND_REPEAT | Beta7 | 106 | 6.000 | 17.667 | 55.515 | 70.406 |
| C13_NSMB_BASE_CLEAN | Beta6 | 1151 | 26.003 | 44.265 | excluded | excluded |
| C13_NSMB_CAND_CLEAN | Beta7 | 1176 | 26.013 | 45.208 | 23.179 | 30.387 |

| Scene | Baseline mean pairs/s | Candidate mean pairs/s | Change |
|---|---:|---:|---:|
| BAT | 16.986 | 18.835 | +10.88% |
| FIGHT | 16.890 | 17.851 | +5.69% |
| NSMB | 44.265 | 45.208 | +2.13% |

The cave uses 22 seconds on the bat platform without controller input. Combat uses six seconds with active enemies and no attack input to avoid pickup menus. Each Castlevania build has two fresh isolated suspend trials per room, in baseline/candidate/candidate/baseline order. Setup damage, enemy phases, knockback, camera position and projectile timing can vary, so these short observations do not establish whole-game speed or a long combat soak. NSMB uses a 26-second repeated-jump sequence at the castle entrance.

## Correctness and provenance

- Full ARM helper self-test passed.
- 27,836,416 independent gray interpolation checks passed, including every pair of native 9-bit color values, ascending/descending rounding, clipped starts and complete rows across widths 1–512.
- 512 new gray-rectangle cases matched both Beta6 and the independent uncached reference in visible output and complete color/depth/attribute buffers. The census confirms 224 accepted shapes and 288 fallback cases, including narrow widths, unequal channels, perspective, unequal depth, equal-depth mode, disabled blending, textured polygons, opaque alpha and toon mode.
- All 5,388 prior raster cases retained exact Beta6 full buffers. Of those, 5,132 independently match uncached rendering. Another 256 one-pixel cases are baseline compatibility checks; 40 retain existing cached-versus-uncached buffer differences, including two visible differences. This change does not claim to fix those legacy differences.
- Combined: 5,900 cross-build full-buffer cases, including 5,644 independent uncached-reference cases.
- All 48 sequential snapshots retained full buffers, visible rows, polygons, render state and texture/palette hashes. Ten combat snapshots are paused or transition frames.
- All 160 serial, split-worker, band-worker and delayed-worker renders retained exact buffers.
- Both saved room controls exercise the new full-screen gray path and retain Beta6 hashes.
- Source correspondence checks cover 851 inputs. The only private/public source difference is an unlinked standalone profile unit test. Temporary private-build overlays were restored.
- The rig protects 54 original files and saves. Trials use isolated save copies. No ROMs, saves, settings or captured game media are included in the source or ZIP.

Baseline source: `d892c75831df99c2997bbd4f075740e302a35f01` (Castlevania Beta6).
Candidate helper SHA-256: `e87d7ef159e2b45a3269b29d35a123a64ad102603b5b0045f11440e94d69a269`.

## Remaining work

The 60 fps target remains unmet. Profile this beta again before choosing further work on translucent blending, geometry and replay. More repeatable combat states and longer survivable trials would strengthen gameplay conclusions. SIMD or packed-channel blending needs separate exactness and native performance checks; it is not included here.

This is a private focused beta. Full playthroughs, other cartridge revisions and promotion to the general beta are not claimed. See [Beta6 measurements](CASTLEVANIA_RECTANGLE_SETUP_PERFORMANCE_20261016.md) for the previous change.
