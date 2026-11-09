# RC15 3D Off diagnostic — 9 November 2026

Turning off 3D pixel rendering substantially increases completed screen updates in the 3D-heavy scenes, but it does not accelerate Mario Kart’s race clock in the tested scene. Further resolution cuts are unlikely to fix that slow clock. Geometry processing, guest CPU execution, memory waits and synchronization remain candidates for the next investigation. This experiment does not distinguish those remaining causes.

All three modes use the same diagnostic binary, AA Off, the same FPGA and guest patches, and a 1 GHz host CPU. Values below are completed screen-pair publications per second; they include reused pictures and are **not unique animation FPS**.

| Scene | Native | Half Rows | 3D Off |
|---|---:|---:|---:|
| Mario Kart Figure-8 Circuit | 29.4 | 39.5 | 59.6 |
| Dawn cave | 31.7 | 36.3 | 59.6 |
| NSMB World 3 map | 16.0 | 22.9 | 59.6 |
| NSMB World 3 tower | 59.6 | 57.7 | 59.6 |

Mario Kart was stationary in a 50cc Figure-8 Circuit race with Mario/B Dasher. Native and Half Rows each have two windows; Off has three. The mode sequence included forward and reverse comparisons. The table averages those windows. The other scene/mode combinations each have one 30-second window.

For Mario Kart’s speed comparison, two screenshots were taken during uninterrupted play, approximately 5 and 25 seconds after resuming. This avoids the inconsistent pause/resume-transition contributions observed in the preliminary readings.

| Mode | Race seconds advanced | Wall seconds | Race-clock speed |
|---|---:|---:|---:|
| Native | 9.992 | 20.049 | 49.84% of real time |
| Half Rows | 9.989 | 20.027 | 49.88% of real time |
| 3D Off | 9.966 | 19.989 | 49.86% of real time |

Dawn’s whole-second play clock advanced 30 / 29 / 30 seconds in the Native / Half Rows / Off 30-second windows. NSMB’s tower countdown advanced 40 / 41 / 40 units between pauses; active 20-second samples advanced 26 / 27 / 27 units. These coarse counters do not establish small percentage differences or measure every aspect of gameplay. The map has no suitable game timer. Half Rows reduced tower screen updates by about 3.2%; Off provided no useful update-rate gain over Native in that scene.

The implementation samples a private host-owned control word at frame boundaries. Off bypasses texture preparation/coherence and pixel rasterization, returns transparent 3D pixels, and preserves geometry processing and normal renderer completion fences. Guest CPUs, 2D rendering and display capture continue running; capture receives the blank 3D result. Switching back invalidates reuse and sparse-clear history so a fresh normal image is rendered. No geometry-command dropping was added.

The separate diagnostic launcher is `Scripts > NDS_RC15_Zero3D`. Its Display menu offers `3D Resolution: Native / Half Rows / Off (test)`. Off is intentionally transient; restarting returns to a saved supported mode. Off removes the 3D scene and is a diagnostic, not a playable quality setting. Beta2 remains the accepted build.

Validation passed: host menu/control/persistence checks, helper self-tests, and 605 renderer cases across five scheduling modes, including transparent Off output, texture-change recovery, preserved polygon state and live transitions. All 16 admitted 30-second hardware windows had zero FPGA/HPS faults, stable session epochs, and the expected CPU frequency. Native visuals were restored after Off on the same Mario Kart session.

Two preliminary NSMB tower windows are excluded: the initial Start press occurred before the level was ready, so those windows measured the pause screen. Their files remain in the evidence directory. The corrected `ZST` windows require the pause-menu image before/after measurement and verify that it is absent from both active timer screenshots. No invalid tower values appear in the tables above.

Only fixed scenes and stationary characters were tested. There was one game session per title, using disposable save aliases. These results do not characterize whole games or prove the exact remaining bottleneck.

Runtime source commit: `fa786ce5aee813f5978c5f0ce118d0c25aa6d52e` on `experiment/zero-3d-20261109`.

Measured results (`RESULTS.json`) · Timer observations (`TIMER_OBSERVATIONS.json`) · Build identity (`BUILD.json`) · Harness notes (`HARNESS_NOTES.txt`)

Mario Kart Native (`ZM5nativebefore-main.png`) · Mario Kart Off (`ZM2offactive-main.png`) · Dawn Native (`ZD0nativeactive-touch.png`) · Dawn Off (`ZD2offactive-touch.png`)

Qualification files and a locally linked copy of this report are in the private `evidence/zero-3d-20261109` directory outside this source checkout.
