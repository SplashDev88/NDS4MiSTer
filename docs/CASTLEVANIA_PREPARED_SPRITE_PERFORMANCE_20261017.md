# Exact prepared-sprite reuse — 17 October 2026

This focused Castlevania candidate avoids unchanged Engine-B background stores and reuses map-screen composition when the prepared sprite pixels, OBJ-window bytes and sprite count match exactly. It builds on Castlevania Beta9. The existing exact game profile enables the changes; other profiles retain their paths.

## Correctness and scope

Each physical background bank is compared separately before suppressing a write and its revision update. Changed banks retain their writes, dirty state and invalidations. Sprite preparation still runs at its original phase. The composition cache preserves all palette, VRAM, mapping and register dependencies; only OAM revision identity is replaced by comparison of the actual prepared sprite result.

Raw sprite inputs are compared and snapshotted before X mosaic can change them. A snapshot becomes valid only when its corresponding output is committed. The enabled zero-count case retains a cheap proof because preparation cleared both OBJ buffers. The new path excludes currently disabled Engine B and display capture. Coherence, window calculation and X-mosaic state transitions still run on cache hits.

The cache allocates about 247 KB only for the enabled profile. The FPGA, standalone host, ARM clock, frame admission and runtime environment remain those of Beta9. No 3D arithmetic changed. RTC, controller mapping and display support are inherited; this is not new HDMI or DV1 qualification.

The full ARM service self-test passed in Docker. The physical-write oracle passed 3,840 cases, including equal and mixed-bank writes, with complete VRAM, dirty-state, revision and flat-coherence checks. Existing Engine-B, paired-cache and direct-output tests passed. The new prepared-sprite oracle compares 16,515,072 actual pixels against uncached rendering in each of normal, parallel, direct-output and parallel/direct-output modes: 66,060,288 comparisons in total.

Each mode records 24,383 hits and 7,873 misses, including required hits on empty, static nonempty, transparent, OBJ-window and mosaic lines. Tests also cover changing OAM and affine matrices, palette/VRAM changes, engine-disable and capture transitions, discarded sprite preparations, runtime flag changes, output guards and immutable completed publication slots. Post-composition OBJ hashes match. The public regression test sources were separately compiled and run against the qualified ARM core. All 851 build inputs were checked, and temporary source overlays were restored. Earlier 3D qualification is inherited because those runtime inputs are unchanged; it is not claimed as a new run.

## Live scene results

Analog RGBS through a RetroTINK-4K and capture rig at the stock 1 GHz ARM clock. Each scene uses baseline/candidate/candidate/baseline order with fresh isolated save copies. Cave windows last 22 seconds, combat six seconds and NSMB 26 seconds. The short combat windows avoid death and pickup menus; enemy phases vary.

Rates count completed source publication pairs, not distinct displayed animation frames. They do not establish 60 fps.

| Scene | Beta9 pairs/s | Candidate pairs/s | Change |
|---|---:|---:|---:|
| Cave/bat platform | 19.6668 | 21.6370 | +10.018% |
| Upper-right Warg combat | 18.6328 | 21.4896 | +15.332% |
| New Super Mario Bros. control | 44.7629 | 44.5209 | -0.541% |

All twelve measured recordings were visually reviewed and showed complete pictures and animation, audio present, zero protocol fault words and zero capture render/encode drops. Measured saves and all 54 protected files were unchanged. Audio presence does not certify audio fidelity.

| Trial | Pairs/s | Median interval, ms | p95, ms | Max, ms |
|---|---:|---:|---:|---:|
| C38_BAT_BASE | 19.6006 | 50.594 | 60.730 | 74.111 |
| C38_BAT_CAND | 21.5787 | 45.559 | 55.099 | 61.744 |
| C38_BAT_CAND_REPEAT | 21.6953 | 44.898 | 54.887 | 75.046 |
| C38_BAT_BASE_REPEAT | 19.7331 | 50.504 | 59.218 | 67.981 |
| C38_FIGHT_BASE | 18.3467 | 53.760 | 64.397 | 70.686 |
| C38_FIGHT_CAND | 21.8009 | 46.053 | 59.479 | 64.688 |
| C38_FIGHT_CAND_REPEAT | 21.1782 | 47.535 | 56.790 | 62.654 |
| C38_FIGHT_BASE_REPEAT | 18.9189 | 53.242 | 61.760 | 64.706 |
| C38_NSMB_BASE_CLEAN | 44.4734 | 23.343 | 30.545 | 45.712 |
| C38_NSMB_CAND_CLEAN | 44.4258 | 23.087 | 30.793 | 40.232 |
| C38_NSMB_CAND_REPEAT_CLEAN | 44.6160 | 23.165 | 31.101 | 42.419 |
| C38_NSMB_BASE_REPEAT_CLEAN | 45.0523 | Excluded | Excluded | Excluded |

Raced timeline snapshots are excluded from interval statistics; independently sampled stable header counts remain usable for throughput. Higher average throughput alone does not prove uniformly smoother animation. These short controls are not a whole-game compatibility guarantee.

The analog capture also provides a secondary visible-change check. With a fixed 24-pixel minimum and RGB threshold 20, the cave combat-region average rises from 18.818 to 20.136 changed images/s and the combat average from 18.750 to 21.083. Those cases have zero paused false changes. At threshold 32, cave results are essentially flat while combat still improves; low thresholds admit analog noise. The p95 visible gap does not consistently improve. These threshold-sensitive counts support a combat cadence improvement but are not distinct animation FPS.

## Native cost and tradeoffs

Six samples per binary and workload on one stock ARM core, with the verified Main menu temporarily parked and then restored. Complete output hashes matched. These synthetic paired-rendering measurements compare the unpromoted C37 count-zero prototype with C38 exact identity; they isolate this cache extension and are not Beta9 whole-game gains.

| Workload | CPU time change |
|---|---:|
| Dense static sprites | -34.685% |
| Dense changing sprites | +6.994% |
| Changing OBJ VRAM | +5.436% |
| No sprites | +2.275% |
| Static OBJ windows | -24.566% |
| One changing sprite among static sprites | -30.796% |
| Profile disabled | +0.344% |
| Static mosaic sprites | -30.314% |

Negative values mean less time. Constantly changing sprites and sprite VRAM cost more because comparisons and snapshots cannot yield reuse. Empty-line overhead also increased slightly despite preserving the zero-count shortcut. The separate inline background-write test found a 10.96% cost for constantly changing background pairs; that implementation is unchanged here. These are explicit tradeoffs, not a universal performance claim. The live game comparisons and regression controls determine acceptance.

This remains a private focused test beta. Performance Beta6 stays the general baseline, and no public GitHub Release is created.
