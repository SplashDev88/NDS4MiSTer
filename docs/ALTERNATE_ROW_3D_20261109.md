# Alternate 3D row experiment, 2026-11-09

This opt-in renderer draws the even 3D rows and duplicates them vertically before
native 2D composition. It increases picture throughput in the tested slow scenes,
with visible loss of vertical detail. It does not demonstrate faster game clocks
and is not proposed as a new default. The NSMB tower is a regression case.

## Measured screen-pair publications per second

All arms use AA off, the same frozen RC15 FPGA/host/guest catalog, and the release
1 GHz runtime setting. Frozen RC15 is independently controlled to detect changes
caused by rebuilding or code layout. Each candidate mode was launched twice per
game with opposite ordering in the repeat round. Mario Kart has two 30-second
windows per launch; Dawn has one; NSMB has separate map and tower windows.

| Scene | Frozen RC15 | Candidate native | Candidate half rows | vs same binary | vs frozen |
|---|---:|---:|---:|---:|---:|
| DAWN | 32.00 | 31.96 | 36.62 | +14.6% | +14.4% |
| MKDS | 29.03 | 28.92 | 38.99 | +34.8% | +34.3% |
| map | 16.07 | 16.01 | 22.98 | +43.5% | +43.0% |
| level | 58.28 | 58.16 | 55.73 | -4.2% | -4.4% |

These are completed screen-pair publications, not unique animation FPS. The
static camera/position controls isolate repeatable rendering work; they do not
establish whole-game performance. Before, active, and after native framebuffers
were reviewed. All 25 timed windows had zero FPGA/HPS faults and stable process
and session identities. All 15 admitted sessions exited cleanly.

## Game progress and image quality

The exact per-launch timer observations are in the adjacent result JSON. Dawn
uses coarse whole seconds, Mario Kart uses its race timer, and the NSMB tower
uses integer countdown units. The map has no suitable game timer. Timer behavior
does not establish gameplay acceleration. Mario Kart still advances about 32
race seconds during 60 wall seconds despite the higher picture count.

The 3D scenery and characters are visibly coarser, including Dawn's sprite-like
3D geometry, Mario Kart's road/kart/fence, and NSMB's world map. Native 2D labels,
menus, HUDs, and secondary-screen composition remain sharp. Thin geometry can
vanish or flicker when it falls only on an omitted row. The tower result makes
this an explicit, scene-dependent quality/performance tradeoff.

The conservative prototype copies complete rows and marks duplicated rows fully
dirty. That extra copy/clear work is a plausible explanation for the tower loss;
it has not been isolated as its cause. A future experiment could duplicate only
proven dirty spans, with full-row fallback for image clears/fog and independent
native-buffer oracles. This version remains frozen for the reported comparisons.

## Implementation and verification

The flag `NDS4MISTER_ALTERNATE_3D_ROWS=1` is sampled into renderer-owned state.
It is admitted only for complete-frame consumers when effective AA is disabled.
AA-enabled frames and legacy scanline consumers retain native rendering.
Skipped rows still process polygon membership, edge setup/steps, and the shadow
ordering carry flag. After all raster workers join, sampled color/depth/ID rows
are expanded for edge/fog processing; completed colors are expanded again before
the complete-frame fence permits 2D reads. Mode changes invalidate identical-frame
reuse and raster cost history. Dirty bounds cover cancellation and the return to
native resolution.

The ARM hard-float Release/LTO/RC15-PGO service self-test passes. An independent
oracle first renders every native row, then samples/expands that plane. The 515
cases cover five scheduling configurations, textures, fog, edge marking,
translucency, shadows, sparse/empty/repeated frames, AA transitions, cancellation
recovery, forced X-partition ownership, and Dawn's prepared rectangle path.
Only visible top-layer color/depth/attributes are compared for deliberately
omitted rows; the ordinary service suite retains native full-buffer checks.

Runtime source: `b77c0335aff9481940fd31e13e87e9055f23d746`.
Helper SHA-256: `5253686bf17856fabc03c6dc91de7fd4f09fb54f8522f97ae2403263f97c5331`.
Test-only additions are pinned in the build receipt. The frozen RC15 AA Beta1
ZIPs and installed inventory are separately reverified after hardware testing.

## Evidence and private packaging

The workspace evidence directory `evidence/alternate-row-3d-20261109` contains
the predeclared plan, build/test logs, all raw measurement windows, mode/hash
receipts, native screenshots, timer observations, existing-recorder pacing dumps,
clean-exit receipts, and restoration checks. The native flight recorder is an
observer; draw intervals include asynchronous waits and are not CPU percentages.

Two initial harness problems were corrected before admitting candidate data:
a missing copied reference PNG stopped Dawn before timing; an obsolete private
supervisor helper pin rejected a candidate launch before loading the core. The
rejected launch is retained in the plan. A build storage failure was resolved by
removing only untracked, reproducible Quartus caches from completed experiments;
source, bitstreams, reports, release archives, and evidence were preserved.

The optional package provides separate Native Control and HalfRows Test launchers,
sharing the tested candidate binary and a separate settings directory. RC15 AA
Beta1 remains untouched. Use AA off for comparisons. No public release or push
is part of this experiment.
