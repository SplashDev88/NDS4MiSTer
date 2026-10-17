# Sprite-row input cache experiment, 2026-10-17

The exact per-row sprite-input cache was rejected before gameplay installation. It reduced dense static sprite cost by only 2.069%, while empty, changing, VRAM-changing and window workloads became slower. Castlevania Beta10 remains accepted.

The private candidate compares the ordered sprite number and all three OAM attributes only for normal sprites intersecting the current Engine B row. Unrelated OAM writes do not invalidate the row. The original OBJ VRAM coherency step always runs; the key also includes the resulting VRAM epoch and display control. Visible affine or mosaic sprites, capture, tracing and disabled modes retain the original path. Cached buffers belong to the pre-composition sprite phase, and include transparent/window sprite counts. Admission uses the existing Castlevania prepared-sprite setting. The 448,016-byte cache is allocated only when eligible.

Both tracked and untracked OAM tests passed 132,885 directed comparisons, including 256 required hits after irrelevant OAM writes, live attribute invalidation, affine/mosaic/profile-off exclusions, raw sprite buffers, composed pixels and two deliberate fault-detection controls. Engine B, paired-screen and direct-output tests passed. The accepted 168-frame prepared-sprite oracle passed normal, direct, parallel and direct-plus-parallel modes, each comparing 16,515,072 pixels plus sprite-state checks. The complete ARM service self-test passed in Docker. All 851 source inputs were checked; only the intended GPU2D source and header differ at runtime. Private overlays were restored.

The private helper SHA-256 is `8698a36362ae66077162376858a3be49d1c52cf97b8d91eb4065631b7e2ba0db`. The baseline is accepted Beta10, not an earlier unpromoted sprite-cache prototype.

## Native timing

Six samples per build and synthetic scene, baseline/candidate/candidate/baseline order with three samples per position. Each sample measures 96 frames after two warmups. Full paired output hashes match and are checked outside each frame's timed interval. Stock 1 GHz, CPU0 timing, verified MENU temporarily parked with a watchdog and restored afterward.

| Scene | Mean CPU cost change | Mean elapsed cost change |
| --- | ---: | ---: |
| Dense static sprites | -2.069% | -2.064% |
| Dense changing sprites | +11.479% | +11.497% |
| Changing OBJ VRAM | +11.453% | +11.504% |
| No sprites | +16.879% | +16.830% |
| Static OBJ windows | +2.431% | +2.436% |
| One changing sprite | -0.191% | -0.318% |
| Profile disabled | -0.097% | -0.093% |
| Static mosaic sprites | +5.947% | +5.947% |

Negative means faster. The predeclared gate required at least 5% gains in dense-static, empty, window and one-changing-sprite cases, no more than 1% cost with the profile off, and no more than 10% in the remaining dynamic controls. Only the profile-off limit passed. These synthetic per-line costs are not game FPS. Correct cache hits alone did not repay the lookup and buffer-copy costs across the admitted workloads.

No live kit, new package, accepted source change or public release was created. The original NSMB runtime and save, all 54 protected files, clock, menu affinity and OBS settings were restored, and the game-selection menu was visually verified. Private evidence: `castlevania-sprite-row-input-performance-20261017`.
