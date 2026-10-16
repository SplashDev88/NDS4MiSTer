# Castlevania VRAM replay experiment — 2026-10-16

Castlevania Beta4 increases completed picture-pair delivery in the cave from
14.61–14.67/s to 15.88–16.19/s, a 9.54% difference between the two-run means.
It reduces ARM work when replaying packed VRAM writes in Dawn of Sorrow
USA revision 0. Eligible write pairs use 56–58% less CPU time in a native
microbenchmark; that percentage describes one replay operation, not
whole-game speed. These are short scene measurements, with limits detailed
below. The 60 fps target remains unmet. Performance Beta6 remains the
general baseline.

## Why replay became the next target

The [Beta3 renderer changes](CASTLEVANIA_PIXEL_PATH_PERFORMANCE_20261016.md)
reduced fixed-input renderer CPU time while leaving the cave near 15
completed picture pairs per second. A fresh unprofiled Beta3 cave run
produced 323 pairs in 22.021 seconds, or 14.668 pairs/s. Admission to picture
completion took a median 47.321 ms. The interval from picture completion to
the next admitted picture added a median 19.127 ms. Most admissions were
four DS LCD frames apart.

The replay/2D thread used 39.126 CPU ms per completed picture, versus
38.433 CPU ms across the two raster threads, 14.771 ms in input acquisition
and 1.108 ms in publication. These figures include replay and input work for
frames omitted from display; they are not the cost of one isolated frame.
Overlapping wall-time stages cannot be added as serial work. Every skipped
admission had a nearby backlog snapshot above 16 packets, but that snapshot
does not establish the exact cause of the earlier admission decision.

A separate CPU-clock profile found `apply_vram` in 3.44% of helper samples
and about 8.3% of replay-thread samples. That identified a bounded candidate
for reducing catch-up work. Profiling recordings are excluded from speed
acceptance. The existing per-kind pipeline counters omit packed VRAM pairs,
so they are not used to estimate this path's coverage.

## Selected change

The existing exact Castlevania cartridge-profile gate selects a specialized
loop for `VramWritePair` runs. Two adjacent full ARM9 words are written
together only when both remain in the same 512-byte dirty block and mapped
segment. The existing VRAM templates still handle bank overlap, mirrors,
unmapped addresses and dirty tracking. A pair of 32-bit fields preserves
four-byte alignment on Cortex-A9; an eight-byte-aligned integer would not
cover every valid word pair.

Partial writes, block crossings, unsupported addresses and capture-synchronized
Engine B mode retain the original path. Timestamp overflow checks, pending
geometry flushes, SWAP ordering, memory revision batching and scanline
ordering are preserved. Other cartridges retain the original record handler.
The renderer, FPGA, host, stock 1 GHz clock, frame admission, controller mapping
and persistent/offline RTC behavior are inherited unchanged from Beta3.

## Correctness and source qualification

- The complete ARM helper self-test passes.
- A new test compares 98,304 pairs across all 512 bank masks against the
  original two-word operation, including aliases, unmapped ranges, dirty-block
  crossings, mapping boundaries and remaps. Complete VRAM bytes, dirty bits,
  external render revisions and timestamps match.
- Existing matched-display tests enable the specialized path and retain
  paired-pixel, catch-up and ordering checks.
- Every native replay timing workload retains its full VRAM/dirty-state hash.
- The helper matches the public runtime sources. The only difference in the
  conservative 851-file build inventory is a standalone profile unit-test
  source that is not linked into the helper. The private build checkout was
  restored after compilation.

The renderer is identical to Beta3. Its previous 4,108 synthetic raster cases,
48 captured full-buffer comparisons and 160 parallel-renderer comparisons
are inherited qualification, not tests rerun during this replay experiment.

Selected ARM helper SHA-256:
`f8ac30462e6b14fabb9ac21dd6f854bc50d458f996cb0fb2dcc6df3396f17b08`.

## Native Cortex-A9 replay measurements

Stock 1 GHz, benchmark on CPU0, stopped MENU on CPU1. Six samples per
binary/workload in baseline/candidate/candidate/baseline order. Each sample
has 32 warm-up and 512 measured packets, containing 4,096 paired records or
8,192 ordinary word records. The benchmark calls the actual replay-packet
method. Clock settings and MENU affinity are restored afterward.

| Profile / operation | Beta3 ns/record | Candidate ns/record | Change |
| --- | ---: | ---: | ---: |
| Castlevania, eight-byte-aligned pairs | 427.989 | 180.169 | −57.90% |
| Castlevania, four-byte-offset pairs | 428.047 | 185.147 | −56.75% |
| Castlevania, ordinary words | 286.873 | 289.771 | +1.01% |
| Other profile, eight-byte-aligned pairs | 428.248 | 429.110 | +0.20% |
| Other profile, four-byte-offset pairs | 428.929 | 430.141 | +0.28% |
| Other profile, ordinary words | 287.184 | 289.217 | +0.71% |

Four-byte-offset workloads include pairs that cross a dirty-block boundary
and therefore fall back. Fallback controls show small overhead, up to 1.01%;
they do not establish zero cost outside the optimized operation.

## Physical gameplay measurements

Analog RGBS at about 59.64 Hz is captured through the RetroTINK-4K and the
existing USB/OBS setup. No video settings are changed. These measurements
have no CPU sampling or GPU snapshot writes during the active input window.
This round does not add physical DV1 or HDMI qualification.

All eight unprofiled runs have zero protocol faults, zero OBS render/encode
drops, active audio, unchanged isolated saves and 54 unchanged protected
files. Audio presence is checked; full audio fidelity is not qualified.

| Scene / build | Completed pairs | Seconds | Pairs/s | Median interval ms | p95 interval ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cave / Beta3, first | 323 | 22.021 | 14.668 | 66.579 | 80.620 |
| Cave / Beta3, repeat | 321 | 21.976 | 14.607 | 67.015 | 80.487 |
| Cave / Beta4, first | 349 | 21.984 | 15.875 | 62.463 | 72.307 |
| Cave / Beta4, repeat | 356 | 21.986 | 16.192 | 62.380 | 65.417 |
| Combat / Beta3 | 85 | 5.965 | 14.250 | 67.188 | 98.015 |
| Combat / Beta4 | 90 | 5.985 | 15.038 | 66.816 | 77.240 |
| NSMB castle / Beta3 | 1161 | 26.030 | 44.602 | Excluded | Excluded |
| NSMB castle / Beta4 | 1161 | 25.988 | 44.674 | 23.157 | 30.631 |

RAM timeline snapshots with raced records are excluded entirely from stage
and interval analysis: NSMB castle / Beta3. The independently sampled
publication-counter windows remain valid.

The NSMB castle control uses the same isolated save and 26 seconds of repeated
jumping at the entrance. It measures 44.602 versus 44.674 pairs/s
(+0.16%). This short control checks for an obvious other-game
regression; it does not establish zero overhead or a general speed gain.

The cave character and camera remain on the middle platform at HP 132 and
experience 69. Both candidate windows exceed both baseline windows. The
mean publication-rate difference is +9.54%. The second candidate window
continues its session after a separate diagnostic profile; the final baseline
window uses a fresh golden-save launch. Bat phases vary, so this is a repeated
scene observation rather than a deterministic full-game benchmark.

Picture-pair rates use completed source publication counters at the active
window boundaries. The counts are not necessarily distinct animation frames.
The interval distributions use the coherent RAM timeline; nominal-window
boundaries can differ by one event from the counter window. LCD tags near
60/s are not rendered-picture FPS. Compressed analog-frame differences have
nonzero paused controls, so they are used for visual inspection, not the
reported rate.

In the first candidate cave run, admission to picture completion falls from
47.321 to 46.453 ms median, and completion to next admission falls from
19.127 to 16.668 ms median. More admitted frames are separated by three LCD
frames instead of four. Replay/2D CPU per completed picture falls from
39.126 to 34.134 ms. This includes the changed number of omitted frames
between pictures and must not be described as a fixed per-frame CPU saving.
A separate candidate profile reduces `apply_vram` samples from 514 to 14,
with specialized work inlined into the replay loop; percentages across
changed work rates are not a direct total-speed measurement.

The six-second combat checks start at HP 103 and experience 69, using the
same repeated-attack sequence. Beta3 ends at HP 64 / experience 81; the
candidate ends at HP 92 / experience 79. Enemy overlap, knockback and defeat
phases differ. Both show attacks and effects without visible new faults.
The observed 14.250 versus 15.038 pairs/s is not sufficient evidence for a
repeatable combat speed gain.

## Alternatives and remaining work

The first prototype put an aligned-pair shortcut inside the general record
handler. Its direct-call microbenchmark showed a 6.4% slowdown for unaligned
pairs. It was superseded before gameplay. A second prototype moved dispatch
to the Castlevania replay run but still required eight-byte alignment; its
unaligned control regressed by about 3%. The selected version also handles
four-byte-aligned pairs within one dirty block. Earlier prototype timings
use different call boundaries and must not be compared directly to the
selected packet-level benchmark.

The remaining workload includes geometry processing, general polygon
rasterization, rectangle rendering and translucent blending. Further work
should preserve exact output and test the same rooms before changing frame
admission or discarding more work. This experiment does not establish that
the existing FPGA/ARM division can reach 60 fps in these scenes.

Private evidence directory: `castlevania-replay-performance-20261016`.
ROMs, saves, GPU snapshots and capture media are excluded from source and
the installable package.
