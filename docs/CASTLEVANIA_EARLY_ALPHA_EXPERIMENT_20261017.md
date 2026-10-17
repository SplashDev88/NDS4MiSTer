# Castlevania early alpha rejection experiment, 2026-10-17

The scalar transparency check was moved before depth/attribute reads in the existing Castlevania contiguous-texture fallback. Exact output checks pass, but physical Cortex-A9 measurements show higher rendering cost in both target rooms. The change is rejected; Castlevania Beta11 remains the accepted focused build. No full helper was built or installed for this candidate.

The hypothesis was that fully transparent pixels could avoid depth-buffer reads. The tested ordering instead reads texture/color before knowing whether a pixel is occluded. This is a possible explanation for the extra cost, not a separately established causal attribution. Opaque NEON groups, frame admission, clocks and the adaptive scheduler were unchanged.

## Native measurements

Six samples per build per scene were collected in baseline/candidate/candidate/baseline order at 1 GHz. Each sample uses 16 warmups and 100 renders. Both workers are available while the verified menu is temporarily stopped with a watchdog. Full color/depth/attribute hashes match in all 60 samples. Negative percentages mean less rendering time.

| Saved scene | CPU time change | Elapsed time change |
| --- | ---: | ---: |
| bat-live | +1.222% | +0.969% |
| combat-live | +0.798% | +1.365% |
| nsmb-castle | -0.231% | -0.327% |
| nsmb-castle-left | -0.561% | -0.388% |
| mario-kart-heavy | +0.671% | +0.114% |

Both target scenes fail the predeclared requirement for more than 1% lower elapsed rendering time. The control scenes stay within the 1% regression bound. These saved-scene measurements do not establish gameplay FPS; live gameplay trials are not warranted by this result.

## Correctness and limits

The isolated candidate translation unit was linked against the accepted Beta11 core library. It passed 1,536 alpha-reference cases against both the baseline and uncached renderer, 5,388 existing full-buffer raster cases, 48 scene snapshots, 320 serial/parallel snapshot comparisons and 384 synthetic scheduler comparisons with 192 deliberately delayed worker wakeups. Of the broad raster cases, 5,132 also match the independent uncached reference; 256 narrow-polygon compatibility cases retain existing baseline differences. Ten of the sequence snapshots are non-gameplay combat transitions. The inherited scheduler tests detect both profile policies and transitions.

The first compilation attempt duplicated an unchanged pragma-once header under two paths. The header was confirmed byte-identical and the private duplicate removed; the corrected build uses the single public header. No hardware was changed by that failed compilation.

The original runtime, NSMB save, 54 protected files, stock clock, menu affinity and OBS settings were restored. A fresh game-selection screenshot was visually checked. Candidate source and private evidence remain outside the release tree; no public release or new beta package was made.

Private evidence: `castlevania-early-alpha-investigation-20261017`.
