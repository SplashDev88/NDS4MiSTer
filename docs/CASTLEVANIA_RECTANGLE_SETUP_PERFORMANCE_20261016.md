# Castlevania rectangle setup — 16 October 2026

Castlevania Beta6 is a focused ARM experiment built on Castlevania Beta5. The fixed cave frame uses 12.03% less rendering CPU time and the fixed combat frame uses 10.53% less. Live scene results are listed separately below. The 60 fps target is not met. Performance Beta6 remains the general baseline.

## Change and scope

Eligible neutral textured rectangles prepare their horizontal S/T steps once per polygon. The proof requires identical signed vertical deltas on both sides and integral horizontal steps. The existing vertical interpolator still supplies exact rounding, including fractional and descending texture coordinates. The row renderer reuses the existing cached interior implementation and preserves full-coverage boundaries, alpha rejection, depth, blending and both antialiasing layers.

The shortcut remains behind the exact Dawn of Sorrow USA revision 0 cartridge profile. Nonintegral, unequal-slope and one-pixel-wide rectangles retain the previous implementation. The one-pixel exception preserves the old overlapping-edge ordering, including hidden layer contents. An initial prototype failed that full-buffer combat check despite matching visible rows; it was rejected and corrected before acceptance.

The FPGA, host, stock 1 GHz clock, frame admission, controller mapping, packed VRAM replay and offline RTC fallback are retained. No new FPGA build or timing closure is claimed.

## Fresh Beta5 profiling

Separate 499 Hz CPU-clock sampling runs covered the cave platform and the crowded combat room through the physical RetroTINK chain. Front-facing rectangle rendering accounted for 9.96% and 12.81% of statistical leaf samples, respectively. General polygon rendering accounted for 10.13% and 8.90%; translucent plotting for 4.46% and 4.57%. These are sampled CPU proportions, not inclusive time or frame rates. Profiles are diagnostic only and are excluded from performance acceptance.

An incomplete cave trace exhausted temporary storage during trace expansion; it was archived and rerun using SD storage. An incomplete short combat profile exceeded its profiler wait and was repeated with a sufficient bounded wait. Neither incomplete run contributes to the reported profile or speed results.

## Native fixed-input controls

Physical Cortex-A9 at 1 GHz; one renderer thread pinned to one core with a stopped, hash-verified menu on the other. Six samples per binary per scene, in baseline/candidate/candidate/baseline order. Each sample uses 16 warmup renders and 100 measured renders. All full native color, depth and attribute buffer hashes matched. Clock settings and menu affinity were restored. These are rendering CPU costs, not whole-game FPS.

| Saved frame | Beta5 ms/render | Candidate ms/render | Change |
|---|---:|---:|---:|
| bat-live | 35.454 | 31.187 | -12.03% |
| combat-live | 33.137 | 29.649 | -10.53% |
| nsmb-castle | 11.933 | 11.888 | -0.38% |
| nsmb-castle-left | 11.733 | 11.700 | -0.29% |
| mario-kart-heavy | 35.770 | 35.514 | -0.72% |

Both NSMB controls and Mario Kart were within 1% of Beta5 in this run. Their cartridge profiles do not enable the new specialization. Small differences should not be interpreted as an optimization of those games.

## Unprofiled physical-output controls

Analog RGBS at approximately 59.64 Hz passed through the RetroTINK-4K and the retained 1080p60 capture chain. No new HDMI or DV1 qualification is claimed. No SSH polling or sampling profiler ran during measured input windows. All accepted recordings had zero reported host/helper faults, zero OBS render/encode drops and an audio signal. Audio presence does not certify the absence of hitches or clipping.

The service headers count completed screen-pair publications over each active input window. These are not distinct visible animation FPS; approximately 60 LCD tags per second does not mean 60 newly rendered pictures. Delivery intervals come from the RAM timeline, flushed after measurement. Raced timeline records are excluded when present.

| Trial | Build | Pairs | Seconds | Pairs/s | Median interval ms | p95 ms |
|---|---|---:|---:|---:|---:|---:|
| C12_BAT_BASE_CLEAN | Beta5 | 357 | 22.016 | 16.216 | 61.737 | 70.160 |
| C12_BAT_BASE_REPEAT | Beta5 | 352 | 22.015 | 15.989 | 62.085 | 71.813 |
| C12_BAT_CAND_CLEAN | Candidate | 373 | 22.107 | 16.872 | 58.411 | 68.088 |
| C12_BAT_CAND_REPEAT | Candidate | 376 | 22.025 | 17.072 | 58.389 | 67.975 |
| C12_FIGHT_BASE_IDLE | Beta5 | 96 | 6.007 | 15.980 | 62.240 | 76.367 |
| C12_FIGHT_BASE_REPEAT | Beta5 | 95 | 6.046 | 15.713 | 62.524 | 74.939 |
| C12_FIGHT_CAND_IDLE | Candidate | 97 | 5.994 | 16.183 | 61.323 | 71.724 |
| C12_FIGHT_CAND_REPEAT | Candidate | 98 | 6.004 | 16.323 | 59.767 | 80.358 |
| C12_NSMB_BASE_CLEAN | Beta5 | 1157 | 25.993 | 44.511 | 23.137 | 30.814 |
| C12_NSMB_CAND_CLEAN | Candidate | 1161 | 25.995 | 44.663 | 23.140 | 30.855 |

| Scene | Baseline mean pairs/s | Candidate mean pairs/s | Change |
|---|---:|---:|---:|
| BAT | 16.102 | 16.972 | +5.40% |
| FIGHT | 15.846 | 16.253 | +2.57% |
| NSMB | 44.511 | 44.663 | +0.34% |

Cave trials use the bat platform and 22 seconds without controller input. Combat trials use six seconds with active enemies and no attack input, avoiding soul pickup menus. Both rooms have two trials per build, each starting from a fresh isolated suspend copy. Enemy phases and setup damage vary; these are local observations, not a whole-game speed guarantee or a long combat soak. NSMB uses the same castle entrance and a 26-second repeated-jump sequence.

The cave gain repeated in both runs. The combat mean changed only modestly, and the second candidate trial began at EXP 71 versus EXP 69 for the baseline after setup. Damage, enemies and projectile timing were not identical; the candidate combat p95 also varied across repeats. The combat publication-rate change is inconclusive as a repeatable gameplay improvement, despite the clear fixed-input rendering CPU reduction.

## Correctness and provenance

- Full ARM helper self-test passed.
- 11,636,590 independent rectangle-step arithmetic checks passed, including signed endpoints, fractional vertical steps, descending interpolation and rejected setup cases.
- 7,488,001 front/back depth-selection checks passed.
- 5,132 synthetic full native color/depth/attribute cases matched Beta5 and the independent uncached reference. Another 256 independently initialized one-pixel cases matched Beta5 full buffers; these are compatibility checks, not independent accuracy passes. 40 retained legacy cases differ from the uncached reference in full buffers (2 also differ visibly).
- The added one-pixel fixtures exposed existing differences between cached and uncached rendering in Beta5. The candidate preserves those exact legacy results, including hidden layers. Fixtures use fresh machines, and the baseline comparison includes all three buffers. The existing difference is not presented as fixed or as an independent accuracy pass.
- All 48 sequential private snapshots matched complete buffers, visible rows, render state, polygons and texture/palette hashes. Ten combat snapshots are paused/transition frames.
- All 160 serial, split-worker, band-worker and delayed-worker renders matched reference buffers.
- The saved combat regression frame exercises 471 prepared rectangles, 7,706 polygon rows and nine one-pixel fallbacks, with exact full buffers.
- All five native saved-frame controls retained exact full buffer hashes.
- 851 source inputs were checked against the public tree. The only differing private-build source is the standalone profile unit test, which is not linked into the helper. Private build overlays were restored.
- Original files and saves are protected by the 54-file rig manifest. All trials use isolated save copies. No ROM, save or captured game media is included in the source or package.

Baseline source: `e8041220350f6c9073166855cb559163d5b4a028` (Castlevania Beta5).
Candidate helper SHA-256: `6c75386c37c6602afc4c47ad6094971a61a1da6666b45af082f40a7b24acbeb3`.

## Remaining work

General polygon spans, translucent blending, replay and geometry remain substantial costs. The improvement does not close the gap to 60 fps. Future changes need the same full-buffer and other-game controls, with longer combat trials where a repeatable survivable workload is available.

This is a private focused beta, not a public release. Full playthroughs, other cartridge revisions, additional video modes and promotion to the general beta are not claimed. See [Beta5 measurements](CASTLEVANIA_BACKSPAN_PERFORMANCE_20261016.md) for the previous change.
