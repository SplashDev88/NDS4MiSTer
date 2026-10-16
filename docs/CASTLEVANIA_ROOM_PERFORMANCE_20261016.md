# Castlevania room performance investigation — 2026-10-16

Status: focused Castlevania test candidate. Exact-output and short live
compatibility checks pass; a live speed gain has not been demonstrated.
Beta6 remains the accepted general runtime.

## Scope

The requested routes are the cave directly left of a save room, with a
respawning bat, and the enemy-heavy room reached by going left, up, then right.
Testing uses Dawn of Sorrow's first Lost Village save near Flying Armor. This
matches the described routes; the user has not yet confirmed the save point.
The upper-right room contains a Warg, armored enemy and spawning zombies.

This replaces the earlier intro-combat workload as the primary Castlevania
optimization target. Earlier intro measurements do not establish performance
in either of these rooms.

## Repeatable test setup

- Physical MiSTer, stock 1 GHz ARM clock, unchanged FPGA and host.
- Beta6 renderer, full-rate admission and existing weighted raster settings.
- Analog RGB through RetroTINK-4K and the existing capture rig.
- Isolated copies of saves; original installation and user saves are protected.
- Separate room-entry Suspend saves for cave and combat. Suspend restores the
  room entrance, not the exact player position. Each run repeats the approach
  and verifies the camera position before measurement.
- Correct-size private 8 KB save created for ACVE. The existing 64 KB user
  sidecar is untouched; the core deliberately treats that wrong-size file as
  nonpersistent rather than overwriting it.

## Clean cave baseline

`C7_BAT_BETA6_BASE` measures 22 active seconds, paused at both ends, with no CPU
sampling or GPU snapshot enabled. The character is on the middle cave platform.

| Measurement | Result |
| --- | ---: |
| Completed picture pairs | 325 |
| Completed picture pairs per second | 14.773 |
| Picture-ready interval, median | 66.950 ms |
| Picture-ready interval, 95th percentile | 75.387 ms |
| Picture-ready interval, maximum | 90.407 ms |
| Admission to completed picture, median | 47.685 ms |
| Completed-picture upload, median | 1.026 ms |
| Capture rendering/encoding drops | 0 / 0 |

The compressed analog recording shows approximately 14.6 significant scene
changes per second at the selected threshold, with zero false changes in its
paused control. This is consistent with the source publication count. Visible
changes depend on animation and the threshold; neither measurement is a claim
about emulated CPU speed or total game FPS. The approximately 59.9 LCD tags per
second likewise do not prove full gameplay speed.

The complete 22-second timeline has no raced records. Stage durations overlap
and include scheduling and waiting, so they must not be added together.

## Clean combat baseline

`C7_FIGHT_BETA6_BASE` is a separate unprofiled attack sequence in the upper-right
room, with a Warg, armored enemy and spawning zombies. Over the actual 6.083 s
header interval it completes 77 picture pairs, or 12.658/s. The coherent
six-second timeline has a 75.803 ms median picture interval and a 101.426 ms
95th percentile. OBS records zero rendering and encoding drops. Character HP
falls from 108 to 99 and experience rises from 70 to 80; attacks, enemy defeat
and effects are visible. Saves and protected files remain unchanged.

This short fight is a workload and compatibility baseline, not a precise
game-speed calibration. Enemy timing and damage vary. Compressed video needs
a stricter change threshold here than in the cave because the paused menu
has visible compression noise. At threshold 24 with at least 48 changed pixels,
the combat region records about 12.67 significant changes/s and zero changes
in its paused control. Audio is present; its full fidelity is not qualified.

## Separate CPU profile

`C7_BAT_BETA6_PROFILE` has 15,011 active-window CPU-clock leaf samples:

| Code group or function | Share of samples |
| --- | ---: |
| All `SoftRenderer3D` methods | 39.45% |
| `RenderPolygonScanline` alone | 25.47% |
| All `GPU3D` geometry methods | 16.05% |
| All `SoftRenderer2D` methods | 10.11% |
| Packet acquisition (`Consumer::begin_into`) | 6.86% |
| Constant-color/depth, neutral cached texture span | 5.43% |
| Translucent pixel blending | 4.30% |

Rows overlap: individual functions are included in their group totals. These
are statistical leaf samples, not inclusive function timings. Profiled runs
are excluded from speed acceptance.

The cave and combat workload captures contain hundreds of flat textured quads.
Their display control is `0x19`, including antialiasing. An AA-off shortcut is
therefore insufficient for the requested scenes.

## Qualified fixed-room inputs

Two private diagnostic captures reproduce the live visible 3-D plane exactly:

| Capture | Polygons | Axis-aligned rectangles | Flat-color polygons |
| --- | ---: | ---: | ---: |
| Cave, middle platform | 561 | 557 | 560 |
| Upper-right combat | 516 | 506 | 515 |

Every polygon in these two captures has constant depth and W. The flat-color
rectangles dominate this workload, despite its 2-D appearance. The captures
were made before starting the corresponding render, with normal savestate
renderer restart hooks suppressed. Their frame IDs fall inside the measured
active input windows. Fresh replay matches the visible 3-D plane; inactive
secondary buffer pixels can retain different history, so live full-buffer
hash equality is not claimed. Baseline/candidate replay comparisons still
require exact color, depth and attribute hashes across all native buffers.

Capture instrumentation is excluded from live speed acceptance. A full
temporary filesystem invalidated one combat capture; after verified archival
of old test artifacts, a fresh capture passed. Stale, late, incomplete and
normal-hook captures are explicitly excluded from live correspondence.

## Rejected prototypes

The following private builds are excluded from the beta:

- Flat polygon depth reuse: effectively unchanged cave timing, with slower
  NSMB controls. Its less selective predecessor also gave no useful gain.
- Four-pixel batching of linear spans: approximately 9.8% slower on the earlier
  lower-cave input workload.
- Skipping unused constant-color setup: approximately 3.1% slower there, with
  approximately 4.5–4.9% regressions in the NSMB controls.
- A top/bottom edge-row shortcut restricted to antialiasing-off scenes: does
  not apply to these rooms.
- The antialiasing-capable edge-row version: 1.43% slower on the qualified cave
  input and 1.64% slower on the qualified combat input. NSMB color/attribute
  hashes also differ, despite the 2,828-case synthetic matrix passing. This
  is a correctness rejection as well as a performance rejection. It was never
  installed for gameplay. The synthetic matrix alone is insufficient.

Earlier lower-cave input replays predate live visible-plane qualification;
those timing results are rejection evidence, not accepted live-speed claims.

## Integral texture-coordinate prototype

When both texture coordinates advance by exact integral steps, repeated
quotient/remainder interpolation is unnecessary. The private prototype proves
that condition once per eligible constant-color/depth interior span and then
advances coordinates by addition. Depth rejection, texture wrapping, alpha
rejection and blending retain their original order. Before returning to a
generic edge, it invalidates the span recurrence so the edge recomputes its
own exact state. Antialiased edge rows stay on their established path.

It passes 259,406 independent coordinate and generic-edge continuation checks
on the host, under ASan/UBSan and on ARM, plus the 2,828-case renderer matrix.
All five native fixed workloads retain exact full color/depth/attribute hashes.
At stock 1 GHz, six samples per binary/workload in ABBA order give:

| Fixed input | Beta6 CPU ms | Unrestricted prototype CPU ms | Change |
| --- | ---: | ---: | ---: |
| Qualified cave | 39.749 | 38.935 | −2.05% |
| Qualified combat | 38.484 | 37.153 | −3.46% |
| NSMB castle | 11.950 | 12.072 | +1.02% |
| NSMB castle, left | 11.753 | 11.888 | +1.14% |
| Mario Kart heavy | 35.780 | 35.747 | −0.09% |

The unrestricted version is not accepted: the NSMB overhead is a regression.
A subsequent prototype selects the shortcut only for the verified Dawn of
Sorrow USA revision-0 cartridge header. Selection uses two matching header
reads and the existing session fence, defaults off for unknown/failed reads,
and is applied before the new instance starts rendering.

The first gated version placed its selection inside the existing hot pixel
function. Although disabled for NSMB, its fallback still regressed the two
NSMB controls by 2.14% and 2.02%. It was not deployed. The revised version
moves selection into the per-span dispatcher and retains the original scalar
pixel-loop body verbatim. It passes all 3,084 synthetic cases, including 256
additional fixtures with deliberately integral texture coordinates. Cross-build
hash comparisons use matching initial renderer history; restarting only one
side invalidates a comparison of buffers that retain earlier state.

The revised native ABBA comparison, again six samples per binary/workload:

| Fixed input | Beta6 CPU ms | Selected-path CPU ms | Change |
| --- | ---: | ---: | ---: |
| Qualified cave | 39.727 | 38.944 | −1.97% |
| Qualified combat | 38.423 | 36.796 | −4.23% |
| NSMB castle, shortcut off | 11.963 | 12.012 | +0.41% |
| NSMB castle left, shortcut off | 11.757 | 11.804 | +0.41% |
| Mario Kart heavy, shortcut off | 35.879 | 36.119 | +0.67% |

All native color/depth/attribute hashes match Beta6. The target renderer gains
are repeatable; the small control overhead remains measurable and is disclosed.
This is a focused Castlevania experiment, not an accepted general replacement
for Beta6.

## Clean live candidate comparison

These runs use the normal runtime, without CPU sampling or GPU capture, at
the stock 1 GHz clock. The cave runs repeat the same approach from isolated
room-entry saves; the second candidate run continues from its paused position.
All timelines cover their requested windows without raced records.

| Room/run | Runtime | Completed picture pairs/s | Median picture interval | 95th percentile |
| --- | --- | ---: | ---: | ---: |
| Cave, first | Beta6 | 14.773 | 66.950 ms | 75.387 ms |
| Cave, repeat | Beta6 | 14.459 | 67.299 ms | 83.028 ms |
| Cave, first | Candidate | 14.384 | 67.215 ms | 82.601 ms |
| Cave, repeat | Candidate | 14.441 | 67.188 ms | 83.091 ms |
| Combat, short attack sequence | Beta6 | 12.658 | 75.803 ms | 101.426 ms |
| Combat, short attack sequence | Candidate | 12.611 | 80.920 ms | 103.416 ms |

The renderer CPU improvement has not translated into a demonstrated live
presentation improvement. The cave remains visibly choppy at approximately
14–15 completed pictures per second; the short combat sequence is around
12–13. These publication counts are not total game FPS. The combat runs have
different enemy phases, damage and defeats, so their small difference is not
a controlled causal speed estimate.

In the candidate combat run, HP falls from 99 to 76 and experience rises from
69 to 81. The Warg, armored enemy, zombies, attacks and effects remain visible.
At the same threshold as the baseline (24, at least 48 changed pixels), the
combat recording has 12.83 significant scene changes/s and zero paused false
changes. The reviewed cave and combat recordings show no obvious new visual
faults. All six recordings have zero OBS rendering/encoding drops, audio
present, zero protocol fault words, unchanged test saves during the measured
sequence, and unchanged protected files. This is short compatibility evidence,
not a full playthrough, audio-fidelity qualification or proof of bug freedom.

## Candidate and next targets

The separate `NDS4MiSTer_Castlevania_Beta1` launcher preserves the established
FPGA, host, clock, frame admission and prior fixes. Only the verified Dawn of
Sorrow USA revision-0 header enables the new path; other identities default
off. The package is optional for focused testing. The remaining control
overhead and absence of a demonstrated live gain prevent general promotion.

The next optimization should target the much larger per-polygon/scanline
setup and edge work, then geometry replay, using these same two qualified
room inputs. The cave profile attributes 25.47% of all sampled work to
`RenderPolygonScanline` and 16.05% to geometry methods; the narrow cached span
function accounts for only 5.43%. CPU reductions must be followed through
frame admission, replay and presentation before claiming smoother play.
Candidate scheduling and packet queues also need comparison: their wall-time
waits overlap rendering and are not independent CPU costs.

Any wider sprite/rectangle specialization must preserve antialiasing,
translucency, depth order and lower-layer behavior. The rejected edge shortcut
demonstrates why passing synthetic cases alone is insufficient. Other-game
controls remain mandatory even when their cartridge gate is off.

## Acceptance criteria

Changes must preserve exact color, depth and attribute outputs in the raster
oracle, improve native ARM timing on the requested room workloads, and avoid
regressions in NSMB and Mario Kart controls. Clean physical comparisons must
retain graphics, audio, save isolation and the stock clock. Diagnostic capture
or CPU sampling must not be used as speed acceptance.

GPU captures need a new request ID, a matching active frame interval and a
fresh receipt. Saving GPU state through the frontend's normal renderer hooks
can restart a worker; the private diagnostic instead fences the previous job
and suppresses those hooks. Unqualified or stale captures are excluded from
live-output correspondence claims. Native buffer hashes include inactive
secondary pixels; visible-plane correspondence is checked separately from
cross-build full-buffer equivalence.

No GitHub Release is published by this investigation. The accepted Beta6
package is unchanged; the Castlevania package is a separate test experiment.
