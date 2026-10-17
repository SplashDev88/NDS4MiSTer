# Renderer stage measurements — diagnostic only

A private helper correlates existing renderer counters with the cave and combat measurement windows. Five events per admitted frame are written to the existing RAM timeline. It enables renderer stage clocks while keeping per-command pipeline timers off. No rendering arithmetic, frame admission, FPGA or clock was changed. The full ARM self-test passed both with the diagnostic gate disabled and enabled; all 851 build inputs were verified and private source overlays restored.

| Scene | Complete frame samples | Raster ms | 3D output wait/read ms | Engine A draw/composition ms | Engine B draw/composition ms | A sprites ms | B sprites ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Cave | 377 | 15.205 | 21.029 | 5.432 | 4.724 | 1.257 | 1.956 |
| Combat | 96 | 15.404 | 21.652 | 5.759 | 4.813 | 1.253 | 1.970 |

These are mean instrumented wall times. Stages overlap and include scheduling delay: the 3D output wait includes raster execution and must not be added to it. Engine draw/composition includes backgrounds, sprite interleaving and final color composition; it does not isolate the final color-effect function. Row-zero sprite preparation occurs before the admitted-frame counter snapshot.

The cave sample covers 22 active seconds and combat six seconds. Both recordings show complete backgrounds and active animation, zero protocol faults or capture drops, stock 1 GHz, audio presence and unchanged protected files. Enemy phases and damage vary in the short combat sample.

The cave delivered 17.128 publication pairs/s under these renderer timers, compared with the nearby unprofiled Beta8 mean of 19.378. Thus the new diagnostic still perturbs timing, though substantially less than the earlier full-pipeline profiler near 11.2 pairs/s. None of these instrumented rates is an optimization acceptance result or distinct visible animation FPS.

The measurements justify investigating 2D composition alongside raster work. They do not identify why Engine B cache entries miss. The next private prototype removes provably unnecessary final color-effect dispatch for pixels whose output cannot change.

Private evidence: `castlevania-frame-stages-performance-20261017`.
