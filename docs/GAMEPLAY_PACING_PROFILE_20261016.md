# Gameplay pacing and ARM profiles — 16 October 2026

Baseline: Performance Beta 4, `9cf56bf9776560511926a5c51bd66ef37159613d`.
The calibrated capture reveals a useful NSMB opportunity: removing its fixed
alternate-frame drawing policy increases visible character changes from
about 30/s to 54.5–55.5/s in two repeated-jump trials. The ARM helper
and FPGA image are byte-identical to Beta 4. Four longer game-clock trials
find no detectable slowdown in the tested scene. The setting is accepted
for private Performance Beta 5; this does not establish full-game speed.

The profiles also distinguish the games. Named 3D raster routines account
for about 41% of sampled helper CPU work in Castlevania, versus 10% in NSMB.
Named 2D routines account for about 7% and 20%, respectively. A matrix-only
FPGA offload is a lower priority for these measured scenes.

## Method and limits

Tests use Castlevania: Dawn of Sorrow USA revision 0 and NSMB USA revision 0,
isolated save copies, the existing analog RGB/RetroTINK-4K capture chain,
manual 1280×720 capture at the device's advertised 60.00024 Hz, and stock
1 GHz ARM clocks. OBS records at 60 Hz. The earlier
[capture calibration](RASTER_EDGE_PERFORMANCE_20261016.md#capture-calibration)
established approximately 59.57 distinct counter updates/s through this chain.

Input steps use absolute deadlines to avoid accumulated per-step drift.
Actual input times are recorded, and 22-second active windows exclude the
initial pause and final menu. Ordinary frontend input still has scheduling
latency, so identical input plans do not guarantee identical enemy states.
Physical recordings and source timeline counts are kept separate. The
existing timeline is flushed after the measured window; no profiling runs
are used as speed-acceptance measurements.

Visible-change detection averages the captured game rectangle to DS
resolution, then compares successive RGB pixels. NSMB's primary character
region uses a 16-level RGB threshold and at least 12 changed pixels;
Castlevania's screen region uses 32 levels and 12 pixels. Neighboring
thresholds and paused controls are retained to expose compression noise.
These are changes in the selected image region, not an exact whole-game FPS
or latency meter. Static animation, landing pauses and soul messages can
produce unchanged pictures intentionally. The capture is not frame-perfect.

## Beta 3 / Beta 4 gameplay comparison

Four unprofiled runs per game use control/candidate/candidate/control order.
NSMB starts at HUD 391 and ends at 354 in all four jump replays, with the
same lives, coins and score. Every run has zero core/helper fault words,
unchanged isolated saves and zero OBS render/encode drops.

| Replay | Visible NSMB character changes/s | Completed picture pairs/s |
| --- | ---: | ---: |
| Beta 3, first | 30.23 | Timeline not collected |
| Beta 4, first | 30.09 | 29.91 |
| Beta 4, second | 30.14 | 29.91 |
| Beta 3, second | 30.32 | 29.91 |

NSMB's primary paused controls have zero detected changes. Median visible
change spacing is 33.3 ms, with p95 33.3–50 ms and maximum 50–66.7 ms.
The three retained source timelines have no picture-completion gap over
50 ms. No meaningful Beta 3/Beta 4 motion improvement is established here.

| Replay | Visible Castlevania screen changes/s | Completed picture pairs/s | Median admission-to-picture, ms |
| --- | ---: | ---: | ---: |
| Beta 3, first | 16.27 | 17.14 | 41.44 |
| Beta 4, first | 16.68 | 17.55 | 40.57 |
| Beta 4, second | 17.09 | 17.86 | 40.21 |
| Beta 3, second | 18.27 | 18.32 | 40.30 |

All four Castlevania clocks advance from 00:00:31 to 00:00:56. However, the
last control remains fighting the Skeleton, while the other runs defeat it
and advance to the Armor Knight/Golem sequence. Damage and effect timing
also differ. These are not matched workloads, so their overlapping rates
do not establish a causal gameplay FPS gain. The prior exact fixed-scene
benchmark remains the evidence for Beta 4's 4.22% renderer CPU reduction.

Castlevania's visible p95 gaps range from about 67 to 83 ms. Some unchanged stretches
reach about 0.28 seconds during gameplay messages, while source picture
completion has much shorter gaps. Those visible holds must not all be
reported as renderer stalls. The primary paused control has zero or one
detected change in approximately 90 transitions, and threshold sensitivity
remains part of the uncertainty.

## Pipeline evidence

The first Beta 4 NSMB trace retains the entire 22-second active window:

- 1,310 geometry submissions, about 59.55/s, and 658 completed pictures,
  about 29.91/s. Exactly 658 of 1,316 LCD admissions omit drawing under the
  existing half-rate policy.
- Median admission-to-picture is 17.82 ms; p95 is 20.01 ms. Median completed
  picture-to-upload-start is 79 microseconds, and upload takes 0.928 ms.
- 13,102 fast query replies have median acquisition-to-reply time
  62 microseconds and p95 651 microseconds. Acquisition begins after the
  producer makes its packet ready; these are not complete FPGA/guest stall
  measurements.

Castlevania's first control trace has roughly 43.75 ms median packet queue
wait and 41.44 ms admission-to-picture time. It renders 377 of 1,317 LCD
admissions, omitting obsolete derived pictures while replaying their state.
There are no fast or ordered query replies in this combat window. Rendering
and replay pressure, rather than query replies, are the immediate lead here.
Queue and draw spans overlap and include scheduling; summing them does not
give total CPU time or input-to-photon latency.

## Remaining CPU costs

Separate Beta 4 runs sample every helper thread with CPU-clock leaf sampling
at 499 Hz. Exact matching ELF symbols resolve 9,173 NSMB and 15,211
Castlevania samples within the active 22-second windows. These are self
samples including the helper's kernel execution, not inclusive call trees.
Profiling perturbs scheduling and is excluded from speed comparisons.

| Named function group | NSMB samples | Castlevania samples |
| --- | ---: | ---: |
| `SoftRenderer3D` raster routines | 9.69% | 41.15% |
| `SoftRenderer2D` routines | 19.96% | 7.27% |
| `GPU3D` geometry/state routines | 12.02% | 17.01% |
| Packet acquisition (`Consumer::begin_into`) | 4.84% | 5.52% |
| Intake polling (`poll_replay_input`) | 4.12% | 3.04% |
| Complete-frame publication | 3.17% | 1.16% |
| Named matrix multiplication routines | 0.61% | 0.12% |

Inlined and shared routines can fall outside these named groups. The main
Castlevania polygon scanline routine accounts for 26.65%, and its neutral
cached interior span adds 8.78%. NSMB's extended-background routine accounts
for 7.05%, and its text-background routine adds 6.29%. Context switching is
also visible: `finish_task_switch` accounts for 7.88% of NSMB and 3.95% of
Castlevania samples. Reducing wakeups must preserve query responsiveness.

Hardware performance counters report 0.65/0.77 instructions per cycle and
2.00%/2.15% generic cache-event miss ratios for NSMB/Castlevania. Counters
cover the full 32-second profiling interval and run without multiplexing.
They do not establish DRAM bandwidth saturation, a texture-only cost or a
percentage of time stalled on memory.

## NSMB full-rate candidate

The candidate retains helper SHA-256
`a39c7236202a639113e1a8190bc698521e104d94a1a7fc1edee60d7841347ce9`.
Only the launch setting changes from `NDS4MISTER_STANDALONE_FRAME_SKIP=nsmb-half`
to `off`. The previous override applied only to the verified NSMB USA
revision-0 fingerprint. Other games already used full-rate admission.

All authoritative records still replay, complete 2D/3D screen pairs remain
paired, and the existing age/queue backlog checks still reject obsolete
derived pictures. No new pixel-loop selector, approximate arithmetic,
geometry format, FPGA image, clock or host binary is introduced.

In the first unprofiled candidate trial, the character detector measures
54.55 changes/s, median spacing 16.7 ms, p95 33.3 ms and maximum 50 ms, with
zero changes in the paused control and zero OBS drops. The source completes
59.82 picture pairs/s, with median interval 16.76 ms and p95 18.46 ms.
The game again advances from HUD 391 to 354. Visible change rate need not
equal picture rate because consecutive drawn animation states can match.

The four longer quiet World 2-5 trials use Beta 4/full-rate/full-rate/Beta 4
order. Elapsed time comes from the two coherent source snapshots, rather
than assuming the requested 125-second sleep is the whole interval.

| Trial | HUD countdown | Actual seconds | HUD units/s |
| --- | ---: | ---: | ---: |
| Beta 4, first | 382 → 210 | 128.971 | 1.33364 |
| Full-rate, first | 380 → 206 | 130.276 | 1.33563 |
| Full-rate, second | 380 → 206 | 130.455 | 1.33379 |
| Beta 4, second | 382 → 210 | 129.216 | 1.33111 |

Aggregating elapsed time and HUD progress gives 1.33237 units/s for Beta 4
and 1.33471 for full-rate, a +0.18% difference. This is within the integer
HUD sampling uncertainty: no slowdown is detected in this bounded scene.
All four have unchanged saves and zero core/helper faults. This does not
qualify the speed of every level, enemy load or multiplayer mode.

The first full-rate replay averages 1.20 CPU cores of helper work, versus
about 0.80 for Beta 4, measured over the full input replay including paused
margins. The additional motion costs ARM headroom; CPU frequency remains
1 GHz. The second full-rate replay averages 1.19 cores and again advances
from HUD 391 to 354, with unchanged saves and zero fault words.

| Unprofiled motion trial | Character changes/s | Median gap, ms | p95 gap, ms | Maximum gap, ms | Completed picture pairs/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Beta 4, first | 30.09 | 33.3 | 50.0 | 66.7 | 29.91 |
| Beta 4, second | 30.14 | 33.3 | 33.3 | 50.0 | 29.91 |
| Full-rate, first | 54.55 | 16.7 | 33.3 | 50.0 | 59.82 |
| Full-rate, second | 55.50 | 16.7 | 33.3 | 66.7 | 59.77 |

Both candidate captures have zero paused-control changes and zero OBS
render/encode drops. Audio is active; audio fidelity is not fully qualified.
Their mean character-change rate is about 83% higher than the two Beta 4
controls, under this detector and replay. The second source trace has a
16.76 ms median picture interval, 18.74 ms p95 and 31.24 ms maximum. Its one
66.7 ms visible hold is not a corresponding source-picture stall.

The launcher, supervisor expectation, accepted runtime fixture and launch
block test pin change together. All 45 existing launcher, preflight,
clock, video and recovery tests pass. All 851 tracked renderer/build inputs
remain identical to Beta 4. The previous renderer oracle and ARM self-test
results apply to the same retained binary; they were not rerun for this
configuration-only change. Earlier controller and offline RTC fixes remain
included. The separate beta launcher preserves the regular installation.

## Priorities after qualification

1. Target Castlevania's remaining polygon scanline and cached texture work.
   Select specializations outside the pixel loop where possible; require
   exact output and native NSMB/Mario Kart regression controls.
2. Optimize NSMB's measured extended/text background routines, preserving
   palette, VRAM and raw-write invalidation rules.
3. Reduce proven packet-intake or wakeup overhead without removing ownership
   checks, fences, ordering or bounded query responsiveness.
4. Consider broader geometry offload only after a measured cost/latency
   budget. The small matrix multiplication shares do not justify a
   matrix-only FPGA build for these scenes, and query latency outside the
   ARM acquisition/reply interval remains unmeasured.
