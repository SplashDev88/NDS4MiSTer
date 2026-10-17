# Rejected Castlevania renderer experiments — 16 October 2026

These experiments did not replace Castlevania Beta8. The most promising renderer candidate reduced fixed-input rendering CPU time by about 4.4%, but its live cave throughput was unchanged and its repeated NSMB control exceeded the predeclared 1% slowdown limit. It was rejected before packaging. The 60 fps goal remains unmet.

## Renderer candidates

1. Mirrored texture batches: cave CPU cost changed by −0.964% and combat by −0.097%. The target gain was below 1%; rejected.
2. Masked opaque/transparent stores: cave cost increased by 0.489% and combat by 0.965%; rejected.
3. Separating prepared rectangle rendering from fallback rendering: the moved fallback body and pixel arithmetic remained unchanged, but the changed function boundaries also changed generated code. Native target CPU savings passed the initial gate; the live control failed.

The first two full raster qualifications were stopped after failing the speed gate. Their partial checks are not complete passes. Their code is excluded from the third candidate and from the current beta.

## Third candidate: fixed-input native measurements

Stock 1 GHz Cortex-A9; rendering on CPU0 with the stopped MENU process on CPU1. Baseline/candidate/candidate/baseline order, three samples per leg, 16 warm-up and 100 measured renders per sample. Full color/depth/attribute hashes matched. These values are CPU cost per saved rendering input, not gameplay FPS.

| Scene | Beta8 ms | Candidate ms | Change |
|---|---:|---:|---:|
| bat-live | 23.835 | 22.791 | -4.381% |
| combat-live | 22.627 | 21.625 | -4.426% |
| nsmb-castle | 11.777 | 11.869 | +0.779% |
| nsmb-castle-left | 11.652 | 11.675 | +0.192% |
| mario-kart-heavy | 35.942 | 35.733 | -0.579% |

## Physical gameplay control

Analog RGBS at approximately 59.64 Hz passed through the RetroTINK-4K and the established USB/OBS capture chain. No new HDMI or DV1 qualification is claimed. Measurements had no sampling profiler or SSH polling during active gameplay. All accepted runs retained zero protocol faults, zero OBS render/encode drops, an audio signal and 54 unchanged protected files. Audio presence is not an audio-quality qualification.

| Trial | Completed pairs/s |
|---|---:|
| C15_BAT_BASE_CLEAN | 19.507 |
| C15_BAT_CAND_CLEAN | 19.509 |
| C15_FIGHT_BASE_IDLE | 18.513 |
| C15_NSMB_BASE_CLEAN | 44.813 |
| C15_NSMB_CAND_CLEAN | 44.011 |
| C15_NSMB_CAND_REPEAT_CLEAN | 44.306 |
| C15_NSMB_BASE_REPEAT_CLEAN | 44.643 |

The first cave comparison was 19.507 versus 19.509 completed screen pairs/s (+0.007%). NSMB used two fresh-save runs per build in baseline/candidate/candidate/baseline order. Its mean was 44.728 versus 44.158 (-1.274%). Both candidate NSMB rates were below both baseline rates.

Completed publication pairs are not necessarily distinct animation frames. Cave windows lasted 22 seconds, NSMB 26 seconds with repeated jumps at the castle entrance. NSMB recordings showed the expected level, 19 coins, active jumping and no death or dialog. Short tests do not establish long-session stability or worst-case frame pacing.

The first candidate combat window is excluded because a soul-acquisition dialog remained open throughout. It cannot be compared with active combat. Further cave/combat runs and Beta9 packaging were cancelled after the repeated NSMB control failed. No combat speed gain is claimed.

## Correctness and provenance

The third candidate passed the complete ARM service self-test, 5,900 full-buffer raster comparisons with Beta8, 48 sequential snapshots and 160 serial/parallel/delayed-worker renders. Of the 5,900 raster cases, 5,644 also matched an independent uncached reference. The remaining 256 preserve legacy baseline behavior, including 40 full-buffer and two visible differences from the reference. The unchanged gray blend helper passed 12,713,984 arithmetic checks.

A conservative 851-input inventory matched the public runtime sources; the only difference was an unlinked standalone profile-test source. Temporary private-build overlays were restored. Geometry, replay, frame admission, FPGA, host and ARM clock were unchanged.

Baseline: `3c71cb55e1b8256f3ccab67ed4e399093482e995` (Castlevania Beta8). Candidate helper SHA-256: `4f8850de6a59be6d1ceb14bce96f04fbaa9acdbaca191f76f92b4d4579c9d8e0`.

## Follow-up: packet acquisition

Separate instruction samples concentrated around the two-record FPGA-to-ARM copy loop. These are statistical samples, include recording padding, and do not assign exact cycles to individual instructions. Buffer reuse and larger-copy-batch prototypes were tested separately from the renderer change.

At 1 GHz on the physical Cortex-A9, buffer reuse reduced cached-RAM packet-acquisition cost by 10.579% for the 264-record workload and 7.580% for the 1,799-record workload. Eight-record batches increased the smaller workload cost by 9.883%; they were not selected. Combining the changes was not consistently better than reuse alone.

The packet tests cover existing validation/ownership faults, 20 payload lengths, grow/shrink/same-length reuse with diagnostics enabled and disabled, and empty output on unsuccessful acquisition. Cached-RAM microbenchmarks do not measure uncached FPGA traffic or live gameplay; a standalone buffer-reuse candidate requires its own live qualification.

Private evidence: `castlevania-texture-performance-20261016`. No ROMs, saves, snapshots or captured game media are included in this document or the public source.
