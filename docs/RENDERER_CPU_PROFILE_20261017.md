# Renderer CPU and wall-time profile — 17 October 2026

Decision: **MEASUREMENT COMPLETE**. The two Castlevania rooms each spend
slightly more than 1 ms of measured CPU time clearing buffers and performing
the final pass. This justifies a separately tested parallel-phase prototype.
Polygon setup also exceeds the 1.5 ms CPU threshold in both rooms and deserves
further investigation. No new runtime is accepted by this diagnostic.

Follow-up: the [parallel-phase prototype](PARALLEL_PHASES_20261017.md) passed
correctness checks but failed its native performance qualification. The measured
serial work did not translate into an accepted optimization.

## Method

A separate helper derived from frozen Beta12 records thread CPU time beside
wall time for coherence, clearing, setup, final processing and polygon-band
preparation. The start-of-frame palette diagnostic is measured separately from
cache coherence. Profiling no longer builds unused scanline lists merely to
populate a counter. No pixel arithmetic, scheduling or clock setting changes.

The diagnostic uses `NDS4MISTER_RENDERER_FRAME_PROFILE=1`, without the broader
per-command timing profile. It still retains renderer instrumentation and
palette diagnostics; its throughput is not an uninstrumented speed result.
The full ARM service suite passed with the gate off and on, including all 19
per-pair record kinds, nonzero exercised thread CPU clocks, zero clock failures
and the existing published-pixel oracles. All 851 source inputs were checked
against the frozen inventory; exactly four diagnostic inputs differ.

One qualified capture per scene uses fresh isolated save copies at stock
1 GHz, unchanged RetroTINK-4K/OBS settings, no sampler and no competing build.
Cave/combat windows are 22/6 seconds, and NSMB is 26 seconds of repeated jumps.
Every renderer-stage record comes from the independently committed Replay
timeline lane, which must be unraced and cover the complete active window.

## Measurements

Numbers below are milliseconds per **rerendered** published pair. Identical
3D-plane reuse is excluded from these phase averages. Wall time can include
descheduling and measurement overhead; CPU time also includes instrumentation.

| Scene | Complete pairs | Rerendered | Identical 3D | Display flags |
| --- | ---: | ---: | ---: | --- |
| BAT | 445 | 445 | 0 | 0x19 |
| FIGHT | 117 | 117 | 0 | 0x19 |
| NSMB | 942 | 823 | 119 | 0x699 |

| Phase | Cave CPU / wall, ms | Combat CPU / wall, ms | NSMB CPU / wall, ms |
| --- | ---: | ---: | ---: |
| Cache coherence | 0.068 / 0.078 | 0.894 / 0.904 | 0.011 / 0.022 |
| Buffer clear | 0.581 / 0.697 | 0.561 / 0.637 | 0.555 / 0.670 |
| Polygon setup | 2.841 / 4.239 | 2.651 / 3.936 | 0.933 / 1.315 |
| Final processing | 0.486 / 0.666 | 0.458 / 0.688 | 1.043 / 1.352 |
| Band preparation | 0.464 / 0.657 | 0.444 / 0.645 | 0.401 / 0.699 |
| Start palette diagnostic | 0.209 / 0.220 | 0.213 / 0.219 | 0.222 / 0.231 |

Castlevania flags are `0x19`: antialiasing is on, edge marking and fog are off.
NSMB flags are `0x699`: antialiasing and fog are on, edge marking is off.
The observed mean polygon counts per published pair are about 560 in the cave
and 548 in combat. NSMB averages 411 including identical-plane reuse; these
are prepared renderer polygons, not a whole-game geometry rate.

Setup contains substantial compute as well as scheduling delay: approximately
2.84 ms CPU versus 4.24 ms wall in the cave, and 2.65 versus 3.94 ms in combat.
The difference does not identify a particular competing thread. The
[same-binary publication-placement test](PUBLICATION_PLACEMENT_20261017.md)
already found that moving publication to CPU1 reduced total throughput.

Coherence is much smaller in the cave than the older wall-time counter
suggested once the start palette scan is separated. Combat coherence remains
substantial, approximately 0.89 ms CPU. This supports measuring texture-cache
invalidation work later; it does not prove that a particular cache optimization
will help. Band preparation costs roughly 0.44–0.46 ms CPU in the targets, but
moving the copy to CPU1 without preserving immutable polygon state would race.

The roughly 1.02–1.07 ms target clear/final CPU sum is work that may be
redistributed, not a promised saving. Parallel joins, replay contention, memory
traffic and binary layout can offset it. The separate prototype must compare
clear-only, final-only and combined modes against option-off and frozen controls.
An edge-marking implementation must avoid concurrent reads/writes of the same
attribute words, even though the polygon-ID bits are unchanged.

## Qualification and limits

The first combat capture passed runtime/video checks, but two Replay snapshot
records raced and stage analysis rejected it. Its capture and failure remain
preserved. A fresh combat save copy produced the qualified replacement; the
original is not selectively reused for phase averages. The cave run is retained;
a fresh NSMB fixture was used when collection resumed.

All qualified contact sheets and the excluded combat recording were inspected.
The expected cave, forest combat and castle jump scenes have intact sampled
graphics and HUD. Qualified combat starts at HP103 and ends at66, EXP69/gold0;
NSMB timer496 ends at474. All captures have audio present, no OBS render/encode
drops, zero fault words and correct runtime/memory/affinity settings. This is
sampled visual review and audio-presence evidence, not audio-fidelity proof.

Both interruption and final cleanup restored the original NSMB runtime/save,
all 54 protected paths, stock clock and unchanged OBS settings. Fresh restored
game-selection snapshots were viewed. The frozen package remains unchanged.

There is only one qualified diagnostic run per scene. The setup counter retains
small per-polygon profiling work; the separately existing line-215 palette scan
is outside the new start-scan counter. Total profiling overhead was not measured
with a same-binary live OFF/ON comparison. Phase costs cannot be converted
directly into an unprofiled frame-rate saving. No memory-bound diagnosis, absolute 60 FPS
ceiling or combined percentage gain follows from these data.

Diagnostic helper SHA-256:
`c1d10b7f658414d4cf6d7a222dfed28f8d3ab8856405d093517fe218fbdb55b6`.

Private evidence: `renderer-cpu-profile-c57-20261017`, including build/source
receipts, qualified per-pair data, the rejected snapshot, visual/restoration
checks and SUMMARY. No diagnostic binary or captured game data is committed.
