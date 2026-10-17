# Background-write and sprite-cache follow-ups — 17 October 2026

Neither prototype replaces Castlevania Beta9. Inline comparisons before redundant background writes improved the cave mean by less than 1%. Adding reuse for lines with no prepared sprites produced a small cave gain, but the combat mean was lower. The additional cache benefit is not established by these short samples.

## Changes and correctness

The first prototype replaces the rejected generic memory-comparison calls with fixed-size inline comparisons for 2-, 4- and 8-byte writes. It compares each mapped physical Engine-B background bank independently, preserves pre-existing dirty state and only suppresses a write/revision update when the bytes already match. The existing exact Castlevania game profile enables the path. Changed writes and other game profiles retain their required effects.

The second prototype adds a conservative proof after the normal sprite-preparation phase: an enabled engine with zero prepared sprites has cleared both OBJ pixel and OBJ-window buffers. Such lines can ignore irrelevant OAM revision changes in the paired Engine-B composition cache. All other keys, preparation, coherence and mosaic work remain. The general cache and other game profiles retain their behavior.

Both full ARM service self-tests passed in Docker. The physical-write oracle passed 3,840 cases, including 2,827 equal-write and 48 mixed-bank cases, checking complete VRAM, dirty state, revisions and flat-memory coherence. Existing Engine-B, paired-cache and direct-output tests passed. The sprite-cache oracle compared 9,437,184 actual pixels in each of normal and alternating direct-output modes against uncached rendering. It exercised changing OAM, affine sprites, windows, mosaic, disabled engines, palette/VRAM changes and runtime flag transitions. All 851 build inputs were verified and temporary source overlays restored. No GPU3D arithmetic changed; previous 3D qualification is inherited, not rerun.

## Live results

Stock 1 GHz ARM clock, analog RGBS through a RetroTINK-4K and the capture rig. A six-run Beta9/inline/combined/combined/inline/Beta9 sequence brackets both cave candidates with the same two baseline samples. Combat and NSMB use separate baseline/candidate/candidate/baseline sequences for the combined candidate. Saves are fresh isolated copies. Cave windows last 22 seconds, combat six seconds and NSMB 26 seconds. Enemy phases vary, especially in the short combat samples.

Rates count completed source publication pairs, not distinct displayed animation frames. They do not establish 60 fps.

| Scene / candidate | Beta9 pairs/s | Candidate pairs/s | Change |
|---|---:|---:|---:|
| Cave, inline writes | 19.6929 | 19.8657 | +0.878% |
| Cave, combined | 19.6929 | 19.9105 | +1.105% |
| Combat, combined | 19.0683 | 18.9155 | -0.801% |
| NSMB, combined | 44.6754 | 44.6351 | -0.090% |

The combined candidate adds only 0.225% over the inline-write candidate in the cave comparison. This small difference does not establish a separate cache benefit. The nominal gates require more than 1% cave gain and no worse than −1% combat/NSMB mean changes. Passing those gates would make a candidate eligible for further consideration; it does not make it a clear upgrade when combat is lower. Beta9 remains selected.

All fourteen measured recordings were visually reviewed: complete pictures, animation and audio present, zero capture render/encode drops, zero protocol fault words, unchanged measured saves and all 54 protected files unchanged. Audio presence does not certify audio fidelity. An initial NSMB setup attempt stopped before measurement because the private harness required an optional touch configuration file. The verified host defaults to Normal when that file is absent; the harness now recognizes that default only for the verified host hash. No user settings were written, and the controls restarted with fresh saves.

| Combined-candidate comparison trial | Pairs/s | Median interval, ms | p95, ms | Max, ms |
|---|---:|---:|---:|---:|
| C36_BAT_BASE | 19.6812 | 50.634 | 60.424 | 67.672 |
| C37_BAT_CAND | 19.9309 | 50.069 | 59.484 | 65.543 |
| C37_BAT_CAND_REPEAT | 19.8900 | 50.074 | 59.058 | 66.241 |
| C36_BAT_BASE_REPEAT | 19.7045 | 50.538 | 58.854 | 67.149 |
| C37_FIGHT_BASE | 19.2182 | 52.526 | 65.963 | 68.361 |
| C37_FIGHT_CAND | 18.4989 | 53.299 | 65.681 | 77.185 |
| C37_FIGHT_CAND_REPEAT | 19.3321 | 51.480 | 66.723 | 74.155 |
| C37_FIGHT_BASE_REPEAT | 18.9185 | 52.405 | 67.270 | 74.696 |
| C37_NSMB_BASE_RETRY_CLEAN | 44.6758 | 23.049 | 30.009 | 38.938 |
| C37_NSMB_CAND_RETRY_CLEAN | 44.2909 | 23.239 | 30.413 | 41.340 |
| C37_NSMB_CAND_REPEAT_RETRY_CLEAN | 44.9794 | 23.011 | 30.516 | 40.619 |
| C37_NSMB_BASE_REPEAT_RETRY_CLEAN | 44.6750 | 23.231 | 30.730 | 39.706 |

Raced timeline snapshots, if present, are excluded from interval statistics; independent stable header counts remain the throughput source. A higher mean alone does not establish uniformly smoother play.

## Native write-path measurements

Six samples per binary and scenario on one stock ARM core, with the verified Main menu temporarily parked and then restored. Complete physical/flat-memory hashes matched. These timings isolate synthetic replay and coherence cost; they do not measure whole-game performance or the additional sprite-cache change.

| Synthetic write workload | CPU time change |
|---|---:|
| Unchanged BG pairs | -9.918% |
| Changing BG pairs | +10.965% |
| Unchanged BG words | -14.819% |
| Changing BG words | -2.272% |
| Mixed regions pairs | -19.566% |
| Other profile BG pairs | -1.176% |
| Unchanged BG pairs at a four-byte offset | -11.348% |
| Other profile BG words | +0.396% |

Negative time changes are faster. Changing background pairs are 10.96% slower, an explicit cost of testing for unchanged data. This reinforces why synthetic gains alone are insufficient for promotion.

## Next experiment

Test exact prepared OBJ pixel/window/count identity for stable nonempty map-screen rows. Preserve the cheap zero-sprite case and all non-OAM dependencies. The added cache occupies about 247 KB, so memory traffic and live regression controls must justify it. This is a hypothesis, not an accepted optimization.

Both prototypes remain private and unintegrated. The original rig, save, 54 protected files, stock clock and OBS settings were restored after these controls. No public release or general-beta promotion occurred.
