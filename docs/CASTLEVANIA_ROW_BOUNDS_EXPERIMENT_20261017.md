# Rejected transparent texture-row bounds — 17 October 2026

This private ARM candidate did not improve Castlevania enough to replace Beta8. No runtime source was integrated, full helper built or candidate installed.

The experiment packed the first and last nonzero-alpha texel into the existing per-row maximum-alpha word. Existing maximum-alpha readers retained the low five bits. Proven forward, unit-step, in-bounds Castlevania texture spans skipped alpha-zero prefixes and suffixes before depth testing. Cache allocation, invalidation, framebuffer ordering and final-pass bounds stayed unchanged.

## Two-core native controls

Stock 1 GHz, verified frontend parked with a recovery watchdog and restored afterward. Six samples per build/scene, 100 warm renders per sample, baseline/candidate/candidate/baseline order. Full color/depth/attribute hashes matched. Negative means less time.

| Saved scene | CPU change | Wall-time change |
| --- | ---: | ---: |
| bat-live | +0.199% | +0.138% |
| combat-live | -0.132% | -0.380% |
| nsmb-castle | +0.024% | -0.051% |
| nsmb-castle-left | +0.083% | -0.060% |
| mario-kart-heavy | +0.370% | +0.306% |

The cave was slightly slower and combat savings were below the predeclared 1% gate. These warm-render measurements exclude cold texture-upload overhead and are not gameplay FPS. The source remains archived for reference, rather than promoted on small timing noise.

## Correctness

8,192 metadata rows and 131,072 clipped span cases passed. All 5,388 existing raster cases and 512 gray cases matched Beta8's complete color/depth/attribute buffers. Of these, 5,644 also match an independent uncached reference. The remaining 256 retain known baseline compatibility behavior; no fix for those differences is claimed. Forty-eight saved sequence frames and 160 serial, split, band and delayed-worker renders matched. The unchanged blend arithmetic test was not rerun.

The first local compile used an incomplete copied-header overlay and failed with duplicate definitions. Copying the matching GPU_Soft header fixed the isolated build; no runtime code was changed for that correction. A later attempt to cancel the expensive oracle after the speed result found it had already finished, so no running job was stopped.

Private evidence: `castlevania-row-bounds-performance-20261017`. No game fixtures or captured media are included in public source.
