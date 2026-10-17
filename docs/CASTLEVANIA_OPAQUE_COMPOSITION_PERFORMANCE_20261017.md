# Opaque 3D composition experiment — 17 October 2026

This change skips final 2D color arithmetic only when the existing scalar compositor would return the top pixel unchanged. The focused Castlevania candidate is built on Castlevania Beta8. It keeps its ARM clock, FPGA, host, frame admission, game profiles and runtime environment.

## Change and correctness

The existing no-ordinary-effects path now copies a scanline immediately when no second blend targets are enabled. In its mixed path, a pair of fully opaque 3D pixels can also pass through unchanged. The mask excludes OBJ flags; partial 3D alpha, sprites, windows and normal effects retain the scalar fallback. Pixel metadata is preserved.

The full ARM service self-test passed in Docker. The new `tools/test_opaque_composition.cpp` checked 33,554,432 actual pixels in each baseline and candidate against the unchanged scalar `ColorComposite`, covering all 16,384 legal BLDCNT words in eight generated scenarios. It includes all 3D alpha values, opaque and transparent 3D, ordinary/semitransparent/bitmap sprites, effect windows and brightness. Both binaries produced the same oracle hash (`6db1144d09c2633d`). Engine-B, paired-cache and direct-output tests also passed. The 851 recorded build inputs were checked; production GPU3D code is unchanged from Beta8, so prior raster qualification is inherited, not claimed as a new run.

## Live comparison

Analog RGBS through a RetroTINK-4K and capture rig, at the stock 1 GHz ARM clock. Each scene used baseline/candidate/candidate/baseline order and fresh isolated save copies. Cave windows were 22 seconds, combat windows 6 seconds, and NSMB windows 26 seconds. Short combat windows avoid death or pickup menus; enemy phases and damage vary. All twelve captures were visually reviewed and had complete pictures, audio present, zero capture render/encode drops, zero protocol fault words, unchanged measured saves and all 54 protected files unchanged. Audio presence does not certify audio quality.

Rates below count completed source publication pairs. They do **not** measure distinct displayed animation frames and do not establish 60 fps.

| Scene | Beta8 pairs/s | Candidate pairs/s | Change |
|---|---:|---:|---:|
| Castlevania cave/bat platform | 19.3839 | 19.7825 | +2.056% |
| Castlevania Warg combat | 18.6500 | 19.0358 | +2.069% |
| New Super Mario Bros. control | 44.4010 | 44.5868 | +0.418% |

Individual frame delivery intervals retain variability. Cave mean median/p95/maximum intervals improved by 2.23%/1.27%/1.58%. Combat mean median improved by 1.32%, but its mean p95 and maximum increased by 2.11% and 6.18%. Enemy phases vary across these short samples. Higher average throughput alone does not establish uniformly smoother play or exclude a combat tail regression.

| Trial | Pairs/s | Median interval, ms | p95, ms | Max, ms |
|---|---:|---:|---:|---:|
| C29_BAT_BASE | 19.3233 | 51.818 | 59.873 | 67.424 |
| C29_BAT_CAND | 19.8098 | 50.347 | 59.180 | 66.699 |
| C29_BAT_CAND_REPEAT | 19.7551 | 50.606 | 59.823 | 66.143 |
| C29_BAT_BASE_REPEAT | 19.4445 | 51.437 | 60.656 | 67.549 |
| C29_FIGHT_BASE | 18.4615 | 53.386 | 64.356 | 76.683 |
| C29_FIGHT_CAND | 19.0328 | 52.181 | 70.006 | 81.351 |
| C29_FIGHT_CAND_REPEAT | 19.0388 | 52.522 | 62.909 | 78.169 |
| C29_FIGHT_BASE_REPEAT | 18.8386 | 52.715 | 65.809 | 73.547 |
| C29_NSMB_BASE_CLEAN | 44.3089 | 23.161 | 30.527 | 46.772 |
| C29_NSMB_CAND_CLEAN | 44.6670 | 23.004 | 30.757 | 40.414 |
| C29_NSMB_CAND_REPEAT_CLEAN | 44.5065 | Excluded | Excluded | Excluded |
| C29_NSMB_BASE_REPEAT_CLEAN | 44.4930 | Excluded | Excluded | Excluded |

Timeline snapshots containing raced records are excluded entirely from interval analysis. Their independently sampled, stable service headers still provide publication counts. No replacement or interpolated interval values are used.

## Native compositor controls

Six samples per binary and scenario, 19,200 scanlines per sample, on one stock ARM core with the normal menu process temporarily parked and then restored. Complete output hashes matched. These isolate synthetic composition cost; they are not whole-game results.

| Scenario | CPU time change |
|---|---:|
| Opaque 3D, no second targets | -66.793% |
| Opaque 3D with backdrop and second targets | -18.633% |
| Partial 3D with sprites | +2.680% |
| Window and normal-effect mixture | -1.502% |
| Engine B scenario 0 | -0.649% |
| Engine B scenario 1 | -0.853% |
| Engine B scenario 2 | -0.262% |
| Engine B scenario 3 | -0.189% |

Negative time changes are faster. The partial-3D/sprite synthetic case is **2.68% slower**. This is a measured tradeoff, not a claim of universal improvement; the live NSMB control gates acceptance. The cave mean must improve by more than 1%, and combat/NSMB must each remain above a −1% mean-change gate. These short controls are not a whole-game compatibility guarantee.

## Scope

This remains a private focused Castlevania experiment, not a public release or a promotion of the general Performance Beta6 baseline. It retains earlier RTC, controller mapping and display behavior. No new HDMI/DV1 qualification is claimed. Further cache-miss diagnostics will guide the next change; diagnostic builds are kept out of the test package.
