# Vertical rectangle edge stepping: no promotion

The private candidate reduces isolated Castlevania renderer time, but its live cave comparison changes completed picture delivery by only -0.084%. It does not meet the 1% live gain gate and is excluded from Beta10. No replacement beta was packaged.

The existing exact Dawn of Sorrow cartridge profile already proves vertical edges, equal suitably aligned W, linear attributes and constant depth for its rectangle paths. The candidate advances only the row and linear interpolation position there. It avoids recomputing unchanged X/clamps and an unused W-buffer perspective factor. The factor is invalidated so a later generic interpolation request recomputes it normally. Generic polygons, depth and blend rules, frame admission, FPGA, host and 1 GHz clock are retained.

## Correctness and build

The edge oracle passes 1,262,688 attribute/state checks against independent integer interpolation and the original edge stepping, plus 11,328 generic-factor resynchronization comparisons. It covers both sides, signed attribute endpoints, clipped starts, heights through 512, equal W endpoints and W-buffering enabled/disabled. Host and ARM results agree.

All 512 gray raster and 5,388 broader full color/depth/attribute cases match the unchanged 3D baseline. Of those, 5,644 also match the independent uncached reference; 256 retain known one-pixel baseline compatibility differences. Forty-eight sequential snapshots and 160 serial, split, banded and delayed-worker buffer comparisons match. Ten saved combat snapshots are non-gameplay frames.

The full ARM service self-test passes. All 851 build inputs are checked; only the two intended GPU3D source files differ from Beta10, apart from the existing standalone private profile test not linked into the helper. Temporary build overlays are restored. Candidate helper SHA-256: `f207c2ebdbc18bce5abb63aae7c4e45cbcc4311b052d5489532d78dee0433dd2`.

## Native rendering controls

Two raster workers on the physical Cortex-A9 at stock 1 GHz, verified frontend parked and restored, six samples per build/scene in ABBA order. Each sample has 16 warmup and 100 measured renders. Full output hashes match. Negative values mean less time.

| Scene | CPU time change | Wall time change |
| --- | ---: | ---: |
| bat-live | -4.610% | -4.605% |
| combat-live | -3.869% | -3.645% |
| nsmb-castle | +1.113% | +1.313% |
| nsmb-castle-left | +0.603% | +0.845% |
| mario-kart-heavy | +0.060% | +0.061% |

The first NSMB castle control is slightly slower. A second ABBA series adds twelve samples per build for each NSMB scene, retaining every valid sample. Pooled over eighteen samples per build, castle CPU/wall changes are +0.979% / +0.971%; castle-left changes are +0.811% / +1.056%.

Thus the native all-controls-under-1% condition was not met. A deliberately limited live experiment was still justified by the 3.6–4.6% target reduction, with the NSMB cost explicitly unresolved. This was not acceptance or a relaxation of the live regression gate. Isolated rendering time is not gameplay FPS.

## Live cave decision

Four fresh isolated suspend copies in baseline/candidate/candidate/baseline order, 22 active seconds each at the bat platform. Analog RGB passes through the RetroTINK-4K and unchanged capture setup. No sampling profiler, other hardware polling or compilation runs during the measured windows.

| Run | Completed pairs/s | Median interval ms | p95 interval ms |
| --- | ---: | ---: | ---: |
| Base | 21.622084 | 45.423 | 53.964 |
| Cand | 21.613926 | 45.179 | 56.377 |
| Cand Repeat | 21.651620 | 45.167 | 56.235 |
| Base Repeat | 21.679738 | 45.097 | 55.000 |

Baseline mean: 21.650911 pairs/s. Candidate mean: 21.632773 pairs/s. Difference: -0.084%. Publication pairs are not distinct displayed animation FPS, and these short stationary-room observations do not establish whole-game performance. The native savings did not yield a useful live improvement; the reason is not established by these trials.

All four captures show complete cave backgrounds, player, haze, pause and map, with HP132 and EXP69 unchanged. There are zero reported protocol faults or capture drops, audio is present, and the stock clock, protected files and isolated saves pass their checks. Audio presence does not establish hitch-free audio. No live combat or NSMB candidate comparison is claimed: those trials were not run after the cave gate failed.

The original NSMB rig, save, 54 protected files and OBS settings were restored, and the completed game-selection menu was visually verified. Early black startup snapshots were excluded from visual restoration acceptance. Runtime sources and both accepted package pointers remain unchanged.

Private evidence: `castlevania-vertical-edge-performance-20261017`. The exact patch, helper, individual timings, qualification and capture receipts are retained privately.
