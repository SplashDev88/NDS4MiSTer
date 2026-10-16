# Polygon color performance experiment — 16 October 2026

The selected ARM change checks whether every vertex of a polygon has the
same final color, then reuses that exact color along both edges instead of
repeating six interpolation checks on every scanline. The fixed Castlevania
Dawn of Sorrow combat snapshot takes about 1.6% less renderer CPU time than
Performance Beta 5. Bounded gameplay checks below pass; this is not a
whole-game FPS claim.

## Selected change

`SetupPolygon` computes one boolean from all three full-precision final
color components of every vertex. `RenderPolygonScanline` uses that boolean
to reuse the vertex values. Other polygons retain the existing edge
interpolation. Equal endpoints already return the original value in the
reference interpolator, regardless of depth, perspective or span length.
The subsequent horizontal interpolation, texture sampling, coverage, depth
tests and blending remain unchanged.

The candidate retains Beta 5's full-rate NSMB admission setting, earlier
palette/publication/raster improvements, controller mapping and offline RTC
fallback. It changes neither FPGA logic nor the host executable or clocks.

## Exact-output and native checks

The complete ARM service self-test passes under the bundled execution
runtime. All 1,414 existing raster cases match the uncached reference
path and Beta 5's saved color, depth and attribute hashes. These cover flat
and varying color, W/Z buffering, perspective/linear spans, texture modes,
translucency, depth changes and edge handling.

Native timing uses the MiSTer's Cortex-A9 at 1 GHz with normal MENU on CPU1
and the single-threaded snapshot renderer on CPU0. Each sample renders the
same private GPU snapshot 100 times after 16 warmup renders. Three samples
at each position in control/candidate/candidate/control order give six
samples per binary per scene. CPU time excludes process startup; outputs
must remain identical. The prior clock policy and protected files are
verified after the benchmark.

| Fixed scene | Beta 5 median CPU ms | Candidate median CPU ms | Change |
| --- | ---: | ---: | ---: |
| Castlevania combat, 614 polygons | 36.911 | 36.329 | −1.58% |
| NSMB castle, 384 polygons | 12.092 | 11.971 | −1.00% |
| NSMB castle, left view, 384 polygons | 11.875 | 11.744 | −1.11% |
| Mario Kart heavy, 1,226 polygons | 35.990 | 35.789 | −0.56% |

The Castlevania and NSMB candidate sample ranges are below their control
ranges. Mario Kart's ranges overlap, so its small median difference is not
claimed as an established improvement. These are repeatable rendering
workloads, not sustained game-speed, displayed-FPS or input-latency tests.

## Rejected additional texture-row shortcut

A second prototype also hoisted constant texture-row addressing and skipped
its unchanged T interpolation. It passed the full service self-test and an
expanded 1,990-case raster comparison, including 576 additional neutral
constant-row cases across six texture formats, wrapping modes, depth modes,
perspective, translucency and transparent holes.

Its separate native comparison showed Castlevania −1.82%, NSMB castle
+0.08%, NSMB's left view +0.60%, and Mario Kart −0.28% versus Beta 5.
The additional Castlevania benefit over the simpler prototype was small
and not established by a direct paired comparison; it also gave back the
NSMB gains. This prototype is excluded from the selected candidate.

## Gameplay qualification

The World 1 castle entrance uses the existing isolated NSMB save and normal
map inputs. Repeated jumps are recorded through the calibrated RetroTINK-4K
analog capture chain, with separate 125-second quiet timer observations.
No ROM patches or original user-save changes are needed. All tested builds
retain 1 GHz ARM clocks. Each trial begins from the same copied save.

| Build | HUD countdown | Actual seconds | HUD units/s |
| --- | ---: | ---: | ---: |
| Beta 4 half-rate, first | 471 → 378 | 129.313 | 0.71919 |
| Beta 5 full-rate | 471 → 370 | 129.986 | 0.77701 |
| Candidate full-rate | 470 → 367 | 130.181 | 0.79121 |
| Beta 4 half-rate, repeated | 471 → 378 | 129.600 | 0.71759 |

The repeated half-rate control gives the same 93-unit countdown progress.
These runs show no candidate game-clock slowdown. Integer HUD samples
have roughly one tick of endpoint uncertainty; they do not establish the
candidate's small apparent improvement over Beta 5. The castle remains
slower than the previously tested outdoor scene.

The 22-second character-region detector gives 30.18, 27.82, 28.23 and 29.91 visible
changes/s respectively. Threshold sensitivity and paused controls matter:
the primary detector has 1, 0, 1 and 1 paused false changes across 90 comparisons.
The earlier outdoor motion improvement does not generalize numerically to
this castle. These measurements are not total emulator or geometry FPS.
The candidate source trace records 44.59 completed picture pairs/s; this is
also distinct from meaningful visible changes. Its picture-interval p95 is
31.20 ms and maximum 41.90 ms. All four recordings have zero OBS render or
encode drops, active audio, unchanged isolated saves and zero fault words.
Audio fidelity and full playthroughs are not qualified.

Beta 5's optional diagnostic timeline contains one concurrently changed
record and is excluded from source-stage and cadence claims. Its physical
capture, timer, scheduler totals and health checks remain valid. Helper CPU
usage over the input replay is 1.14 cores for the first half-rate control,
1.37 for Beta 5 and 1.37 for the candidate, including paused margins.

Normal play additionally exercised scrolling, rope platforms, fireball
effects, moving lava platforms and two normal death/restart transitions.
The route attempt reached roughly the first quarter of the castle but did
not reach the boss. Boss behavior and full-level performance remain
unqualified. No ROM or game-state shortcuts were used.

The selected helper also passed the Dawn of Sorrow intro combat replay,
including attacks, enemy defeat, effects, the Golem appearance and screen
peek. Physical capture was visually reviewed; audio was active, saves were
unchanged, fault words were zero and OBS reported no dropped frames. The
screen detector recorded 16.95 visible changes/s at the existing conservative
threshold, with zero paused-control changes. This compatibility run is not
a matched causal FPS comparison: enemy outcomes and timing can vary between
replays. The fixed-snapshot timings above establish the renderer CPU gain.

## Remaining work

- Reach and qualify the NSMB castle boss and longer gameplay sessions.
- Target remaining Castlevania scanline work with exact-output controls;
  avoid speculative texture shortcuts that cost other games performance.
- Profile NSMB's current full-rate 2D path before changing background work.

The candidate retains the earlier controller and offline-clock fixes and is
qualified as a separate private experimental beta, not a public release.

[Previous calibrated capture and ARM profiles](GAMEPLAY_PACING_PROFILE_20261016.md)
