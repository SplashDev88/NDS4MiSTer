# Sprite-phase cache experiment — no promotion

The existing optional Engine B sprite-phase cache did not improve the target Castlevania cave scene. Castlevania Beta8 remains the accepted build. The candidate used the exact Beta8 helper and enabled only `NDS_GPU_SPRITE_PHASE_CACHE=1` in an isolated private kit. No runtime source, FPGA, clock or frame-admission changes were made.

The cache retains VRAM coherency and restores pre-mosaic sprite buffers at their original phase. Current-code qualification passed 132,608 directed cases in each tracked/untracked mode, writer and negative-control checks, 7,488 integration lines, Engine B, paired-screen and direct-framebuffer pixel oracles, and the complete ARM helper self-test. An older test harness was adjusted for the already-accepted OAM epoch tracking both engines and the existing sprite setup cache; production code was unchanged.

Four fresh isolated suspend trials used baseline/candidate/candidate/baseline order on the same cave platform. Rates were 19.36541, 19.24993, 19.31613 and 19.38958 completed screen pairs/s. Mean baseline 19.37750 versus candidate 19.28303 is -0.487%. Candidate p95 intervals were 61.630 and 61.991 ms, versus 60.382 and 60.751 ms for baseline. This fails the predeclared 1% improvement gate.

All four accepted captures showed complete cave geometry, stable HP132/EXP69, stock 1 GHz, no protocol faults, zero OBS render/encode drops, audio presence and unchanged protected files and isolated saves during measurement. An earlier baseline with one OBS render drop was excluded and replaced before comparison. These short publication measurements are not distinct visible animation FPS. No live combat or NSMB acceptance claim is made after the target gate failed. No new beta or public release was created.

Private evidence: `castlevania-sprite-cache-performance-20261017`.
