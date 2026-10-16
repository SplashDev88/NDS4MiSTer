# Raster edge performance — 16 October 2026

Baseline: Performance Beta 3, `dd0dc0ea88850175c5166eaba386653812dbe563`.
The selected ARM renderer extends the exact white-color modulation shortcut
to eligible polygon edges. A fixed Castlevania: Dawn of Sorrow USA combat
scene uses **4.22% less rendering CPU time**. Two NSMB views and the heavy
Mario Kart control are effectively unchanged. These are renderer CPU
measurements, not whole-game FPS gains.

## Selected change

When a textured modulate span has constant RGB 63/63/63 and polygon alpha 31,
its decoded texture color is already the exact shader result. Beta 3 uses
that identity in eligible cached interiors. This change also uses it for
generic top, bottom and side-edge pixels, while preserving texture alpha,
coverage, rejection, blending and both depth layers.

The additional pixel check sits inside the existing cached-texture branch.
An earlier placement before that branch slowed NSMB. The selected change is
12 lines in `GPU3D_Soft.cpp` and adds 32 bytes to the ARM helper. No FPGA,
geometry, clock, frame-admission or publication change is included. Previous
palette, publication, controller and offline RTC changes are retained.

## Profile and native measurements

A CPU-clock leaf profile of Beta 3's fixed Castlevania scene puts 66.13% of
samples in polygon scanline rendering and 19.09% in its neutral-white cached
interior. Inspection of hot instructions identifies remaining generic-edge
color multiplication as a candidate. Profiling includes small startup costs
and is used to locate work, not as acceptance timing.

Acceptance runs on the physical Cortex-A9 at stock 1 GHz. The standalone
session is cleanly stopped, MENU's unchanged main thread stays on CPU1, and
the benchmark runs on CPU0. Each process warms up 16 renders and times 100
renders without profiling. Baseline/candidate/candidate/baseline ordering,
with three samples at each position, gives six samples per binary and scene.
The prior clock state and all protected files are checked after completion.

| Fixed scene | Beta 3 CPU ms/render | Selected CPU ms/render | Change |
| --- | ---: | ---: | ---: |
| Castlevania combat, 614 polygons | 38.549 | 36.922 | −4.22% |
| NSMB castle, 384 polygons | 12.110 | 12.076 | −0.28% |
| NSMB castle left, 384 polygons | 11.865 | 11.859 | −0.05% |
| Mario Kart heavy, 1,226 polygons | 35.921 | 35.820 | −0.28% |

Castlevania's ranges do not overlap: 38.326–38.705 ms for Beta 3 and
36.863–37.027 ms for the selected renderer. The other ranges overlap; those
small differences are not established improvements. Every timed sample
preserves the same native color, depth and attribute hashes as the baseline.
The private GPU-only fixtures execute no ROM or emulated CPU and are not
distributed. Live dual-core pipeline time can differ from this isolated test.

## Correctness and rejected approaches

The complete ARM service self-test passes. All 1,414 synthetic raster cases
match both the generic uncached path and separate Beta 3 binary, including
384 white-color cases, clamp/repeat/flip modes, varying depth, texture alpha,
translucency, antialiasing and both native layers. The existing exhaustive
neutral-modulation identity test remains applicable; its arithmetic is
unchanged. No approximate arithmetic or visual-quality reduction is used.

Game-specific selection was investigated after user authorization. The
experimental selector matched the tested ACVE revision-0 header fingerprint
and defaulted safely on other identities, failed/torn reads and reloads.
Its identity tests passed, but its renderer implementations did not meet the
speed requirement:

| Rejected experiment | Castlevania CPU change | NSMB CPU change | Mario Kart CPU change |
| --- | ---: | ---: | ---: |
| Shared check before cached-texture branch | −5.05% | +1.18% | −0.60% |
| Two compiled raster implementations | +0.94% | +5.44–5.64% | +0.92% |
| Compact game-specific gate | −4.07% | +1.63–2.22% | +1.88% |

Both game-specific variants also passed 1,414 rendering cases in each mode.
They were rejected for performance. The selected beta uses the measured
shared implementation; the experimental selectors and duplicated functions
are excluded. These results concern those implementations, not all possible
game-specific tuning. Future profiles still need native regression checks.

## Capture calibration

The automatic macOS OBS 720p capture preset was recording only 30 distinct
updates per second. Requesting exactly 60/1 FPS caused the capture plugin to
fall back to 50 FPS, because the device advertises 60.00024 FPS. Manual
1280×720 NV12 with its exact advertised duration fixed that limitation.

Original test programs display a known six-bit color counter once per DS
VBlank, or once per two VBlanks. Published pixel/counter observations and
physical RetroTINK recordings distinguish source updates from capture repeats.
The corrected full-rate run records 59.57 distinct updates/s with zero OBS
render/encode skips, versus 30.00 before. The half-rate control reads 29.93
updates/s. Each window is about 14 seconds. A few repeated or missed states
remain in the complete chain, so this is not a frame-perfect latency meter.
Older 30 Hz recordings cannot establish a game's own unique-frame rate.

## Live validation

Four unprofiled NSMB World 2-5 runs use control/candidate/candidate/control
ordering, 125-second quiet windows, stock 1 GHz and isolated save copies.
The control advances 344 HUD units in 258.412 seconds; the candidate advances
343 in 258.266 seconds. The combined rate difference is −0.234%, a single
count within integer HUD sampling uncertainty. No slowdown is detected in
this scene. Every run has zero core/helper fault words and unchanged saves.

Control and candidate jump recordings through analog RGB, RetroTINK-4K and
the calibrated USB capture show ordinary gameplay, active audio, and zero
OBS render/encode skips. Motion phases differ between recordings; these
bounded compatibility checks do not establish a whole-game FPS improvement.

Both builds complete Castlevania's menu and touch-name entry, then a short
prologue combat sequence with movement, attacks and the Skeleton soul pickup.
The in-game clock advances from 00:00:31 to 00:00:39 on the control and
00:00:38 on the candidate. Enemy states and positions differ, so these runs
qualify compatibility rather than matched combat speed. Both have zero
core/helper fault words, unchanged isolated saves, active captured audio and
zero OBS render/encode skips. Audio fidelity and full playthroughs are not
qualified by these short checks. All 53 protected paths remain unchanged.

## Private beta

Performance Beta 4 contains the selected shared ARM shortcut. Its helper
SHA-256 is `a39c7236202a639113e1a8190bc698521e104d94a1a7fc1edee60d7841347ce9`.
It retains the previous beta's host, FPGA image and runtime settings, including
the controller and offline RTC fixes. No new per-game selector is included.
The source change does not establish FPGA timing closure, sustained combat
FPS or a gain in every game.
