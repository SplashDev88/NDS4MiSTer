# Castlevania back-facing texture spans — 16 October 2026

Castlevania Beta5 is a focused ARM experiment built on Beta4. Two short cave trials per build showed a small completed-picture delivery improvement. The fixed cave frame used 2.13% less raster CPU time and the fixed combat frame used 1.06% less. The 60 fps target is not met. Performance Beta6 remains the general baseline.

## Change

Eligible back-facing neutral textured rectangles now use integral texture-coordinate stepping for interior pixels. This extends the existing exact Castlevania USA revision 0 path. Back faces retain strict less-than depth testing; they never acquire the front-facing equal-depth exception. Transparent rows, texture wrapping, alpha rejection, blending and both antialiasing layers retain their original results. Nonintegral rows and polygon edges retain the previous implementation.

The FPGA, host, stock 1 GHz ARM clock, frame-admission policy, Beta4 packed VRAM replay, controller mapping and offline RTC fallback are retained. No new FPGA build or timing closure is claimed.

## Native fixed-input raster controls

Runs used the physical Cortex-A9 at 1 GHz, one renderer thread pinned to one core, a stopped and verified menu on the other core, six samples per binary per scene in baseline/candidate/candidate/baseline order. Each sample has 16 warmup renders followed by 100 measured renders. All three full native buffer hashes matched. These are isolated 3-D raster CPU costs, not whole-game FPS.

| Saved frame | Beta4 CPU ms/render | Candidate CPU ms/render | Change |
|---|---:|---:|---:|
| bat-live | 36.135 | 35.364 | -2.13% |
| combat-live | 33.439 | 33.083 | -1.06% |
| nsmb-castle | 11.853 | 11.882 | +0.25% |
| nsmb-castle-left | 11.613 | 11.725 | +0.96% |
| mario-kart-heavy | 35.570 | 35.123 | -1.26% |

The exact Castlevania profile is disabled for NSMB and Mario Kart. Despite unchanged fallback rendering logic, the NSMB native controls were 0.25% and 0.96% slower. These small differences are reported rather than rounded away; native controls alone do not establish a live gameplay regression.

## Unprofiled physical-output trials

Analog RGBS at approximately 59.64 Hz passed through the RetroTINK-4K and the existing 1080p60 capture chain. No new HDMI or DV1 qualification is claimed. Capture settings were retained. No SSH polling or sampling profiler ran during the measured input windows. All accepted runs had zero reported host/helper faults, zero OBS render/encode drops and an audio signal. Audio presence does not prove freedom from hitches or clipping.

Completed screen-pair publications are counted from the service headers over the active input window. They are not distinct visible animation FPS. Roughly 60 LCD timing tags per second do not imply 60 newly rendered pictures. Interval measurements come from the RAM timeline, flushed only after the trial. Raced timeline records are excluded when present.

| Trial | Build | Pairs | Seconds | Pairs/s | Median delivery interval ms | p95 ms |
|---|---|---:|---:|---:|---:|---:|
| C11_BAT_BASE_CLEAN | Beta4 | 351 | 21.998 | 15.956 | 62.238 | 72.487 |
| C11_BAT_BASE_REPEAT | Beta4 | 351 | 22.027 | 15.935 | 62.272 | 72.933 |
| C11_BAT_CAND_CLEAN | Candidate | 356 | 21.969 | 16.205 | 61.508 | 69.535 |
| C11_BAT_CAND_REPEAT | Candidate | 355 | 22.008 | 16.131 | 61.400 | 71.541 |
| C11_FIGHT_BASE_IDLE | Beta4 | 95 | 5.987 | 15.867 | 62.626 | 78.732 |
| C11_FIGHT_CAND_IDLE | Candidate | 95 | 5.986 | 15.870 | 64.377 | 72.704 |
| C11_NSMB_BASE_CLEAN | Beta4 | 1162 | 25.990 | 44.709 | excluded | excluded |
| C11_NSMB_CAND_CLEAN | Candidate | 1171 | 26.041 | 44.967 | 23.041 | 30.432 |

The two-run cave means were 15.946 and 16.168 picture pairs/s (+1.39%). Both baseline trials started from fresh copies of the suspend; the second candidate trial continued after the first. The same platform, HP 132 and EXP 69 were visually verified. Bat phases vary. This supports a small local gain, not a whole-game percentage.

The first baseline attack trial, C11_FIGHT_BASE_CLEAN, triggered an Axe Armor soul popup during the measurement and is excluded from performance comparisons. Replacement combat trials used six seconds with no attack input. Both stayed in the active room and survived, but enemy phases and setup experience differ. No firm live combat speed gain is claimed. The isolated identical-frame comparison above supplies the raster measurement.

NSMB used the same castle-entrance fixture and a 26-second repeated-jump sequence. The candidate's completed-publication rate changed by +0.58%. This is a short regression control, not a whole-game certification.

## Correctness and provenance

- Full ARM helper self-test passed, including the retained packed-VRAM replay checks.
- 7,488,001 depth-selection comparisons cover front/back depth rules, signed depth boundaries, equal depths, alpha rejection and lower-layer selection.
- All 4,108 synthetic full native color/depth/attribute cases matched the previous renderer as well as the independent reference.
- All 48 sequential private snapshots matched full buffers, visible rows, render state, polygon state and texture/palette hashes. Ten combat snapshots are paused/transition frames; they are not presented as active gameplay.
- All 160 serial, split-worker, band-worker and deliberately delayed-worker renders matched the reference buffers.
- Five native saved-frame controls retained identical full buffer hashes.
- 851 source inputs were checked against the public tree. The only differing private-build input is the standalone profile unit-test source, which is not linked into the helper. Temporary private source overlays were restored.
- Original user files and saves are guarded by the 54-file rig manifest. Gameplay trials use isolated copies; no game/save/media data is included in the source or beta package.

Baseline source: `e8c69187c5c737eea6d18c76eb3352d1fe66b447` (Castlevania Beta4).
Candidate helper SHA-256: `b6b4cb97d8aa618c1083a7d9d2df62a38f5061c1db1e0026440e86446da3971b`.

## Remaining work

The improvement is small relative to the 60 fps goal. The prior Beta4 CPU profile still points to rectangle scanline setup, general polygon spans and translucent blending as the larger raster costs. A useful next experiment is to precompute more proven rectangle texture setup once per polygon while preserving exact interpolation and edge behavior. Replay/geometry work also remains significant. Any subsequent change needs the same full-buffer and other-game controls.

This is a private focused beta, not a public release. Full playthroughs, other cartridge revisions, new video-mode validation and a general-beta promotion are not claimed. See [Beta4 replay measurements](CASTLEVANIA_REPLAY_PERFORMANCE_20261016.md) for the previous change.
