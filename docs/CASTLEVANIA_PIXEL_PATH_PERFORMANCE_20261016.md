# Castlevania pixel processing experiment — 2026-10-16

Castlevania Beta3 reduces fixed-input renderer CPU time by 4.1% in the cave
and 5.5% in combat compared with Castlevania Beta2. Exact-output tests and
short physical gameplay checks pass. The cave's live picture rate is
essentially unchanged; the combat observation needs repetition with better
matched enemy phases. The 60 fps target remains unmet. Performance Beta6
remains the accepted general runtime.

## Scope and selected changes

The primary workloads remain the cave left of the save room and the crowded
room reached by left, up, right in Dawn of Sorrow USA revision 0. The assumed
save is the first Lost Village save near Flying Armor; the user has not
confirmed that location. See the [Beta2 investigation](CASTLEVANIA_RECTANGLE_PERFORMANCE_20261016.md)
for the preceding rectangle optimization and fixture provenance.

Two ARM renderer changes are selected behind the existing exact cartridge
profile gate:

1. Eligible neutral-white, opaque, constant-depth spans with integral texture
   steps read adjacent decoded texels directly when S advances one texel per
   pixel, T is constant and the complete span stays in bounds. On ARM NEON,
   four pixels are written together only when every texel is fully opaque
   and every front-layer depth comparison strictly passes. Alpha rejection,
   equal depth, lower AA layers and translucent blending retain the scalar
   selection and blend sequence, in increasing X order.
2. The proven axis-aligned rectangle setup path also accepts back-facing
   rectangles with the normal strict less-than depth rule. Its depth function
   is selected at compile time. Back faces do not enter the front-facing
   cached-interior path, which has a different equal-depth exception.

The general scanline fallback retains its separate compiled body. The
earlier attempt to share that body regressed other games. Texture wrapping,
edge coverage, antialiasing, depth ordering and output buffer formats are
preserved. The FPGA, host, stock 1 GHz ARM clock, frame admission, controller
mapping and persistent/offline RTC behavior are retained.

## Correctness qualification

- Full ARM helper self-tests pass.
- The public raster harness now contains 4,108 cases. All compare complete
  native color, depth and attribute buffers with the independent uncached
  renderer. The original 3,084 cases also match the Beta2 build; the 1,024
  added cases cover contiguous texture rows and mixed front/back winding,
  including overlapping depth ties.
- All 48 sequential diagnostic snapshots preserve full-buffer output
  against Beta2: 24 cave and 24 combat inputs. Ten combat inputs are at or
  after the pause transition, so they count as transition correctness checks,
  not active-gameplay opportunity measurements. All 48 visible replay outputs
  also reproduce the actual diagnostic helper output.
- Both qualified fixed room inputs preserve full-buffer output in serial,
  split, weighted-band and delayed-worker modes: 160 checked frame outputs.
- All five native timing workloads retain exact full-buffer hashes.
- The selected helper corresponds to the public runtime sources. The only
  difference in the conservative 851-file build inventory is a standalone
  profile unit-test source that is not linked into the helper. The integrated
  public raster harness is separately qualified.

Selected ARM helper SHA-256:
`185b8d2f6eeada4355233a9619c5c9ff49934ff3c6c2b922134eab260049b1bb`.

## Native Cortex-A9 measurements

Stock 1 GHz, core stopped in MENU, benchmark on CPU0 and MENU on CPU1.
Six samples per binary/workload in baseline/candidate/candidate/baseline
order; each sample has 16 warm-up and 100 measured renders. Original clock
settings and MENU affinity are restored afterward. These are serial renderer
CPU milliseconds for fixed inputs, not live dual-worker wall time or game FPS.

| Fixed input | Castlevania Beta2 ms | Beta3 ms | Change |
| --- | ---: | ---: | ---: |
| Cave | 37.557 | 36.031 | −4.06% |
| Combat | 35.144 | 33.195 | −5.55% |
| NSMB castle | 11.914 | 11.801 | −0.95% |
| NSMB castle left | 11.690 | 11.590 | −0.86% |
| Mario Kart heavy | 35.849 | 35.557 | −0.82% |

No slowdown was observed in the three other-game controls. Their small
changes do not establish a deliberate optimization outside the selected
cartridge path. These percentages are relative to Beta2 and must not be
added to the earlier Beta2-versus-Beta6 percentages.

## Physical cave and combat checks

Analog RGBS at about 59.64 Hz was captured through the RetroTINK-4K and the
existing USB/OBS setup. Video settings were unchanged. These are fresh
baseline/candidate runs with no profiler or GPU snapshot requests during
measurement. All four runs have zero protocol faults, zero OBS render or
encode drops, active audio, unchanged isolated saves and 54 unchanged
protected files. Audio presence is verified; full fidelity is not qualified.
This round does not add a separate physical DV1 or HDMI qualification.

| Room / build | Completed picture pairs | Measured seconds | Pairs/s | Median picture interval ms | p95 interval ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cave / Beta2 | 324 | 22.006 | 14.723 | 66.424 | 78.995 |
| Cave / Beta3 | 324 | 22.060 | 14.687 | 66.293 | 80.027 |
| Combat / Beta2 | 83 | 5.984 | 13.871 | 71.788 | 93.223 |
| Combat / Beta3 | 91 | 6.001 | 15.163 | 65.018 | 84.993 |

Picture-pair rates come from completed source publication counters sampled
at both ends of the active window. Intervals come from the coherent RAM
timeline using the nominal 22- or 6-second input window; boundary differences
can change the timeline event count by one. LCD tags near 60/s are not
rendered-picture FPS, and publication pairs need not be distinct animation
frames. Overlapping timeline stages must not be summed as serial work.

The cave character and camera were visually checked at the middle platform;
the stationary player remained at full health. The candidate's admission to
picture completion median was 47.024 ms versus 47.179 ms for Beta2. The
native CPU savings do not translate into a demonstrated cave picture-rate
gain in this run.

The short combat runs use repeated attacks from HP 99 and experience 69.
Both end at experience 81, but Beta2 ends at HP 52 and Beta3 at HP 63. Enemy
overlap and attack phases visibly differ. Both show effects, attacks and
enemy defeat without new visible faults. The candidate's admission to
picture completion median is 47.438 ms versus 50.295 ms. Its higher observed
picture rate is encouraging, but this six-second comparison does not
establish a repeatable whole-game speed gain.

## Investigated alternatives

Consecutive diagnostic inputs were captured before rendering, with the
previous frame fenced. Across 23 active cave transitions and 13 active combat
transitions, no complete row had an identical canonical key suitable for
exact reuse, including the geometry-only comparison. Palette changes and
animated geometry/effects complicate reuse. Snapshot writes to SD add
substantial overhead and widen the interval between admitted inputs, so this
does not prove that reuse is absent at normal cadence. No cross-frame row
cache is included.

A reverse-coordinate contiguous-span prototype passed the correctness
checks but was not selected or timed natively. Coverage on the inspected
cave input showed zero reverse spans reaching that path; the combat input
had only 30 reverse span calls versus 6,802 forward calls. Many relevant cave
rectangles instead faced backward. The first sequential cave input contains
435 eligible front-facing and 98 back-facing rectangles; combat contains
503 and 9. That evidence led to the selected back-facing setup extension.

The forward-only intermediate build passed correctness but saved less CPU
(cave 1.41%, combat 4.10%) and showed a 1.06% Mario Kart CPU increase in its
control run. It was superseded before live gameplay. The selected combined
build has the results above.

## Remaining work

The largest unresolved question is why measured renderer CPU savings leave
the cave near 15 completed picture pairs/s. Further work should relate
renderer critical-path time, worker contention and frame admission under
the real workload before changing scheduling policy. Mixed opaque and
transparent texture blocks, and tinted effects, remain candidates for more
pixel-loop savings; they need exact-output tests and fresh native controls.
Neither is implemented here. Repeatable longer combat comparisons are also
needed before promoting this focused build to the general baseline.

Private evidence directory: `castlevania-row-reuse-performance-20261016`.
ROMs, saves, GPU snapshots and capture media are excluded from source and
the installable package.
