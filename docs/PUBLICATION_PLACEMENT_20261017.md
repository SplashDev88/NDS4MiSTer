# Publication CPU placement — 17 October 2026

Decision: **REJECTED**. Retain publication on CPU0. Moving it to CPU1 reduced
publication throughput in both Castlevania targets and the NSMB control. The
frozen Beta12 archive, runtime selection and public rc.8 Release are unchanged.

## Comparison

Both arms use the exact frozen Beta12 helper, host, core and support modules.
Only `NDS4MISTER_STANDALONE_UPLOAD_CPU0` differs: A is 1 (CPU0), B is 0 (CPU1).
The setting is read at construction, so each run uses a clean launch and fresh
isolated save copy. The helper is not rebuilt for this comparison.

Order per scene: **A B B A B A A B**, four runs per arm. Cave windows are
22 seconds, combat six, and NSMB 26 with repeated jumps. ARM runs at stock
1 GHz. Pacing/causal tracing remain identical to the freeze; CPU sampling,
renderer profiling, extra hardware inspection and heavy builds are absent
during capture. Analog RGBS passes through RetroTINK-4K into unchanged OBS.

| Scene | CPU0 pairs/s | CPU1 pairs/s | Change | Paired change range |
| --- | ---: | ---: | ---: | ---: |
| BAT | 22.6204 | 22.2249 | -1.749% | -2.536% to -1.262% |
| FIGHT | 21.5506 | 21.2841 | -1.236% | -2.435% to -0.521% |
| NSMB | 44.5322 | 42.7600 | -3.980% | -4.323% to -3.689% |

Every adjacent A/B pair is slower on CPU1 in this batch. Four independent runs
per arm and short variable gameplay windows do not establish a confidence
interval or whole-game performance. These are completed publication pairs,
not unique animation FPS or input-to-photon latency.

The predeclared gate requires both Castlevania means to improve by more than
1%, NSMB to remain within 1%, and picture-ready/upload-end mean per-run p95
gaps to worsen by no more than 2 ms. The speed gate fails in all three scenes.
Mario Kart is therefore not run for promotion: no setting is eligible.

## Samples and long gaps

| Run | Pairs/s | Picture-ready p95, ms | Upload-end p95, ms |
| --- | ---: | ---: | ---: |
| C56_BAT_A_1 | 22.6615 | 52.208 | 52.075 |
| C56_BAT_B_2 | 22.0869 | 53.527 | 53.548 |
| C56_BAT_B_3 | 22.2753 | 53.182 | 53.111 |
| C56_BAT_A_4 | 22.6511 | 53.531 | 53.623 |
| C56_BAT_B_5 | 22.2727 | 53.528 | 53.434 |
| C56_BAT_A_6 | 22.5574 | 52.934 | 52.853 |
| C56_BAT_A_7 | 22.6117 | 52.291 | 52.239 |
| C56_BAT_B_8 | 22.2646 | 53.408 | 53.365 |
| C56_FIGHT_A_1 | 21.7102 | 55.712 | 56.501 |
| C56_FIGHT_B_2 | 21.5010 | 56.546 | 56.624 |
| C56_FIGHT_B_3 | 20.9247 | 56.416 | 56.221 |
| C56_FIGHT_A_4 | 21.1362 | 59.290 | 59.306 |
| C56_FIGHT_B_5 | 21.3691 | 58.488 | 58.374 |
| C56_FIGHT_A_6 | 21.9024 | 54.827 | 54.737 |
| C56_FIGHT_A_7 | 21.4535 | 58.176 | 58.234 |
| C56_FIGHT_B_8 | 21.3417 | 57.076 | 56.811 |
| C56_NSMB_A_1_CLEAN | 44.3927 | 30.524 | 30.432 |
| C56_NSMB_B_2_RETRY2_CLEAN | 42.7549 | 32.641 | 32.305 |
| C56_NSMB_B_3_CLEAN | 42.7613 | 32.431 | 31.944 |
| C56_NSMB_A_4_CLEAN | 44.5706 | 30.674 | 30.564 |
| C56_NSMB_B_5_CLEAN | 42.8183 | 32.056 | 31.992 |
| C56_NSMB_A_6_CLEAN | 44.5305 | unresolved | unresolved |
| C56_NSMB_A_7_CLEAN | 44.6350 | unresolved | unresolved |
| C56_NSMB_B_8_CLEAN | 42.7056 | 32.247 | 32.099 |

Cave mean per-run p95 changes are +0.670 ms picture-ready and +0.667 ms
upload-end; combat changes are +0.130 and -0.187 ms. These meet the tail gate
but do not rescue the failed throughput gate. NSMB A6/A7 each contain two
raced Intake snapshot records, with no Replay or Publication races. The
predeclared conservative all-lane rule leaves the primary NSMB tail comparison
unresolved. Their independent stable header throughput remains in the table.
No runtime protocol fault is implied by a diagnostic snapshot race.

Cave uploads themselves average 994.3 microseconds on CPU0 and 837.3 on CPU1,
yet total throughput is lower. Faster isolated publication does not establish
a faster renderer or identify the exact source of the resulting contention.

## Correctness, workload and interruptions

All 24 qualified contact sheets were inspected: expected rooms, intact scene
graphics and HUD, surviving combat player and repeated NSMB jumps. A denser
0.2-second NSMB A6 sequence confirms jumps that the two-second contact sheet
samples near the ground phase. Contact sheets check sampled integrity, not
every rendered frame. Audio is present in every capture; fidelity is not
certified. All qualified windows have zero OBS render/encode drops, zero
FPGA/HPS fault words, exact intended publication affinity and stock clock.

Combat is deliberately left unfiltered: enemies, damage and incidental pickups
vary. Starting HP in run order is 99/99/99/99/96/99/99/103 and ending HP is
43/66/39/36/31/63/39/48. EXP is 70 in B2/B3/B5 and 69 elsewhere; B2/B5 have
50/100 gold. All samples are retained. NSMB initial timers are 495 or 496,
with repeated-jump windows ending at 473 or 474.

Original NSMB B2 was captured but its final mapping audit stopped before
completion: the checker mistook the intentional bounded query boost (Intake
FIFO priority 2 on CPU0) for an unexpected second publication thread. Its
43.1838 pairs/s result and video are preserved outside the qualified table.
The replacement was chosen for missing qualification, independently of rate.
The first replacement failed before capture when the checker rejected the
existing SCHED_IDLE diagnostic monitor. Neither interruption changed the core.

The corrected read-only classifier validates the publication FIFO1 role,
optional Intake FIFO2 query boost, ordinary workers and existing idle monitor.
It passed 51 offline cases and a live collector check before the final retry.
The qualified replacement is B2_RETRY2; no measured attempt is silently erased.

After every scene and both interrupted attempts, the original NSMB runtime
and save were restored and its game-selection screen inspected. All 54
protected paths and measured saves remain unchanged. Frozen package and
selection-file hashes are rechecked by the final decision script.

## Identity and evidence

Helper SHA-256:
`5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8`.

Frozen source: `1d3a33361730ca0d2f9123c578378bca40463aad`.
The private evidence collection is `publication-placement-c56-20261017`,
including PLAN, KIT_PAIR_CHECK, all captures, per-scene summaries, scheduling
checker corrections, visual/restoration receipts and DECISION. It is not
included in this source tree; no game data or binaries are committed.

The next diagnostic separates renderer thread CPU time from wall time and
isolates profiling-only palette scans before further work is parallelized.
This result does not establish an absolute speed ceiling or rule out other
ways to reduce CPU0 contention.
