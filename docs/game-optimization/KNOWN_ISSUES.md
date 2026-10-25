# Optimization investigation limits

- The three-NOP background NORMAL patch is rejected: video equality did not imply RAM/audio equality. No relaxed budget was requested or assumed.
- Palette uploads in the target room change real colors. Do not remove them or freeze weather/lighting.
- Whole-ROM hashes and game-code guards do not establish that an overlay is currently loaded. Overlay hooks need live identity checks; no overlay hook is installed by this experiment.
- FPGA guest RAM is not ordinary HPS memory. A software reference HLE does not establish a native trap mechanism. No RTL or new HPS service is authorized here.
- Core save states remain unsupported. Derived GPU-cache reset/restore tests do not add persistent core save states.
- `BASE_FIGHT1` reached the data-selection menu after player death. Its 58.5 publications/s is invalid as a combat measurement and excluded.
- The parked partial-image cache helped frozen repetitions but slowed changing inputs; it is not a beta candidate. Its row-copy path also needs explicit X-partition ownership before parallel use.
- Publication pairs are completed screen updates, not necessarily unique animation frames or end-to-end display FPS. OBS timestamps and detector counts are secondary evidence.
- Native ARM7 PC/cycle counts, per-frame FPGA CPU cycle accounting, missed VBlanks and total cartridge/DMA-byte counters are not all exposed by the retained bitstream. Missing measurements must remain unavailable.

- **Native flag verification is mandatory.** The release supervisor intentionally strips inherited `NDS*`/`H3D_*` variables. The early lighting and cache A/B launches therefore tested disabled paths in both arms. Those live results cannot establish candidate performance. The isolated supervisor now admits only declared private Boolean flags and asserts the helper's actual environment; the rig checks that record before input/measurement.
- The native bat-room route uses timed input. Small differences in jumping can put the player on a different platform and change the camera. Inspect the video, exclude mismatched positions, and prefer a reproducible in-game suspend seed. `C3_A` was floor-level while `C3_B`/`C3_A2` were platform-level.
- GPU restore can launch a renderer worker. Standalone paired tests must consume that completion before starting another render. Otherwise the next completion can belong to the restore rather than the measured draw.
- Native raster buffers contain inactive backing pixels: when no top edge refers to a lower pixel, or antialiasing is disabled, those stale bytes are not displayed. Comparison masks only such lower storage, never top color/depth/attributes or live AA data. Complete framebuffer/RAM/audio/save replays remain required.

- The first newly created suspend (`SEEDBAT`) was still in the save room, because exiting requires jumping over the left stair. The resulting ~47 updates/s runs are excluded. `SEEDCAVE` was visually confirmed in the actual bat cave and repeated from the same resume position.
- Texture stress testing exposed an existing dirty-bitset wrap bug: the array index mask counted blocks, not 64-bit words, allowing an out-of-bounds read for wrapped texture ranges. The candidate corrects the word mask; independent wrap tests and 6,000-frame screen/RAM/audio/save replay comparisons pass.
- The guarded opaque-order candidates passed correctness checks but increased target CPU time. They are not included. Lighting-result reuse passed exactness checks but its approximately 0.36% nominal native gain was below the observed scatter; it is also removed.

- `PUBF1` is excluded: an early pause press occurred while the suspend was still loading, and the benchmark subsequently counted the pause menu. The harness now proves the pause screen before measuring. A fixed eight-second OBS sample can precede active play; capture validation now uses the recorded measurement interval.

- `PUBK1` is excluded from the Mario Kart speed comparison: the first interval was still at cup selection, and the second crossed the countdown. The qualified regression route adds spaced confirmation presses and checks actual racing captures.
