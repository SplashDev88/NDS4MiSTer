# Castlevania rectangle rendering experiment — 2026-10-16

Status: exact-output, native timing and short physical room checks pass.
A sustained live speed gain is unconfirmed. The 60 fps target has not been reached. Beta6 remains the
accepted general runtime.

## Scope and implementation

This extends the integral texture-coordinate experiment for the exact tested
Dawn of Sorrow USA revision 0 header. The cave directly left of the save room
and the combat room reached by left, up, right remain the primary workloads.
The assumed save is the first Lost Village save near Flying Armor; the user
has not confirmed that location. See [the room investigation](CASTLEVANIA_ROOM_PERFORMANCE_20261016.md)
for fixture provenance and earlier results.

A new scanline setup path accepts only proven front-facing, axis-aligned
rectangles with neutral white vertex color, polygon alpha 31, constant W/Z,
linear interpolation and the normal less-than depth rule. It verifies all
four unique corners and their adjacency, not just the bounding box. Shadows,
degenerate quads and all unqualified polygons retain the existing path.

Eligible rectangles reuse their constant depth, color, edge position and
coverage. Texture coordinates retain the original interpolation. The pixel
loops retain alpha rejection, both framebuffer layers, depth ordering,
translucency and antialiased edge handling. This is not an AA-off shortcut.
The general fallback retains its separate compiled body because sharing it
with a template caused measurable regressions in other games.

The qualified cave input selects 434 of 561 polygons (6,690 scanline calls);
combat selects 473 of 516 (7,562 scanline calls). The FPGA, host, 1 GHz ARM
clock, query policy, frame admission and runtime environment are unchanged.

## Exact-output qualification

- Full ARM helper self-tests pass.
- All 3,084 synthetic raster cases match the previous baseline, including
  full native color, depth and attribute buffer hashes, not only visible RGB.
- Both qualified room inputs produce identical full-buffer hashes with
  serial rendering, two-way splitting, weighted bands and a deliberately
  delayed worker: 160 checked frame outputs total.
- All five native fixed workloads preserve exact full-buffer hashes.
- The final source cleanup rebuilds to the identical tested ARM binary.

The private parallel harness initially queued an extra implicit startup
frame while enabling threads/loading the snapshot. That raced its own reads.
The corrected harness loads and primes synchronously, then joins the implicit
thread-start frame before testing. Only corrected runs count as evidence.
No production synchronization change was needed.

## Native Cortex-A9 measurements

Stock 1 GHz, core stopped in MENU, benchmark isolated on CPU0 with MENU on
CPU1. Six samples per binary/workload in baseline/candidate/candidate/baseline
order; each sample has 16 warm-up and 100 measured renders. Exact original
clock settings and MENU affinity are restored afterward. Times are renderer
CPU time for a fixed input, not whole-game FPS or live dual-worker wall time.

| Fixed input | Beta6 CPU ms | Rectangle CPU ms | Change |
| --- | ---: | ---: | ---: |
| Cave | 39.731 | 37.709 | −5.09% |
| Combat | 38.478 | 35.215 | −8.48% |
| NSMB castle | 11.933 | 11.968 | +0.30% |
| NSMB castle left | 11.615 | 11.613 | −0.02% |
| Mario Kart heavy | 35.877 | 35.917 | +0.11% |

These are whole candidate-versus-Beta6 results, including the earlier
integral texture-coordinate work. They must not be added to earlier gains.

## Rejected shared-template variant

A second prototype shared one templated pixel body and skipped an unused
perspective-factor update along constant-depth edges. It passed the full
raster matrix, parallel checks and 824,160 independent edge checks on host,
ASan/UBSan and ARM. Nevertheless, its native gains were smaller (cave −2.59%,
combat −7.10%) and the controls regressed: NSMB +4.62%/+5.01%, Mario Kart
+2.16%. It was never installed for gameplay and is excluded from this build.
Those edge-stepping changes and tests do not describe the selected candidate.

## Live validation

The new rectangle build completes 322 and 324 picture pairs in the two
22-second cave windows (14.631/s and 14.717/s). Their median picture intervals
are 66.654 and 66.639 ms, with 95th percentiles 79.959 and 76.937 ms. These
remain within the earlier baseline spread; no live cave speed gain is claimed.
Character position/camera are visually checked on the middle platform, but
Suspend restores the entrance and approaches/enemy phases are not identical.
The fresh baseline required an additional position correction after resume.

A separate 22-second scheduling experiment lets only the secondary raster
and replay workers use either ARM core. It delivers 319 pairs (14.494/s), with
an 81.922 ms 95th-percentile picture gap and 113.137 ms maximum. The original
affinities are restored exactly, after which the second standard run above
delivers 14.717/s. This hypothesis has no demonstrated benefit and is excluded.
It is a scheduling comparison, not a second rendering optimization.

The candidate's six-second combat check completes 82 picture pairs
in 6.014 s (13.634/s); the coherent timeline has a 73.729 ms median picture
interval and a 95.841 ms 95th percentile. The repeated attack sequence shows
enemy damage/defeat and effects, with HP 99→72 and experience 69→79. The
fresh Beta6 comparison completes 73 pairs in 6.004 s (12.159/s), with a
79.786 ms median picture interval and 105.542 ms 95th percentile. Candidate
and baseline video show 13.50 and 12.33 significant changes/s at the same
combat-region threshold (RGB delta >24, at least 48 pixels), with zero paused
false changes. This is encouraging, but the baseline takes more damage
(HP 99→36) and ends at experience 80: enemy overlap and phases differ.
The six-second comparison does not establish a repeatable 12% speed gain.
Both runs show attacks, effects and enemy defeat without new visible faults.

All five standard live trials have zero protocol faults, zero OBS render or
encode drops, active audio, unchanged isolated saves during measurement and
unchanged protected files. Timelines are coherent. Short, phase-dependent
fights are compatibility/workload checks, not precise game-speed calibration.

The fresh Beta6 cave baseline completes 325 picture pairs in 22.012 s
(14.764/s). Its picture-ready interval median is 67.015 ms, 95th percentile
72.727 ms. Admission to picture completion is 47.778 ms median; upload is
1.025 ms. The full timeline is coherent, and OBS drops zero render/encode
frames. The compressed baseline capture's combat region shows 14.77 significant
changes/s at RGB threshold 32 with at least four changed pixels and zero
paused-control changes. These are presentation measurements, not emulated
CPU or animation-rate measurements. LCD tags near 60/s do not establish
60 rendered pictures/s.

For a common cave video threshold with zero paused false changes in every
run (combat region, RGB delta >32, at least 12 pixels), baseline/candidate/
candidate-repeat show 14.00/14.05/13.32 significant changes per second. Small
bat motions can fall below that threshold. The source publication counters
are the primary completed-picture measurement; compressed video alone must
not be labeled emulator FPS. Audio is present, but full fidelity is not
qualified. Capture settings are unchanged.

Private evidence directory: `castlevania-scanline-performance-20261016`.
No ROM, save, GPU snapshot or capture media is part of the source or package.

## Next performance target

The requested rooms still need a much larger reduction in total frame work.
The next candidate to investigate is reuse of unchanged background rows or
polygon groups across frames, with exact invalidation for geometry, texture,
palette, clear state, depth/alpha history and neighboring final-pass effects.
First measure the reuse opportunity on consecutive live inputs, then compare
all buffer layers and changing-scene transitions before native timing. This
is a hypothesis, not implemented functionality or a promised route to 60 fps.
