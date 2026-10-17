# Castlevania adaptive worker balance, 2026-10-17

Follow-up: the optimization series has ended at the [private freeze](PRIVATE_BETA_20261017.md). See the [final live worker-range comparison](CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md); the measurements and native decisions below remain historical evidence.

Private C51 diagnostics on the accepted Castlevania Beta11 renderer show that
the primary worker is usually slower while the adaptive controller is at its
44% minimum estimated work share. This supports testing a lower minimum for
the existing verified Castlevania USA rev0 profile. It does not establish a
performance gain or qualify a new beta.

| Measurement | Cave / bat | Warg combat |
| --- | ---: | ---: |
| Complete frame records | 433 | 116 |
| Frames at the 44% minimum | 423 (97.7%) | 107 (92.2%) |
| Frames with primary raster slower | 431 | 112 |
| Mean primary raster wall time | 14.019 ms | 13.883 ms |
| Mean secondary raster wall time | 11.147 ms | 11.404 ms |
| Mean raster wall time | 14.090 ms | 13.958 ms |
| Mean raster setup wall time | 3.924 ms | 3.816 ms |
| Mean inclusive 3D output wait | 21.006 ms | 20.787 ms |

These stages overlap and must not be added. Timers and diagnostic records
perturb scheduling. Work-share estimates are not CPU utilization, and published
picture pairs are not distinct animation frames. The 22-second cave sample and
six-second combat sample include short transitions back from the pause menu;
neither is a performance acceptance run.

The diagnostic helper was built from Beta11 with per-frame stage, applied-share
and split-line records. The full ARM service self-test and explicit profiling
self-test passed, with expected event counts and ranges; 851 build inputs were
checked and temporary source overlays restored. An initial local decoder
rejected the added event types after the cave recording. Its enum was updated,
the original recording was reanalyzed, and combat used a fresh fixture. Neither
recording had raced timeline lanes.

Both recordings had complete scene layers and normal pause/map transitions in
reviewed contact sheets, audio present, zero capture drops and zero protocol
faults. The original NSMB installation and save, 54 protected files, stock 1 GHz
clock and OBS settings were restored and checked; the restored NSMB menu was
visually verified. No public release or accepted-runtime change resulted.

Next experiment: permit a 35% lower work-share limit only for the matched
Castlevania profile, resetting timing history on profile transitions. Retain
the ordinary 44% limit, neutral 50% start, 80% upper limit, existing smoothing,
hysteresis, correction bound and worker completion fences. Require full-buffer
correctness, game controls and uninstrumented live comparisons before promotion.

Private evidence: `castlevania-adaptive-balance-profile-20261017`, including
`PROFILE_SUMMARY.json`, both `timeline.stages.json` files, `VISUAL_REVIEW.json`
and `FINAL_RESTORATION.json`. No game data is included in this report.
