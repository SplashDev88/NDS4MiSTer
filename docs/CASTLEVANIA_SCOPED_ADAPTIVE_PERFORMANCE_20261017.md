# Castlevania adaptive raster scheduling, 2026-10-17

Follow-up: the optimization series has ended at the [private freeze](PRIVATE_BETA_20261017.md). See the [final live worker-range comparison](CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md); the measurements and native decisions below remain historical evidence.

The private Beta11 candidate improves completed picture-pair delivery versus Beta10 by 2.386% in the cave and 3.935% in Warg combat. The NSMB control changes by +0.762%. These are repeated short scene observations, not distinct displayed animation FPS. The 60 fps goal remains unmet.

The existing exact Dawn of Sorrow USA revision-0 profile selects the existing completion-adaptive two-way raster path. Other games retain the established four-band queue and its hysteresis. Shadow, antialiasing, depth, blending, geometry, worker fences, frame admission and pixel arithmetic are unchanged. The core, host, stock 1 GHz clock and prior Beta10 functionality are retained. The earlier global queue-disabled experiment was rejected because its Mario Kart saved-scene control slowed down; this scoped implementation was built and measured separately.

## Native controls

The physical Cortex-A9 test uses 16 warmups and 100 measured renders per sample, six samples per build and scene in baseline/candidate/candidate/baseline order. Both cores are available; the verified menu is temporarily parked with a watchdog, then resumed with its original affinity. Complete output hashes match. Scheduler observations confirm adaptive mode for the candidate Castlevania scenes and the same policy as baseline for the controls. These isolated snapshots omit normal live input-thread contention.

| Saved scene | Median CPU cost change | Median elapsed cost change |
| --- | ---: | ---: |
| bat-live | -3.810% | -5.736% |
| combat-live | -3.780% | -6.052% |
| nsmb-castle | +0.910% | +0.731% |
| nsmb-castle-left | +0.252% | -0.047% |
| mario-kart-heavy | +0.137% | -0.138% |

Negative means lower rendering cost. Both target elapsed gains exceed 1%; every control CPU and elapsed increase is below 1%.

## Live comparisons

Analog RGBS at about 59.64 Hz passes through the RetroTINK-4K and the existing USB/OBS capture setup. Fresh isolated saves and the same movement sequences are used in each leg. Cave windows last 22 seconds, combat windows six seconds, and NSMB castle windows 26 seconds with repeated jumping. There is no CPU profiler, GPU snapshot request or concurrent heavy build in the measurement windows. No new HDMI or DV1 qualification is claimed.

| Run | Picture pairs/s | Median delivery interval, ms | p95 delivery interval, ms |
| --- | ---: | ---: | ---: |
| C49_BAT_BASE | 21.539 | 45.200 | 55.758 |
| C49_BAT_CAND | 22.141 | 43.504 | 53.761 |
| C49_BAT_CAND_REPEAT | 22.066 | 43.882 | 53.253 |
| C49_BAT_BASE_REPEAT | 21.638 | 45.136 | 55.317 |
| C49_FIGHT_BASE | 21.164 | 47.819 | 58.060 |
| C49_FIGHT_CAND | 21.376 | 47.337 | 58.592 |
| C49_FIGHT_CAND_REPEAT | 21.563 | 47.209 | 56.815 |
| C49_FIGHT_BASE_REPEAT | 20.150 | 49.189 | 59.341 |
| C49_NSMB_BASE_CLEAN | 44.432 | Excluded | Excluded |
| C49_NSMB_CAND_CLEAN | 44.437 | 23.291 | 30.843 |
| C49_NSMB_CAND_REPEAT_CLEAN | 44.885 | 23.233 | 30.709 |
| C49_NSMB_BASE_REPEAT_CLEAN | 44.216 | 23.209 | 30.899 |

All accepted recordings have complete scene graphics, audio presence, zero protocol faults and zero OBS render/encoder drops. Isolated saves and 54 protected files remain unchanged. Encoder counts use the final counter for each recording because OBS resets that counter when recording starts. Raced RAM timelines, if any, are excluded from interval analysis; the independently sampled publication counters remain the rate source.

Bat/enemy phases vary. In particular, the combat baselines differ, so the mean change is not a deterministic gameplay speedup. Audio presence is not a fidelity certification, and short sampled visual review cannot establish whole-game compatibility. Publication pairs and LCD tags must not be presented as distinct animation-frame rates.

## Correctness and provenance

- Full ARM service self-test in Docker passes; it is not run on the memory-constrained MiSTer.
- All 851 build inputs are checked and the private build checkout is restored.
- 320 complete color/depth/attribute snapshot comparisons cover both profile values with serial, adaptive and queued modes. The existing delay hook covers queued workers; the separate synthetic test below also delays adaptive workers.
- 384 synthetic complete-buffer comparisons cover profile transitions on the same renderer and 192 deliberately delayed worker wakeups across both schedules. There are 48 ordinary queued-policy checks and 48 scoped adaptive-policy checks. Linking the same test against Beta10 fails the new policy assertion, confirming that the test detects the change.
- Previous pixel arithmetic and broad synthetic raster qualification are inherited; those unchanged arithmetic tests are not represented as rerun in this scheduler experiment.

ARM helper SHA-256: `6413c7b388c52b1160d765c99735a59ee4ad037e6d4ad929675fced786b8f8b9`.

The original NSMB runtime and save, stock clock, menu affinity and OBS settings are restored after each hardware batch, and the game-selection menu is visually checked. A test package is accepted only after source correspondence, checksum verification, a fresh installation through its actual shell launcher, and final restoration. Beta10 remains the rollback build. No public GitHub Release is created.

Private evidence: `castlevania-scoped-adaptive-performance-20261017`. ROMs, saves, GPU snapshots and recording media are excluded from the repository and installable package.
