# Castlevania raster experiment — 16 October 2026

The [raster edge follow-up](RASTER_EDGE_PERFORMANCE_20261016.md) builds on
this result and resolves the capture's 30 Hz input limitation.

Baseline: Performance Beta 2, `8be7105f5cd586f17a74752c162e2615be0568bd`.
This experiment retains an exact neutral-white modulation shortcut that
reduces rendering CPU time by 4.1% in a fixed Castlevania combat scene. It also
separates the consumer's 3D completion wait from scanline composition and
rejects a slower texture-row prototype. The FPGA, clocks, frame admission,
geometry, display pairing and RTC remain unchanged.

## Where the profiled frame spends time

A private helper adds five frame-correlated records only with timing profiling
enabled. It snapshots stage counters before starting a matched 3D job and
after the completed picture's last row. The previous render job has joined
before its VBlank geometry reuse; the current job's complete-frame fence has
joined before its output is read. Counter snapshots do not add a new wait.
The consumer wait is measured around the existing complete-frame fence.

In one bounded Castlevania: Dawn of Sorrow USA prologue combat window, 104
complete stage records give the following medians:

| Stage | Profiled wall time |
| --- | ---: |
| 3D raster, including its worker join | 21.963 ms |
| Consumer waiting for completed 3D | 25.982 ms |
| 3D coherence, clear, setup and final pass combined | 5.628 ms |
| Scanline work after subtracting 3D output retrieval | 7.837 ms |
| Engine A drawing and composition, inside scanline work | 5.115 ms |
| Engine A sprite preparation | 1.171 ms |
| Engine B sprite preparation | 1.011 ms |
| Parallel raster join, inside raster time | 0.003 ms |

These durations overlap. In particular, the raster job executes while its
consumer waits; adding those two numbers would double-count work. Scanline
work includes the engine/composition/cache stages. Timings are wall time,
including scheduling and instrumentation overhead, not isolated CPU samples.
This diagnostic helper is not used for speed acceptance or beta packaging.

There are 103 complete admission-to-upload chains fully beginning inside the
same input window. Median admission-to-ready is 46.881 ms and upload is
0.952 ms. Input observation is after HPS acquisition, not the original FPGA
scanline timestamp. Neither these intervals nor publication counts measure
unique displayed frames or input-to-photon latency.

## Repeatable rendering inputs

Live combat changes enemy position, HP and effects between runs. For exact
A/B rendering, reuse existing private GPU snapshots:

- Castlevania prologue combat: 614 polygons.
- NSMB castle, two views: 384 polygons each.
- Mario Kart heavy scene: 1,226 polygons, retained as a regression check
  because it exposed earlier interpolation errors.

The GPU-only fixtures preserve the original GPUG, GP2A, GP2B and GP3D
sections; only the container length is rewritten when extracting them from
full snapshots. Both binaries receive identical bytes. They execute no ROM
or emulated CPU and access no FPGA memory. Game-derived fixtures remain
private and are not included in this repository.

## Rejected texture-row prototype

For a cached scalar interior with constant color, constant linear depth and
constant T, resolve the texture row once per span. Skip the invariant T
recurrence and per-pixel Y clamp/repeat/flip. S interpolation, depth selection,
alpha, blending, lower layers, coverage and generic edge rendering retain
their existing rules. No renderer or geometry object fields are added.

The full ARM service self-test passes. The generic uncached renderer and both
baseline/candidate binaries agree across 1,030 raster scenarios on emulated
ARM, including native color/depth/attribute hashes. Added cases include 4-bit
textures. Host, sanitizer and ARM interpolation tests include 96,477
constant-row transitions with skipped positions, negative coordinates and
returns to generic edge interpolation. A separate sanitizer check confirms
1,048,576 row-index equivalences across texture sizes and all wrap modes.

## Native timing method

Run with the standalone core cleanly stopped and MENU active. Verify the
protected installation/save hashes, set the existing clock helper to stock
1 GHz, and restore its prior state afterward. Baseline/candidate/candidate/
baseline ordering gives six samples per path. Each sample checks complete
output hashes outside the timed interval.

Synthetic tests warm up 16 frames and time 32 frames per sample. Fixed game
snapshots warm up 16 renders and time 100 renders per sample, with stage
profiling disabled. Fixed-scene timing uses process CPU time and a single
rendering thread; it is an isolated rendering comparison, not the live
pipeline's dual-core frame time or whole-game FPS.

The first CPU1 fixed-scene run showed only a 0.435% Castlevania CPU reduction
and a 1.162% Mario Kart increase for the texture-row prototype. It was held
out of the beta. A subsequent process/affinity audit found that normal MENU's
main thread also occupied CPU1. CPU time excludes descheduling, but cache and
scheduler contention remain a limitation of those measurements.

The follow-up compares the baseline, texture-row prototype and a separate
neutral-white prototype on CPU0, while verifying that MENU's unchanged main
thread remains on CPU1. The order is base/row/neutral/neutral/row/base, three
separate samples per position. No frontend affinity or priority is modified.

The neutral-white prototype applies only when constant color, positive-width
linear interpolation, equal depth endpoints, white RGB (63/63/63) and polygon
alpha 31 are proven for the entire interior span. The DS modulation equations
then preserve texture RGB and alpha exactly. Texture alpha still controls
rejection/blending. Generic edges and all other spans retain the baseline
shader. The independent identity test passes 17,825,792 cases under host
sanitizers, including discarded RGB bits and alpha-rejection boundaries.

## Selected result

The CPU0 comparison uses six samples per variant and scene. All three
binaries produce identical native color/depth/attribute hashes for every
scene, and every timed sample preserves its initial hashes.

| Fixed scene | Beta 2 CPU ms/render | Neutral-white CPU ms/render | Reduction |
| --- | ---: | ---: | ---: |
| Castlevania combat, 614 polygons | 40.119 | 38.466 | 4.12% |
| NSMB castle, 384 polygons | 12.188 | 12.092 | 0.79% |
| NSMB castle left, 384 polygons | 11.923 | 11.857 | 0.55% |
| Mario Kart heavy, 1,226 polygons | 35.814 | 35.250 | 1.58% |

Castlevania's sample ranges do not overlap: 39.794–40.180 ms for the control
versus 38.313–38.593 ms for neutral white. The NSMB sub-percent differences
have overlapping ranges and should be treated as effectively unchanged.
These are warm, single-thread renderer CPU measurements. They do not establish
a whole-game FPS improvement or a 4% reduction of all frame latency.

The texture-row candidate remains rejected. In the same CPU0 comparison it
reduces Castlevania CPU time by 0.99% but increases Mario Kart by 0.83%, with
non-overlapping Mario Kart ranges. It is not combined with neutral white.

The selected neutral-white renderer passes 1,414 cross-binary raster
scenarios, including 384 white-color dispatch cases. Host, ASan/UBSan and ARM
identity tests all pass 17,825,792 cases. The full ARM service self-test passes.
The private frame-timing additions are excluded from the selected renderer.
Run `tools/test_neutral_modulate.sh` for the host/sanitizer/ARM identity oracle.
The default `tools/benchmark_raster_batch.cpp` matrix checks the optimized
renderer against the generic path, including clamp, repeat and flip cases;
its hashes were also compared across separate baseline/candidate binaries.

## Live regression checks

Four unprofiled NSMB World 2-5 runs use control/candidate/candidate/control
ordering, unchanged stock 1 GHz settings and isolated copies of the same save.
The first pair advances 172 HUD units in 129.124 and 129.121 seconds. The longer
repeat advances 219 units in 164.008 seconds for the control and 220 in
164.354 seconds for the candidate. Combined progression is 1.33387 versus
1.33572 units/second, a 0.139% difference within integer HUD sampling
uncertainty. No slowdown is detected in this quiet scene; heavier levels and
other games are not qualified by it. All four runs have zero core/helper
fault words and unchanged save bytes.

Separate control/candidate repeated-jump recordings pass through analog RGB,
RetroTINK-4K and the existing USB capture device. Both recordings have active
audio and zero OBS render/encode drops. Inspected frames show Mario jumping
with the correct World 2-5 composition. Container frame rate and publication
counts are not unique visible-motion FPS; the capture input remains
uncalibrated for that claim.

Four Castlevania opening runs use the same control/candidate/candidate/control
order and no input, sampling source LCD tags 900–2700. Median publication rates
are 59.6394 and 59.6416 per second (0.004% difference). The same opening images
appear at the sampled endpoints; all sampled fault words are zero and saves
are unchanged. This is a no-slowdown opening check, not a unique displayed-FPS
measurement or sustained combat result.

Both versions also complete the short prologue movement/attack check and
collect a Skeleton soul. The displayed clocks advance from 31 to 38 seconds
for the control and 31 to 39 for the candidate. Character position and effects
differ, so these runs do not establish a matched combat-speed increase.
Both return to the menu, retain unchanged save bytes and report zero fault
words. Analog RetroTINK recordings have active audio, zero OBS render/encode
drops and correct composition in the inspected frames.

## Private beta scope

Performance Beta 3 retains the earlier palette and publication optimizations,
controller mapping, offline RTC fallback and experimental bug-fix baseline.
The selected helper is `9e4e426cbc6ad144885b4837c83612763d8b09d36abc02bc7b7b23663bfeed55`.
It is 4,784 bytes larger than Beta 2. Runtime environment, host, FPGA, clocks,
video helpers and per-game cadence are unchanged. No renderer/geometry fields
were added. The texture-row prototype and private timing instrumentation are
excluded. This is a bounded private experiment, not a complete playthrough
qualification or proof of an overall FPS improvement.


## Next measured targets

The profile points first to the remaining raster work and then to the roughly
7.8 ms of scanline work outside 3D output retrieval. Investigate these with
matched game snapshots and held-out scenes before adding more specializations.
The row experiment shows why removing apparent work can still slow another
game on Cortex-A9.

The consumer's 3D wait overlaps active rendering. Treating that wait as idle
ARM capacity would be misleading. This result does not justify changing
packet-memory attributes or moving geometry into FPGA without separate
measurements of packet acquisition and graphics-query stalls.
