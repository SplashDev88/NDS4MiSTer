# Castlevania adaptive range experiments, 2026-10-17

Follow-up: the optimization series has ended at the [private freeze](PRIVATE_BETA_20261017.md). See the [final live worker-range comparison](CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md); the measurements and native decisions below remain historical evidence.

The first lower-bound experiment, C52, is rejected. Allowing the verified
Castlevania profile to reduce its primary worker share from 44% to 35% did not
improve the cave snapshot and increased combat rendering wall time by 1.679%.
The accepted private beta remains Castlevania Beta11.

The change retained the existing feedback controller, 50% initial share, 80%
upper bound, smoothing, hysteresis, per-frame correction limit and worker
completion fences. Only the verified Castlevania profile received the wider
range; profile transitions reset the controller's timing history. Ordinary
games retained the 44% lower bound and their existing scheduler selection.

| Native saved-scene control | CPU cost change | Wall-time change |
| --- | ---: | ---: |
| Castlevania cave | +0.746% | -0.041% |
| Castlevania combat | +1.951% | +1.679% |
| NSMB castle | -0.081% | -0.294% |
| NSMB castle, left | +0.091% | +0.153% |
| Mario Kart heavy scene | +0.398% | +0.478% |

Lower is better. These are medians from six samples per build and scene,
60 samples total, at stock 1 GHz with the stopped Main menu pinned away from
the renderer. Complete output hashes matched. Saved-scene rendering is not
gameplay FPS and omits live packet contention. The declared gate allowed
neutral target performance but no CPU or wall-time increase above 1%; combat
failed it. No live candidate kit was installed or packaged.

Correctness passed: full ARM service self-test; 851 build-input correspondence
checks and source-overlay restoration; 320 complete saved-scene buffer
comparisons; 384 synthetic scheduler buffer comparisons with 192 actual
delayed worker wakeups; and 384 additional complete-buffer comparisons at the
range extremes and across profile transitions. Deterministic controller
checks covered step bounds, reset/history behavior, repeated profile selection,
both limits and convergence under an estimated cave workload. An initial
test-only duplicate entry point was corrected before qualification; the
runtime helper was unchanged.

The original NSMB core and save, all 54 protected files, CPU clock and menu
affinity, and OBS settings were restored. A fresh NSMB menu screenshot was
visually checked. The rejected runtime remains private evidence only.

The narrower C53 trial is also rejected. C51's inferred balanced shares were
approximately 38.4% in the cave and 39.7% in combat, assuming cost proportional
to the estimated work share. C53 therefore tested a 40% minimum with the same
gates and recorded the final applied share outside the timed benchmark loop.

| C53 native control | CPU cost change | Wall-time change |
| --- | ---: | ---: |
| Castlevania cave | +0.510% | +0.381% |
| Castlevania combat | +1.208% | +1.281% |
| NSMB castle | +0.243% | +0.506% |
| NSMB castle, left | +0.130% | +1.051% |
| Mario Kart heavy scene | +0.291% | -0.125% |

The same correctness qualification passed, but combat and the NSMB-left
wall-time control exceeded the declared limit. Final Castlevania shares
usually remained above the old 44% floor in these isolated native samples;
they do not reproduce the sustained floor saturation of the live diagnostic.
Consequently the native results do not prove that a lower bound can never help
live contention, but they do not justify promoting either implementation.
No live C53 kit was installed or packaged.

C53 restoration passed after correcting a copied local verifier's mistyped
expected save digest against the original setup evidence. The actual save
digest was unchanged throughout; no save restore or rewrite was needed.
The original NSMB menu was visually checked. The copied unused live-kit
scripts' literal digests were also corrected; native output hashes had been
computed and compared dynamically and were unaffected.

Private evidence: `castlevania-adaptive-range-performance-20261017` and
`castlevania-adaptive-range40-performance-20261017`, including
`TECHNICAL_QUALIFICATION.json`, `NATIVE_REVIEW.json`, `DECISION.json` and
`FINAL_RESTORATION.json`. No game data is included in this report.
