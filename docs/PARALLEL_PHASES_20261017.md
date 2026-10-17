# Parallel renderer phases — 17 October 2026

Decision: **NOT QUALIFIED**. The prototype passed correctness checks, but no
option meets the predeclared native performance gates. It remains private and
disabled; frozen Beta12 and its package are unchanged. No live phase candidate
was installed and no game-FPS improvement is claimed.

## Prototype and checks

The [CPU-time profile](RENDERER_CPU_PROFILE_20261017.md) justified testing two
independent options: clear the buffers on CPU1 while CPU0 prepares polygons,
and split final processing between the two renderer workers after raster joins.
Every posted job must finish before cancellation, publication or the next frame.
Edge marking leaves two boundary rows untouched until both interiors finish,
then processes those rows serially to avoid neighboring attribute-word races.
Legacy scanline consumers retain their original serial phases. Pixel arithmetic,
FPGA, clocks, raster balancing and the frozen game profile are unchanged.

The separate helper changes two of 851 inventoried source inputs. Full ARM
service tests pass with both options off, each option alone and both together.
A dedicated oracle passes 2,640 complete color/depth/attribute comparisons,
including hidden AA layers and borders, 864 profile transitions, 192 queued
and 144 X-partition cases. It also passes six held-phase cancellation/recovery
cases, three secondary-final-first cases and three held-worker shutdown cases.
Reset/settings tests honor the existing drain-before-mutation contract; these
are not proof of arbitrary in-flight global reset safety. A further 320 complete
buffer comparisons pass using five captured game scenes.

## Native comparison

At stock 1 GHz, four balanced samples per arm and scene compare the exact
frozen renderer (BASE), the new binary with both options off (OFF), clear only
(CLEAR), final only (FINAL), and both (BOTH). Each sample renders 100 frames
after 16 warmups, with profiling off. The MiSTer menu is paused, the primary
runs on CPU0 and the secondary on CPU1; no build or live game competes.
All output-buffer hashes match. CPU time is process CPU time across workers; wall
time is elapsed renderer time. These saved-scene timings omit guest execution,
packet intake, live replay and FPGA DDR contention.

Cost changes below compare each option with OFF in the **same binary**.
Negative values mean less time, not an animation-FPS percentage.

| Scene | CLEAR wall / CPU | FINAL wall / CPU | BOTH wall / CPU |
| --- | ---: | ---: | ---: |
| Castlevania cave | -1.32% / +1.70% | -1.89% / -0.11% | -2.49% / +2.29% |
| Castlevania combat | -0.99% / +2.46% | +0.32% / +0.94% | -1.39% / +3.12% |
| NSMB castle | -1.85% / +3.88% | -4.88% / +0.16% | -6.08% / +3.96% |
| NSMB castle left | -1.46% / +4.44% | -4.73% / +0.30% | -7.18% / +4.02% |
| Mario Kart heavy | -0.61% / +1.75% | -1.03% / +0.62% | -2.36% / +1.67% |

The native gate required at least 1% less wall time in **both** Castlevania
rooms, control wall time and all CPU time within 1%, against both OFF and BASE.
OFF also had to agree with the observed frozen-baseline range. The gates were
set before measurements and have not been relaxed:

- CLEAR exceeds the CPU-cost limit in every scene and narrowly misses the
  combat wall-time threshold versus OFF.
- FINAL meets the CPU limits but combat wall time is 0.32% higher than OFF;
  its roughly 4.7–4.9% lower NSMB renderer wall time does not qualify the
  Castlevania optimization or demonstrate faster live NSMB gameplay.
- BOTH lowers wall time but exceeds the CPU-cost limit in every scene.
- OFF is outside the BASE CPU/wall ranges in both Castlevania scenes, and
  outside the BASE wall range in NSMB castle left. The formal native decision
  for every arm is therefore **INCONCLUSIVE_BASELINE_SHIFT**, in addition to
  the failed numerical gates above. Binary layout is a possible explanation,
  not a measured cause.

## All samples and restoration

Each cell lists the four wall / CPU measurements in milliseconds per render,
in occurrence order. All 100 measurements are retained; none was excluded.
Four samples are descriptive and do not establish a confidence interval.

| Scene | Arm | Wall ms | CPU ms |
| --- | --- | --- | --- |
| Castlevania cave | BASE | 13.621, 13.895, 13.975, 13.951 | 23.816, 24.278, 24.205, 24.179 |
| Castlevania cave | OFF | 13.524, 13.497, 13.653, 13.552 | 23.502, 23.696, 23.980, 23.782 |
| Castlevania cave | CLEAR | 13.184, 13.164, 13.507, 13.652 | 23.918, 23.906, 24.402, 24.349 |
| Castlevania cave | FINAL | 13.207, 13.131, 13.456, 13.407 | 23.594, 23.516, 23.912, 23.834 |
| Castlevania cave | BOTH | 13.088, 13.077, 13.382, 13.328 | 24.120, 24.058, 24.449, 24.505 |
| Castlevania combat | BASE | 13.330, 13.175, 13.249, 13.044 | 23.000, 22.936, 23.038, 22.921 |
| Castlevania combat | OFF | 12.707, 12.748, 12.803, 12.819 | 22.427, 22.522, 22.433, 22.454 |
| Castlevania combat | CLEAR | 12.652, 12.609, 12.624, 12.682 | 23.069, 23.000, 22.992, 22.987 |
| Castlevania combat | FINAL | 12.938, 12.941, 12.664, 12.695 | 22.809, 22.713, 22.600, 22.563 |
| Castlevania combat | BOTH | 12.627, 12.636, 12.560, 12.544 | 23.216, 23.196, 23.141, 23.088 |
| NSMB castle | BASE | 8.383, 8.605, 8.471, 8.428 | 12.197, 12.360, 12.259, 12.215 |
| NSMB castle | OFF | 8.481, 8.318, 8.366, 8.398 | 12.317, 12.151, 12.226, 12.225 |
| NSMB castle | CLEAR | 8.243, 8.239, 8.224, 8.235 | 12.731, 12.694, 12.695, 12.697 |
| NSMB castle | FINAL | 7.991, 8.006, 7.941, 7.986 | 12.338, 12.228, 12.219, 12.212 |
| NSMB castle | BOTH | 7.797, 7.953, 7.827, 7.945 | 12.662, 12.775, 12.700, 12.720 |
| NSMB castle left | BASE | 8.361, 8.333, 8.355, 8.356 | 12.053, 12.002, 12.025, 12.032 |
| NSMB castle left | OFF | 8.363, 8.239, 8.244, 8.416 | 12.089, 11.920, 11.950, 12.099 |
| NSMB castle left | CLEAR | 8.259, 8.108, 8.237, 8.171 | 12.594, 12.429, 12.608, 12.561 |
| NSMB castle left | FINAL | 7.858, 7.908, 7.898, 8.026 | 11.962, 12.033, 12.065, 12.141 |
| NSMB castle left | BOTH | 7.719, 7.689, 7.709, 7.758 | 12.497, 12.410, 12.521, 12.561 |
| Mario Kart heavy | BASE | 22.404, 22.359, 22.288, 22.021 | 37.602, 37.575, 37.387, 36.887 |
| Mario Kart heavy | OFF | 22.421, 22.624, 22.371, 21.998 | 37.422, 37.717, 37.451, 36.862 |
| Mario Kart heavy | CLEAR | 22.290, 22.324, 22.397, 21.855 | 38.106, 38.281, 38.163, 37.520 |
| Mario Kart heavy | FINAL | 22.211, 22.129, 22.005, 22.143 | 37.740, 37.566, 37.533, 37.535 |
| Mario Kart heavy | BOTH | 21.989, 21.861, 21.823, 21.628 | 38.113, 37.970, 38.056, 37.805 |

Menu process/affinity, clock controls and all 54 protected files were restored.
The original NSMB runtime and save were reloaded, OBS settings remained
unchanged, and a fresh game-selection snapshot was visually inspected.

Private helper SHA-256:
`46fcb056c518bc7e41a46ce918a9c479848dd738a9a10ffe9da859c90db94c35`.
The frozen renderer control was the previously verified native harness linked
to the Beta12 renderer; it was not freshly rebuilt for this batch. Both harness
identities, source inventories, deterministic test harnesses, full-buffer
results, all native samples and restoration receipts are retained privately in
`parallel-phases-c58-20261017`. No binary or game data is committed.
