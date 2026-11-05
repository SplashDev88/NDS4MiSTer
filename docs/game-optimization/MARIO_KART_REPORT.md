# Mario Kart DS — all-course private beta

Course Beta 3 investigates all 32 racing tracks and applies guarded in-memory
resource optimizations to 31 courses in the owned USA AMCE revision 0 ROM. It is ready for private testing after bounded
reference and native qualification. Human audiovisual approval is pending. Sky Garden retains its original course
resource, but the shared helper still showed a roughly 0.85–4.07% native timer
slowdown in isolated checks. It is a documented beta limitation, not a claimed
optimization or timing-equivalent result.
No public release, FPGA, host binary, renderer, clock or save-state format changed.

## What changed

The game avoids submitting complete static geometry spans that are conservatively
outside the view. Eligible independent triangle/quad lists use per-track grouping
chosen using both native output rate and game-timer advancement. Smaller groups
can save renderer work while adding too much guest-CPU work; those tradeoffs are
rejected when they slow game progress. Rendered vertices retain their original coordinates
and attributes; unsupported normal/state shapes and strips stay intact.
The selected shared helper is `normalized`. Code and every resource are
admitted together under full ROM, header, ARM9-section, original-byte and asset
hash guards. Any mismatch returns the original virtual cartridge stream.

The existing VirtualRom preparation and normal boot/resource loading mechanisms
install the changes. No original ROM file is written. The helper occupies the
existing guarded OAM function/literal extent (916 bytes),
uses the normal stack and existing game routines, and introduces no HPS call.
No overlay code is patched. Dynamic/static decoded instruction visibility follows
the normal reset and boot-load path; no late live-code patch is introduced.

Verified prepared resources are cached in the existing bounded local store.
The full original ROM is still authenticated on every load, and each cached output
must match its expected hash. First uncached preparation of all 32 resources took
700.745 seconds on the MiSTer; a verified cached launch took 27.409 seconds.
These are loading measurements, not gameplay gains. Derived cache data stays local
and is excluded from the beta ZIP.

## Measured native results

Each row describes a fixed Time Trials starting view at 1 GHz. Baseline rates pool
opening and closing control windows for 29 unchanged resource recipes. The three
amended courses have two matched-order control/candidate repeats; course history
affects output rates, so their individual windows are retained. Every track has
a native confirmation window. These are completed screen-buffer publications per second,
not unique animation FPS, game-clock speed, or full-race throughput. The rig does
not provide reliable native per-frame CPU-cycle or frame-time percentile data. Small differences
must be interpreted with the recorded control drift and repeat checks.

| Track | Recipe | Baseline pub/s | Beta pub/s | Change |
| --- | --- | ---: | ---: | ---: |
| Figure-8 Circuit | normalized | 21.06 | 23.86 | +13.33% |
| Yoshi Falls | normalized | 17.24 | 19.84 | +15.07% |
| Cheep Cheep Beach | normalized | 19.73 | 21.27 | +7.82% |
| Luigi's Mansion | split8 | 12.49 | 13.04 | +4.45% |
| Desert Hills | normalized | 17.26 | 19.88 | +15.17% |
| Delfino Square | split8 | 19.42 | 20.17 | +3.88% |
| Waluigi Pinball | normalized | 18.11 | 18.65 | +3.02% |
| Shroom Ridge | normalized | 13.19 | 16.64 | +26.23% |
| DK Pass | normalized | 17.03 | 19.53 | +14.65% |
| Tick-Tock Clock | split8 | 21.88 | 26.62 | +21.64% |
| Mario Circuit | split8 | 22.58 | 25.67 | +13.66% |
| Airship Fortress | group2 | 12.59 | 13.55 | +7.61% |
| Wario Stadium | normalized | 19.60 | 22.66 | +15.62% |
| Peach Gardens | normalized | 19.27 | 20.23 | +4.94% |
| Bowser's Castle | normalized | 12.92 | 13.24 | +2.49% |
| Rainbow Road | normalized | 14.19 | 16.99 | +19.70% |
| SNES Mario Circuit 1 | normalized | 28.42 | 30.77 | +8.24% |
| N64 Moo Moo Farm | normalized | 20.11 | 23.39 | +16.30% |
| GBA Peach Circuit | normalized | 28.51 | 30.22 | +6.01% |
| GCN Luigi Circuit | normalized | 19.98 | 21.68 | +8.50% |
| SNES Donut Plains 1 | normalized | 26.07 | 30.01 | +15.09% |
| N64 Frappe Snowland | normalized | 24.05 | 29.86 | +24.15% |
| GBA Bowser Castle 2 | split8 | 26.64 | 29.43 | +10.47% |
| GCN Baby Park | normalized | 20.71 | 21.18 | +2.26% |
| SNES Koopa Beach 2 | normalized | 22.90 | 28.38 | +23.95% |
| N64 Choco Mountain | normalized | 18.51 | 22.44 | +21.20% |
| GBA Luigi Circuit | split8 | 25.52 | 27.94 | +9.47% |
| GCN Mushroom Bridge | split8 | 16.21 | 19.07 | +17.61% |
| SNES Choco Island 2 | normalized | 22.61 | 25.67 | +13.54% |
| N64 Banshee Boardwalk | split8 | 19.69 | 21.37 | +8.55% |
| GBA Sky Garden | original | 22.28 | 22.54 | not claimed |
| GCN Yoshi Circuit | normalized | 17.85 | 22.51 | +26.11% |

Across the 31 transformed-course resources, the arithmetic mean of scene-specific relative gains is
12.93%. The modified-course range is
+2.26% to +26.23%; this is not a whole-game speedup. Sky Garden is listed for
regression coverage and is excluded from these optimization-gain summaries.
A bounded Delfino Square screenshot cross-check shows essentially unchanged race-clock
advancement over the standardized active interval (23.155 versus 23.145 seconds).
The measured delivery gains are not claims of accelerating the race clock or physics.
See `ALL_TRACK_FINAL_NATIVE_V2.json` and `FINAL_QUALIFICATION_REVIEW_V1.json` in the
private evidence directory for windows, control drift, CPU loads and follow-ups.

## Validation and limits

- All 32 tracks have independent geometry/matrix screening and paired short replays.
  The matrix proof covers 519 shapes and 467,100 observed calls without mismatch.
- Baseline and split-span CPU-driver references completed 64 races and 196 normal
  laps. Final mixed-candidate coverage and its reviewed results are recorded in
  `ALL_TRACK_ADMITTED_LONG_REVIEW_V1.json` and the qualification receipt. The timing correction
  changed three resources; their targeted full races replace earlier results,
  while 29 unchanged resource recipes retain their completed coverage.
- Full-race fixture coverage exercises the track route and results screen; it is
  not normal player behavior. Both private menu-unlock and CPU-driver patches are
  removed from the release manifest and verified absent from the final stream.
- Supplemental normal Grand Prix replays cover eight racers. A newly written
  private record save is reopened through the actual release-form patch set.
- Loader tests, generated-code ABI/visibility checks, code write watches, actual
  package extraction/launcher checks and protected-original audits accompany the beta.
- Sky Garden remains a timing exception even with original course data: isolated
  normal-helper timer changes were -4.07% and -0.85%. Its 14,000 compared reference
  frames and save match the control, but raw audio does not. The existing fast
  dispatcher improved those timer measurements by only 1.09% and 0.009% relative
  to the selected helper and did not reliably repair the cost. The regular
  released launcher remains available for comparison.
- Raw timing, RAM, screen and audio output can differ from stock. AI trajectories
  and record times differ in some CPU-driver fixtures. Matching sampled scenery
  does not prove inaudibility or complete gameplay equivalence.
- Multiplayer, every battle/mission mode, long sessions and other regions/revisions
  are not qualified. Save states remain unsupported. Only the full verified USA
  revision is admitted; region addresses are never substituted blindly.

## Options investigated

Three resource recipes were measured on all 32 courses. A fourth grouping was
examined specifically for Sky Garden. None of its tested recipes preserved native
progress well enough, so Sky Garden retains its original resource. Native HUD-clock checks rejected apparent
output gains that slowed gameplay: Airship Fortress split spans advanced only
11.566 seconds against 23.199 control seconds. Pinball and Sky Garden also needed
less aggressive settings. The admitted selection prioritizes native game progress
alongside output rate. Larger groups remain useful when they reduce guest overhead. Shared-helper trials compare
unrolled bounds checks, a cheaper ordinary-list dispatch, the existing DMA threshold,
adjacent visible-payload batching and their bounded combination. The final selection
and rejected variants are preserved in `ALL_TRACK_FINAL_SELECTION_V3.json` and
`NATIVE_REFINEMENTS_RESULT_V1.json`. No removed lighting, precision reduction,
frameskip, audio disabling or overclock was used.

The previous FIFO, ARM7, material, coordinate and two-course investigations remain
in [the historical log](MARIO_KART_PRIOR_INVESTIGATIONS.md). This beta represents the
best confirmed combination within this investigation, not proof of a global optimum.

## Three remaining research ideas

1. Profile Sky Garden's residual ordinary-list and cross-course timing costs.
   Four resource granularities and the existing fast dispatcher did not establish
   a reliable repair; its original resource remains the best admitted choice.
2. Cache composed course visibility matrices only after proving live invalidation,
   ownership and enough guarded code/data space. Endpoint matches are insufficient.
3. Extend conservative visibility to dynamic or lit models after qualifying their
   animation, normal, matrix-stack and state dependencies.

None has an admitted patch or proven gain here. A new HPS service, RTL change,
new save-state format or unproven memory allocation requires separate review.

## Reproduction and evidence

Manifest: `mario-kart-amce-r0-all-course-spans.json` (packaged as
`MARIO_KART_MANIFEST.json`). Build the pinned helper with
`tools/game_optimization/build_course_span_guest.py`; compiler output must match
its expected hash. Generic parsers and asset adapters contain no game addresses.
The pattern library records geometry selection, format/scale handling, visibility
normalization, submission batching, guarded routine reuse and preparation caching.

Owned ROM SHA256: `0ea8a91a0ae3e9db26337c25a6a8568f6737fa36c1e0761988c0fa0ecbf210ed`.
Header SHA1: `a804fde97be47f0d7ac06bbf966d342b07daecbb`. No ROM, BIOS, save, derived course assets or cache
payloads are included in the distributable. Private evidence lives in
`evidence/mario-kart-optimization-20261104` in the testing workspace.

## Regional Beta4 coverage

The USA Course Beta3 results above are unchanged. Exact revision-0 Europe, Japan
and Korea ports, their independent measurements and limits are documented in
[MARIO_KART_REGIONAL_REPORT.md](MARIO_KART_REGIONAL_REPORT.md) and
[MARIO_KART_VERSION_COVERAGE.md](MARIO_KART_VERSION_COVERAGE.md). The older USA-only
qualification statements above describe the original campaign, not the expanded
private catalog.
