# Castlevania gray-overlay blending — 16 October 2026

Castlevania Beta8 is a focused ARM experiment based on Castlevania Beta7. It specializes the blend operation for the gray overlay already accepted by Beta7. The 60 fps target remains unmet. Performance Beta6 remains the general baseline.

## Change and scope

The existing Dawn of Sorrow USA revision 0 profile and rectangle proof are unchanged. The accepted polygons are untextured, translucent gray rectangles with constant depth and W, enabled alpha blending and the required linear interpolation conditions. Other shapes and cartridge profiles retain their existing paths.

The new blend computes the gray source contribution once and blends red and blue in separate 16-bit lanes. Every weighted sum is at most 63 × 32 = 2016, so multiplication and addition cannot carry between the lanes. Green is calculated independently. The transparent-destination bypass and maximum-alpha rule remain exact.

The gray row routine reuses destination attributes already loaded for antialiasing. It preserves repeated translucent polygon-ID rejection, fog clearing, optional depth writes and the lower-layer decision made from the pre-blend attributes. Depth selection, gray interpolation, clipping, slope advancement and final-pass bounds are unchanged.

The initial candidate passed all rendering checks but increased native Mario Kart rendering cost by 1.27%. A longer reversed-order check measured +1.07%, confirming the rejection. A section-attribute experiment produced an identical binary and was not retested. The final candidate removes the gray routine from the explicitly hot function group; its speed results below determine acceptance. This code-placement change does not alter the blend arithmetic.

The generic polygon routine, generic blend and translucent plotting functions, and polygon setup are identical as source to Beta7. The FPGA, host, stock 1 GHz clock, frame admission, controller mapping, packed VRAM replay and offline RTC fallback are retained.

## Fresh Beta7 profiles

Separate 499 Hz CPU-clock profiles covered 22 active cave seconds and six combat seconds through the physical RetroTINK capture chain. Translucent plotting accounted for 5.63% and 5.85% of statistical leaf samples; the gray row routine accounted for 2.91% and 2.79%. These proportions are neither inclusive function costs nor frame rates. Packet acquisition, geometry and textured rectangle rendering remain substantial targets for later work. Profiled runs are excluded from performance acceptance.

## Native fixed-input measurements

The physical Cortex-A9 ran at 1 GHz with one rendering thread pinned to CPU0 and the stopped, verified Main menu on CPU1. Each scene used baseline/candidate/candidate/baseline order, three samples per leg, 16 warmup renders and 100 measured renders per sample. Complete color/depth/attribute hashes matched in all five scenes. Clock settings and menu affinity were restored. These are rendering CPU costs, not whole-game FPS.

| Saved scene | Beta7 ms/render | Beta8 ms/render | Change |
|---|---:|---:|---:|
| bat-live | 25.589 | 23.789 | -7.03% |
| combat-live | 24.287 | 22.667 | -6.67% |
| nsmb-castle | 11.874 | 11.846 | -0.23% |
| nsmb-castle-left | 11.620 | 11.633 | +0.11% |
| mario-kart-heavy | 35.563 | 35.444 | -0.33% |

NSMB and Mario Kart do not enable this game-specific path. Their results are regression controls; small fluctuations around baseline are not claimed improvements.

## Unprofiled physical-output measurements

Analog RGBS at approximately 59.64 Hz passed through the RetroTINK-4K and the retained 1080p60 capture chain. No new HDMI or DV1 qualification is claimed. No sampling profiler or SSH polling ran during measured gameplay windows. Accepted recordings had zero reported host/helper faults, zero OBS rendering/encoding drops and an audio signal. Audio presence does not certify the absence of hitches or clipping.

The service headers count completed screen-pair publications, not distinct visible animation FPS. Approximately 60 LCD tags per second does not imply 60 newly rendered pictures. Any raced RAM timeline records are excluded from interval measurements; stable, independently sampled service headers still provide publication counts.

| Trial | Build | Pairs | Seconds | Pairs/s | Median interval ms | p95 ms |
|---|---|---:|---:|---:|---:|---:|
| C14_BAT_BASE_CLEAN | Beta7 | 415 | 21.974 | 18.886 | 53.058 | 61.542 |
| C14_BAT_BASE_REPEAT | Beta7 | 417 | 21.991 | 18.962 | 53.141 | 61.672 |
| C14_BAT_CAND_CLEAN | Beta8 | 425 | 22.001 | 19.317 | 51.728 | 60.651 |
| C14_BAT_CAND_REPEAT | Beta8 | 424 | 21.936 | 19.329 | 51.578 | 61.363 |
| C14_FIGHT_BASE_IDLE | Beta7 | 108 | 6.013 | 17.961 | 55.844 | 64.757 |
| C14_FIGHT_BASE_REPEAT | Beta7 | 108 | 5.975 | 18.076 | 54.481 | 64.923 |
| C14_FIGHT_CAND_IDLE | Beta8 | 110 | 5.993 | 18.354 | 54.833 | 66.076 |
| C14_FIGHT_CAND_REPEAT | Beta8 | 113 | 6.004 | 18.822 | 52.404 | 71.958 |
| C14_NSMB_BASE_CLEAN | Beta7 | 1145 | 26.029 | 43.990 | 23.307 | 30.794 |
| C14_NSMB_CAND_CLEAN | Beta8 | 1169 | 26.010 | 44.944 | 23.167 | 30.405 |

| Scene | Baseline mean pairs/s | Candidate mean pairs/s | Change |
|---|---:|---:|---:|
| BAT | 18.924 | 19.323 | +2.11% |
| FIGHT | 18.018 | 18.588 | +3.16% |
| NSMB | 43.990 | 44.944 | +2.17% |

The cave uses 22 seconds on the bat platform without input. Combat uses six seconds with active enemies and no attacks to avoid pickup menus. Each Castlevania build has two fresh isolated suspend trials per room, in baseline/candidate/candidate/baseline order. Setup damage, enemy phases, knockback, camera position and projectile timing vary. The native saved-frame comparisons provide stronger causal evidence than these short combat observations. NSMB uses a 26-second repeated-jump sequence at the castle entrance.

Combat publication throughput increased, but its p95 intervals did not improve consistently. These short trials do not establish an improvement in worst-case frame pacing.

## Correctness and provenance

- The full ARM helper self-test passed.
- 12,713,984 independent blend checks passed. They exhaust every red/blue lane pair, source gray and source alpha, check every destination alpha, and test unused color bits against the original weighted-sum formula.
- All 512 gray-rectangle cases matched Beta7 and the independent uncached reference in complete color/depth/attribute buffers and visible output. The unchanged proof accepted 224 shapes and rejected 288 fallback cases.
- All 5,388 prior raster cases matched Beta7 full buffers. Of these, 5,132 also matched the independent uncached renderer. The remaining 256 narrow cases retain existing baseline behavior, including 40 full-buffer and two visible differences from the uncached reference. No fix for those legacy differences is claimed.
- Combined: 5,900 cross-build full-buffer cases, including 5,644 independent uncached-reference cases.
- All 48 sequential snapshots retained exact buffers, visible rows, polygons, render state and texture/palette hashes. Ten combat snapshots are paused or transition frames.
- All 160 serial, split-worker, band-worker and delayed-worker renders retained exact buffers.
- Both saved room controls exercise the specialized gray rectangle.
- Source correspondence checks cover 851 build inputs. The only nonmatching public input is an unlinked standalone profile test. Temporary private-build source overlays were restored.
- Trials use isolated saves and protect 54 original files. No ROMs, saves, settings or captured game media are included in the source or ZIP.

Baseline source: `3f9279b8e0f9a54fee54215624a8e83d2dd8c5f5` (Castlevania Beta7).
Candidate helper SHA-256: `d930d61490cd7e2a4ee69d7fca9d1d649d77aa68c14ee4cd3633c1daca9c9e07`.

## Remaining work

The 60 fps goal remains unmet. Reprofile the accepted build before selecting another optimization in textured rectangles, geometry or replay. Longer survivable combat trials with more closely matched enemy and camera states would strengthen gameplay conclusions.

This is a private focused beta, with no full-playthrough qualification or promotion to the general beta. See [Beta7 measurements](CASTLEVANIA_GRAY_GRADIENT_PERFORMANCE_20261016.md) for the previous change.
