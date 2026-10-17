# Final live worker-balance experiment — 17 October 2026

Decision: **PROMOTE_PRIVATE_FREEZE**. The 40% Castlevania-only worker range passes both live target gates and the NSMB regression control; inherited native snapshot costs remain disclosed. This exact qualified helper is selected for the freeze.
The optimization series stops here at the user's request. The selected frozen
runtime is **Castlevania Beta12 (C55 worker range)**; see [private beta](PRIVATE_BETA_20261017.md).

## Hypothesis and scope

C51 found the Beta11 primary raster worker at its 44% lower work-share bound in
97.7% of cave and 92.2% of combat frames, usually completing later than CPU1.
The already correctness-qualified C53 binary allows a 40% floor only for the
verified Castlevania profile, resets its timing history on profile transitions,
and retains the 50% start, 80% ceiling, EMA, hysteresis, correction bound and
completion fences. Other games retain the 44% range and their existing policy.
Only GPU3D_Soft.cpp and GPU3D_Soft.h differ from Beta11 runtime sources.

This is a new live-contention follow-up of the exact C53 helper, not a new build
or an erasure of its native rejection. The prior native costs remain: cave CPU
+0.510% / wall +0.381%; combat +1.208% / +1.281%; NSMB-left wall +1.051%.
Saved-scene tests generally finished above the old 44% bound, unlike live runs
where intake and rendering contend. That difference justified a separately
predeclared live gate; the earlier native result is not relabeled as a pass.

## Live observations

Fresh isolated suspend copies, baseline/candidate/candidate/baseline order,
stock 1 GHz ARM, identical core/host/runtime flags, packet NC disabled. Cave
windows are 22 seconds, combat six and NSMB 26 with repeated jumping. Analog
RGBS passes through RetroTINK-4K into the unchanged capture rig. No CPU sampler,
GPU snapshot or heavy build runs in the measurement windows.

| Scene | Beta11 pairs/s | 40% candidate pairs/s | Change |
| --- | ---: | ---: | ---: |
| BAT | 22.0859 | 22.6365 | +2.493% |
| FIGHT | 21.4830 | 21.8774 | +1.836% |
| NSMB | 44.3764 | 44.8448 | +1.055% |

The predeclared gate requires >1% mean gain in both target scenes and NSMB
change at least -1%, plus graphics, protocol, save, clock and capture checks.
This is an engineering gate, not a statistical confidence interval. Both cave
candidate samples exceed both baselines. Combat enemy phases/damage vary;
consult the individual samples rather than treating a short mean as exact speed.
Combat starting HP is 99/112/108/103 in run order; the last baseline has EXP70
versus EXP69 in the other runs. NSMB starts at timer495 in the first pair and
496 in both repeats, ending at474 throughout. All remain in the analysis.

| Run | Publication pairs/s | Median interval, ms | p95, ms | Maximum, ms |
| --- | ---: | ---: | ---: | ---: |
| C55_BAT_BASE | 21.9461 | 44.145 | 53.834 | 60.309 |
| C55_BAT_CAND | 22.6172 | 42.544 | 53.364 | 58.990 |
| C55_BAT_CAND_REPEAT | 22.6559 | 42.319 | 53.395 | 58.057 |
| C55_BAT_BASE_REPEAT | 22.2258 | 43.795 | 54.121 | 60.724 |
| C55_FIGHT_BASE | 21.0478 | 47.358 | 59.136 | 64.842 |
| C55_FIGHT_CAND | 21.7069 | 46.142 | 57.759 | 63.796 |
| C55_FIGHT_CAND_REPEAT | 22.0480 | 45.798 | 57.371 | 68.483 |
| C55_FIGHT_BASE_REPEAT | 21.9181 | 45.169 | 58.819 | 68.735 |
| C55_NSMB_BASE_CLEAN | 44.2213 | 23.104 | 30.851 | 40.842 |
| C55_NSMB_CAND_CLEAN | 44.4833 | 23.162 | 30.952 | 42.671 |
| C55_NSMB_CAND_REPEAT_CLEAN | 45.2063 | 23.142 | 30.917 | 44.469 |
| C55_NSMB_BASE_REPEAT_CLEAN | 44.5316 | 23.212 | 30.632 | 38.308 |

Both candidate target-scene p95 intervals are below their baselines. NSMB p95
is slightly higher (30.917–30.952 ms versus 30.632–30.851 ms), as are its observed
maxima (42.671–44.469 ms versus 38.308–40.842 ms). The control passes the declared
throughput gate but does not demonstrate uniformly better tails.

These are source publication pairs, not distinct displayed animation FPS.
The 60 fps objective remains unmet. Tail intervals do not prove input latency
or audio quality. Raced timeline records are excluded from interval analysis;
independent stable header counts remain the rate source. No valid runs were
silently discarded. All 12 accepted recordings were visually reviewed; complete
scene graphics and audio are present, with zero OBS render/encode drops and zero
FPGA/HPS fault words. All 54 protected files and measured saves are unchanged.

## Correctness and provenance

Exact reused helper SHA-256:
`5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8`.
All 851 source inputs were rechecked against the qualified C53 build before
hardware use. Its Docker full-service self-test, 320 complete snapshot buffers,
384 synthetic scheduler buffers and 384 range/transition buffers pass, including
192 actual delayed worker wakeups. These are inherited C53 correctness results;
they are not claimed as a second full build. The freeze record distinguishes
any freshly qualified public test from these inherited checks.

The first C55 orchestration attempt failed before hardware access because a
local OBS preflight helper was absent. The dependency was supplied, scripts
checked and the original error retained; no measurement was discarded.
After each batch the original NSMB runtime/save, stock clock and OBS settings
were restored and its game-selection menu was visually verified. Source
integration and private packaging require the independent audited-source,
actual-launcher smoke and final-restoration gates.

Private evidence: `castlevania-live-balance-followup-20261017`, including
FOLLOWUP_PLAN, CAVE_SUMMARY, LIVE_SUMMARY, DECISION and restoration receipts.
No commercial game data is included in the public report or private installer.
