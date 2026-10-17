# Packet mapping with same-binary controls — 17 October 2026

Decision: **INCONCLUSIVE_BASELINE_SHIFT**. Frozen Beta12 remains selected and unchanged. This is a
new comparison; the previous C54 rejection remains valid under its original gate.

## Method and qualification

The packet-input prototype replaces only the four owned 64 KiB input slots
with a read-only Normal-NC mapping. Control/header and output mapping policies,
packet validation and ordering barriers are preserved. No conflicting Device
alias is allowed. The helper is rebuilt directly from the frozen source with
three changed inputs; no profiling or parallel-phase changes are inherited.

Each scene uses four runs per arm: exact frozen helper (BASE), candidate helper
with mapping off (OFF), and that identical candidate executable with mapping on
(ON). The balanced order is BASE/OFF/ON, ON/OFF/BASE, OFF/ON/BASE, BASE/ON/OFF.
The two candidate kits differ in one runtime setting, the matching launcher
metadata/checksums and their private identities. All support binaries match.
Fresh isolated suspend copies, stock 1 GHz, identical rig settings and no sampler
or competing build are used. Cave/combat active windows are 22/6 seconds;
NSMB uses 26 seconds of repeated jumps in the castle control.

Predeclared gates: ON must improve both Castlevania means by more than 1%
against both references; NSMB may regress no more than 1%. OFF must lie within
the observed BASE range and be no more than 1% slower on average, otherwise
the experiment is inconclusive due to baseline shift. Mean per-run p95
picture-ready and upload-end gaps may increase by at most 2 ms. Correctness,
visual review, protected files and hardware settings must also pass. A Mario
Kart control and packaged module lifecycle qualification are required before
promotion, even if the measurement gates pass.

## Live results

Rates count complete publication pairs, **not unique animation FPS**.
Four short runs per arm describe this batch, not a confidence interval.

| Scene | BASE mean pairs/s | OFF mean pairs/s | ON mean pairs/s | ON vs BASE | ON vs OFF | OFF baseline valid |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| BAT | 22.6164 | 22.7371 | 23.2593 | +2.843% | +2.297% | False |
| FIGHT | 21.6076 | 21.9967 | 21.9279 | +1.482% | -0.313% | False |
| NSMB | 44.5873 | 44.7564 | 44.6421 | +0.123% | -0.256% | True |

| Scene | Speed gate | Tail gate | Scene decision |
| --- | --- | --- | --- |
| BAT | Pass | Pass | INCONCLUSIVE_BASELINE_SHIFT |
| FIGHT | Fail | Pass | INCONCLUSIVE_BASELINE_SHIFT |
| NSMB | Pass | Unresolved | SCENE_NOT_QUALIFIED |

All rates in occurrence order, with per-arm ranges:

| Scene | Arm | Samples, pairs/s | Range |
| --- | --- | --- | --- |
| BAT | BASE | 22.6103, 22.5794, 22.6393, 22.6367 | 22.5794–22.6393 |
| BAT | OFF | 22.6204, 22.8588, 22.7870, 22.6821 | 22.6204–22.8588 |
| BAT | ON | 23.3166, 23.2861, 23.1537, 23.2808 | 23.1537–23.3166 |
| FIGHT | BASE | 21.9389, 20.9087, 21.9135, 21.6691 | 20.9087–21.9389 |
| FIGHT | OFF | 22.1628, 22.3388, 21.9468, 21.5386 | 21.5386–22.3388 |
| FIGHT | ON | 22.0197, 22.0984, 21.6206, 21.9728 | 21.6206–22.0984 |
| NSMB | BASE | 44.3520, 44.6426, 44.5338, 44.8208 | 44.3520–44.8208 |
| NSMB | OFF | 45.1157, 44.8167, 44.5129, 44.5805 | 44.5129–45.1157 |
| NSMB | ON | 44.9639, 44.1832, 44.7685, 44.6528 | 44.1832–44.9639 |

Paired-triplet ON differences (each triplet contains all three arms):

| Scene | Against BASE | Against OFF |
| --- | --- | --- |
| BAT | +3.124%, +3.130%, +2.272%, +2.846% | +3.078%, +1.869%, +1.609%, +2.640% |
| FIGHT | +0.368%, +5.690%, -1.337%, +1.401% | -0.646%, -1.076%, -1.486%, +2.016% |
| NSMB | +1.380%, -1.029%, +0.527%, -0.375% | -0.336%, -1.414%, +0.574%, +0.162% |

Tail statistics use unraced Replay and Publication timeline lanes with complete
active-window coverage, a rule recorded before capture. Unrelated Intake races
remain recorded and invalidate analyses that require Intake events. Stable
header throughput counts do not depend on the timeline snapshot. Missing or
raced required lanes leave the tail gate unresolved; they are not a tail pass.
Per-run gap percentiles are averaged without pooling frames across captures.

NSMB BASE6 has two raced Replay snapshot records and no Intake or Publication
races. Its stable header throughput remains included, but the full NSMB tail
comparison is unresolved. This is a diagnostic snapshot limitation, not a
runtime protocol fault. No replacement run was selected to erase this limitation.

| Scene | Reference | Ready p95 change, ms | Upload p95 change, ms |
| --- | --- | ---: | ---: |
| BAT | BASE | -1.683 | -1.672 |
| BAT | OFF | -1.464 | -1.446 |
| FIGHT | BASE | -0.912 | -1.042 |
| FIGHT | OFF | -1.437 | -1.610 |
| NSMB | Both | Unresolved | Unresolved |

Mean per-run tail statistics:

| Scene | Arm | Event | Median / p95 / p99 / max, ms |
| --- | --- | --- | --- |
| BAT | BASE | picture_ready | 42.890 / 52.297 / 57.078 / 59.594 |
| BAT | BASE | upload_end | 42.885 / 52.287 / 57.117 / 59.642 |
| BAT | OFF | picture_ready | 42.513 / 52.078 / 56.399 / 58.792 |
| BAT | OFF | upload_end | 42.517 / 52.061 / 56.397 / 58.803 |
| BAT | ON | picture_ready | 41.607 / 50.614 / 55.620 / 59.665 |
| BAT | ON | upload_end | 41.605 / 50.614 / 55.744 / 59.636 |
| FIGHT | BASE | picture_ready | 46.337 / 56.259 / 62.324 / 63.925 |
| FIGHT | BASE | upload_end | 46.284 / 56.264 / 62.333 / 63.892 |
| FIGHT | OFF | picture_ready | 45.840 / 56.785 / 60.310 / 65.469 |
| FIGHT | OFF | upload_end | 45.864 / 56.832 / 60.323 / 65.372 |
| FIGHT | ON | picture_ready | 45.619 / 55.347 / 59.267 / 62.919 |
| FIGHT | ON | upload_end | 45.615 / 55.222 / 59.213 / 62.914 |
| NSMB | OFF | picture_ready | 23.029 / 30.804 / 35.551 / 39.674 |
| NSMB | OFF | upload_end | 22.718 / 30.506 / 35.457 / 39.659 |
| NSMB | ON | picture_ready | 23.120 / 30.611 / 35.592 / 41.769 |
| NSMB | ON | upload_end | 22.786 / 30.506 / 35.375 / 41.750 |

## Correctness, review and limits

The fresh helper passed full ARM service, packet and mapping tests, plus host
mapping tests. All 851 build inputs were checked against the frozen inventory;
exactly the three intended packet-mapping inputs differ. The kernel module is
the identical C54-tested binary on Linux 6.18.38-MiSTer. Permission/bounds,
write/execute denial, unprivileged denial and refusal to unload with an active
mapping are **inherited** tests, not fresh C59 reruns. C59 rechecks module/kernel
identity and aliases for every normal load, and checks exact live mapping,
helper identity, environment, affinity and scheduling before and after each run.
The module is unloaded normally with no remaining mapping before restoration.

All qualified contact sheets were viewed. Audio was present and OBS render/
encode drops and runtime fault flags were zero. Sampled images and audio RMS
are not full-playthrough or audio-fidelity proof. Exact scene-state observations
are retained below; short combat windows and enemy timing limit generalization.

- `C59_BAT_BASE_1`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_OFF_2`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_ON_3`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_ON_4`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_OFF_5`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_BASE_6`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_OFF_7`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_ON_8`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_BASE_9`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_BASE_10`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_ON_11`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_BAT_OFF_12`: Viewed full contact sheet: expected cave and middle platform, intact character/background/HUD, menu HP132/132 and EXP69/gold0 before and after; game time 09:24 to 09:47. Sampled images show no visible corruption; not a distinct-animation-FPS measurement.
- `C59_FIGHT_BASE_1`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP103/132 to 56/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_OFF_2`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP103/132 to 66/132, EXP70, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_ON_3`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP99/132 to 49/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_ON_4`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP99/132 to 54/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_OFF_5`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP99/132 to 70/132, EXP70, gold100; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_BASE_6`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP103/132 to 69/132, EXP70, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical. Sampled camera/background shifts during combat and map percentage reaches 1.1%.
- `C59_FIGHT_OFF_7`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP103/132 to 52/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_ON_8`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP99/132 to 65/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical. Sampled camera/background shifts during combat and map percentage reaches 1.1%.
- `C59_FIGHT_BASE_9`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP103/132 to 70/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_BASE_10`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP97/132 to 25/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical. Starts at a different position within the same room, map1.1%, with heavier damage; no death or corruption visible.
- `C59_FIGHT_ON_11`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP99/132 to 49/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_FIGHT_OFF_12`: Viewed full contact sheet: expected forest combat with Warg, armored enemy and zombies; intact graphics/HUD, HP110/132 to 48/132, EXP69, gold0; time 10:07 to 10:13. Enemy phases, damage and camera position vary; retain sample without treating states as identical.
- `C59_NSMB_BASE_1_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to474; paused before/after.
- `C59_NSMB_OFF_2_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to475; paused before/after.
- `C59_NSMB_ON_3_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer495 to473; paused before/after.
- `C59_NSMB_ON_4_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to473; paused before/after.
- `C59_NSMB_OFF_5_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer495 to474; paused before/after.
- `C59_NSMB_BASE_6_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to474; paused before/after.
  Tail limitation: Raced Replay/Publication timeline; throughput retained, tail gate unresolved.
- `C59_NSMB_OFF_7_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to474; paused before/after.
- `C59_NSMB_ON_8_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer495 to473; paused before/after.
- `C59_NSMB_BASE_9_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to474; paused before/after.
- `C59_NSMB_BASE_10_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer495 to474; paused before/after.
- `C59_NSMB_ON_11_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer496 to473; paused before/after.
- `C59_NSMB_OFF_12_CLEAN`: Viewed complete contact sheet: expected castle/lava/rotating-hazard scene, intact Mario/background/HUD, grounded and airborne Mario sampled during the jump sequence, no observed death or corruption. Coins19 unchanged; timer495 to474; paused before/after.

Each scene restores the original NSMB runtime/save, all 54 protected paths,
stock clock and unchanged OBS settings. Fresh original game-selection snapshots
were viewed after restoration. All frozen pointers and the private archive hash
remain unchanged. A preflight attempt initially lacked a local OBS preflight
helper and exited before hardware operations or sampling; its failure log is
retained and the unchanged, previously used helper was supplied before retry.

Required promotion controls:

- mario_kart: NOT_RUN.
- owned_module_lifecycle: NOT_RUN.

These promotion-only controls were not run because the preceding measurement gates did not qualify the candidate. They are not reported as passes.

The experiment-only module controller is not a qualified package lifecycle.
No public Release or accepted runtime is changed by this report.

Candidate helper SHA-256:
`0f44b54f39c375de216f21a4654e2fe307209c23c4f9cc70a964b74435b03617`.
Frozen helper SHA-256:
`5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8`.

Private evidence: `packet-mapping-c59-20261017`, including exact kit comparison,
source/build receipts, every measurement and trace, visual notes, exclusions
and restoration. No game data, binary or private access information is committed.
