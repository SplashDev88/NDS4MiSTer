# Graphics performance experiment — 15 October 2026

The subsequent [complete-frame publication experiment](PUBLICATION_PERFORMANCE_20261015.md)
retains this palette change and measures an additional WC upload improvement.
The [Castlevania raster experiment](CASTLEVANIA_RASTER_PERFORMANCE_20261016.md)
retains both changes and adds a measured neutral-white modulation shortcut.

This experiment retains a small ARM background-rendering optimization. It does
not establish a whole-game FPS increase. Two 3D batching prototypes were slower
on the physical Cortex-A9 and were removed. The FPGA, ARM clock, frame-pair
ownership and accepted per-game cadence remain unchanged.

The baseline is `db09fc5cee49ccca4e9e3b9b71e65ba303836607`: the experimental
SWAP/busy core, overflow-safe renderer with preserved geometry offsets, and
offline RTC fallback. The example games are New Super Mario Bros. USA revision
0 and Castlevania: Dawn of Sorrow USA revision 0. Tests used isolated save
copies; commercial assets and captures are not part of this source tree.

## Retained change

Reuse the existing converted standard BG palette for non-mosaic 8bpp text
backgrounds and standard-palette tiled extended-affine backgrounds. The latter
includes linear, rotated/scaled and mosaic drawing. The real palette bytes are
still checked once per composed scanline, so direct writes remain visible.
Palette index zero, window masking, both layer planes and the existing bit-15
green-channel convention are preserved. Extended palettes, bitmap backgrounds
and direct-color rendering keep their original paths.

No data fields were added and no 3D rendering source changed. This avoids the
geometry-layout issue encountered in the earlier overflow experiment.

### Direct hardware timing

The ROM-free benchmark calls the actual renderer, includes the once-per-line
palette check and compares the baseline and candidate core libraries. Both use
GCC 13.3, Cortex-A9/NEON, Release `-O3` and LTO. Tests ran on MiSTer's CPU1 at
1 GHz with the game stopped, in baseline/candidate/candidate/baseline order.
Each invocation performs three samples of 100,000 scanlines per scenario.
The table reports medians of six samples per binary. All output hashes match.

| Drawing path | Baseline ns/line | Candidate ns/line | CPU time reduction |
| --- | ---: | ---: | ---: |
| 8bpp text | 14,477.55 | 13,498.55 | 6.76% |
| Tiled affine, horizontal | 15,747.20 | 13,185.80 | 16.27% |
| Tiled affine, rotated/scaled | 25,999.20 | 22,943.55 | 11.75% |
| Tiled affine, mosaic | 32,534.90 | 31,887.10 | 1.99% |

These are synthetic path timings, not frame times. Palette animation, windows,
tile content, cache pressure and other work change the benefit in real games.
The benchmark restores the preceding clock state after completion.

### Correctness and game checks

- The complete ARM-target hybrid service self-test passes.
- The real-renderer palette oracle passes 32,768 cases on both the Cortex-A9
  target runtime and native Linux. It compares both layer planes against the
  raw-palette path, including palette/VRAM writes, wrapping, flips, windows,
  mosaic, affine transforms, both engines and unaffected palette/bitmap paths.
  There are 17,860 nontrivial outputs, 2,048 eligible text cases and 4,096
  eligible affine cases. Both platforms produce digest `364396100922484907`.
- NSMB World 2-5: in the first quiet control/candidate pair, both timers
  advanced 172 units, over 129.518 and 129.357 seconds respectively. This is
  essentially unchanged progression; integer HUD readings do not establish
  a small percentage speed increase.
  The longer repeat measured 218 timer units in 163.901 seconds for the
  control and 219 in 164.289 seconds for the candidate. Combining both pairs
  gives 1.3292 versus 1.3315 timer units/second, a 0.18% difference within
  HUD quantization. No slowdown was observed in these quiet scenes; this
  does not qualify heavier levels or other games. All four runs preserved
  the isolated save bytes and reported zero core/helper fault words.
- One separate 30-second statistical-profile pair measured 14.069 versus
  13.935 renderer CPU ms per logical input frame, a 0.95% reduction. This is
  observational evidence from one pair, not a proven game-speed gain. Most
  NSMB background samples still use paths unaffected by this patch.
- Castlevania boots, reaches the prologue and completes the bounded movement
  and attack check. Both control and candidate advance the displayed play
  clock from 31 to 39 seconds. Enemy position and damage differ, so this is a
  compatibility check, not a matched performance comparison or playthrough.
- Analog RGB through RetroTINK-4K was recorded for both games, with no OBS
  render or encode drops in those captures. NSMB uses Main; Castlevania uses
  Touch through Screen Peek. No obvious composition fault was seen in the
  inspected frames. This does not replace extended gameplay coverage.

## Rejected and unqualified experiments

| Experiment | Result | Decision |
| --- | --- | --- |
| Four-pixel NEON batching for opaque constant-color, constant-depth linear spans | Exact output across 774 raster scenarios, but native target scenes take 1.66% and 1.88% more time. | Removed. |
| Batch only after the first depth pass, requiring four front pixels and an eight-pixel minimum remainder | Same 774 exact raster scenarios, but native target scenes take 4.62% and 5.25% more time. | Removed. |
| Disable the NSMB-specific alternate drawing cadence | Publication activity nearly doubles. One quiet timer comparison is about 0.94% slower; the physical recording does not demonstrate doubled visible motion. | Keep existing default. Requires heavier scenes and capture calibration. |

The scalar linear-span path was already optimized. More vector arithmetic did
not make these tested kernels faster. Possible causes include setup cost,
register pressure and instruction layout; this experiment does not isolate
which cause dominates.

OBS records at 60 Hz, but the Guermok USB2 input is using a 1280x720 capture
preset. The inspected moving region generally changes at roughly 30 Hz even
when completed-picture publication activity is doubled. Capture input cadence
has not been calibrated. Publication counters and a 60 Hz recording container
are therefore not measurements of unique displayed animation or input latency.
Landing pauses and animation phases also prevent whole-window pixel-change
counts from serving as FPS comparisons.

## Review and next priorities

The baseline already has NEON vertex transforms, exact paired viewport
division, perspective batching, decoded texture reuse, constant-color linear
spans, sparse clears, weighted dual-core raster bands, direct band rebasing,
complete paired frames, Engine B line reuse, fixed packet storage, SPSC/futex
queues and write-combined publication. Reimplementing these is not new work.

| Priority | Opportunity | Evidence and next acceptance gate |
| --- | --- | --- |
| 1 | Measure the specific raster and texture modes in a repeatable Castlevania scene. Optimize the dominant scalar kernel only after identifying its costs. | An exploratory profile attributes 21.5% of helper self samples to polygon scanlines and 11.2% to the flat linear shader. That run changed scenes, so it is a lead, not a qualified timing baseline. The two failed batching attempts demonstrate why native A/B timing is required. |
| 2 | Target the remaining NSMB 2D background work, including palette and tile fetches in the unaffected paths. | Quiet-scene self samples put extended backgrounds at 7.2% and text backgrounds at 5.6%. The retained cache extension does not cover the dominant sampled paths in this scene. Trace the actual mode before adding another cache; preserve raw-write invalidation. |
| 3 | Measure graphics-query stall time and investigate a small FPGA matrix/query engine. | Intake matrix-prefix processing costs CPU, but query latency can matter beyond that CPU share. Require ordered queries, exact integer results and reset/SWAP tests before a hardware build. |
| 4 | Reduce repeated packet scanning or copying where profiling proves it worthwhile. | Packet acquisition and intake polling each account for about 6% of NSMB self samples. NEON packet copies and fixed storage already exist. Preserve header rechecks, immutable ownership, fences and malformed-packet rejection; removing these is not an optimization. |
| 5 | Calibrate capture cadence, then revisit per-game rendering cadence and representative PGO. | The current capture cannot establish a 30-to-60 visible-motion gain. Broader held-out scenes are needed to avoid trading one game's improvement for another's regression. |

Profile percentages above are statistical leaf/self samples from the helper
and its kernel execution, not inclusive call-tree totals or percentages of
whole-system elapsed time. CPU samples alone do not measure FPGA stalls.
The quiet NSMB baseline consumed 26.48 helper CPU seconds over 31.45 elapsed
seconds across its threads, about 0.84 CPU cores on average. That does not
exclude short serial bottlenecks or FPGA waits, but it is another reason not
to assume that reducing matrix arithmetic will increase game speed.

## FPGA geometry / ARM rasterization proposal

The source already separates geometry/state processing in `GPU3D.cpp` from
software rasterization in `GPU3D_Soft.cpp`. Moving the former into FPGA is a
plausible architecture, but a matrix multiplier alone is a smaller change than
moving the full geometry engine.

In the quiet NSMB sample, `MatrixMult4x4` and `MatrixMult4x3` together account
for about 0.6% of helper self samples. Eliminating just those instructions has
limited direct CPU upside in this scene. This does not rule out an offload:
transform, lighting, clipping, polygon setup and especially cross-processor
query waits must be measured separately.

The current experimental fit uses 34,260/41,910 ALMs, 27/112 DSP blocks and
534/553 RAM blocks. DSP availability is encouraging, but only 19 RAM blocks
remain. Full geometry storage and transport need an explicit buffering/DDR
design; spare multipliers alone do not establish fit or routing success.

A useful first prototype would keep ARM rasterization and complete-frame
pairing, process ordered matrix/query commands locally, and compare its
results against the existing ARM implementation. It must preserve fixed-point
rounding/overflow, partial-command state, stack behavior, geometry enable,
test-result timing, SWAP retirement, and session/reset generations. A fence
acknowledgement is not a completed query. The existing generation-checked
owner in `rtl/nds_h3d_gx_readback_owner.vhd` is part of that contract.

If measured query waits justify expanding the prototype, transform batches
into ARM-visible immutable buffers rather than introducing a blocking MMIO
transaction per vertex. Full clipping/lighting/viewport offload would then
need exact polygon/state oracles and sustained gameplay tests. No FPGA
geometry offload is included in this beta, and no speedup is assumed for it.

## Reproducing the ROM-free checks

Configure the usual ARMHF Release/LTO build, then explicitly build
`nds_background_palette_test` and `nds_background_palette_bench`. Run the
oracle under the target runtime or on an idle device. The benchmark accepts a
line count, for example `nds_background_palette_bench 100000`.

For a baseline comparison, build the same benchmark source against the
preceding core library with matching compiler options. Compare output hashes
before interpreting the timings. Run native benchmarks with gameplay stopped;
emulated ARM runtime timings are not Cortex-A9 performance measurements.
