# Castlevania Beta10: the next measured bottleneck

Follow-up: the optimization series has ended at the [private freeze](PRIVATE_BETA_20261017.md). See the [final live worker-range comparison](CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md); the measurements and native decisions below remain historical evidence.

Beta10's Engine B cache now hits on about 97.5% of sampled lines in both target rooms. A new diagnostic pass puts 3D raster work ahead of map-screen redraw as the next optimization target. These measurements select experiments; they do not establish another speed improvement.

The accepted runtime is `f8fdb6948fee428958ff50606a96919025e9b7aa`, helper SHA-256 `a0ef8246dbdffd15cc861018f2604a969c0af18cd14ccec93de9d3eba56fd4dd`. Two separate methods were used: a private helper with frame-level renderer timers, and external CPU-clock sampling of the exact accepted helper with matching binary symbols. No private diagnostic helper replaces Beta10.

## Frame-level wall times

| Measurement | Cave / bat platform | Warg combat |
| --- | ---: | ---: |
| Complete frame samples | 428 | 112 |
| Engine B cached lines | 97.483% | 97.624% |
| 3D raster | 15.336 ms | 15.300 ms |
| Primary raster worker | 14.241 ms | 14.060 ms |
| Secondary raster worker | 10.615 ms | 10.953 ms |
| Raster setup | 3.633 ms | 3.711 ms |
| 3D output wait/read | 21.572 ms | 21.457 ms |
| Engine A draw/composition | 4.151 ms | 4.663 ms |
| Engine B draw/composition | 0.132 ms | 0.127 ms |
| Engine A sprite preparation | 1.275 ms | 1.261 ms |
| Engine B sprite preparation | 1.979 ms | 1.985 ms |
| Cache decision | 1.199 ms | 1.229 ms |
| Cache commit | 0.278 ms | 0.278 ms |

These are means of instrumented wall time, including scheduling. Raster and its workers overlap; 3D output wait includes raster execution. Engine draw includes final color composition, and scanline time includes cache and output wait. Do not add the rows. Row-zero sprite preparation precedes the admitted-frame snapshot. Stage records are accepted only when all eleven records survive, with zero raced timeline records and exactly 192 Engine B line decisions per complete frame.

The earlier Beta8 profile reported roughly 4.7–4.8 ms of Engine B draw. That is useful historical context, but it is not a matched comparison: the runtime and diagnostic counters differ. The accepted performance result remains the separately controlled [Beta10 comparison](CASTLEVANIA_PREPARED_SPRITE_PERFORMANCE_20261017.md).

## CPU sampling of the accepted binary

At 499 Hz, the selected active windows contain 14,296 cave samples and 4,037 combat samples. Leading leaf-symbol shares are:

| Function or path | Cave | Combat |
| --- | ---: | ---: |
| Flat rectangle raster | 7.974% | 9.958% |
| Gray rectangle raster | 7.289% | 7.629% |
| Frame-packet acquisition | 7.261% | 7.580% |
| GPU3D command execution | 5.512% | 4.979% |
| Packet replay | 5.393% | 4.830% |
| Polygon submission | 4.729% | 4.558% |
| Contiguous texture span | 4.533% | 5.028% |
| Input polling | 4.358% | 4.211% |

These are statistical leaf samples, not inclusive call costs or memory-stall measurements. Blending is inlined into several raster paths: the small standalone translucent-pixel symbol count does not mean blending is absent, and the enclosing function shares do not isolate blend arithmetic. Matrix multiplication itself accounts for about 0.112% of the cave samples, so moving only matrix multiplication to FPGA is not supported as the leading opportunity by this workload.

In the cave sample, the primary raster and input threads on CPU0 accumulated about 3.61 and 3.84 seconds of runnable wait respectively. The secondary raster and replay threads on CPU1 accumulated about 0.12 and 0.21 seconds. This supports investigating work distribution, but does not prove a new partition will help. The earlier corrected eight-band experiment regressed and should not be repeated unchanged.

## Validation and next experiments

All four recordings show complete rooms, active animation, unchanged protected files and saves, stock 1 GHz, audio presence, zero protocol faults and zero capture drops. Combat enemy phases and damage vary. The diagnostic helper passed the full ARM service self-test with its gate both off and on; 851 source inputs were checked and temporary source overlays restored. The original NSMB rig and OBS settings were restored and the game-selection menu visually verified.

The instrumentation perturbs timing. Cave publication throughput is about 19.50 pairs/s with stage timers and 18.55 under external CPU sampling, versus about 21.64 in the unprofiled Beta10 acceptance comparison. These rates are neither speed-acceptance measurements nor distinct animation FPS. Analog threshold-change counts were not used to rank these diagnostic runs.

The first bounded follow-up tests whether combining red and blue alpha interpolation reduces raster cost while preserving every output bit. It requires exhaustive arithmetic checks, full color/depth/attribute comparisons, native cave/combat and NSMB/Mario Kart controls, then clean live comparisons if the native result warrants them. Packet acquisition and sprite-setup identity remain secondary hypotheses. No follow-up is accepted by this report.

Private evidence: `castlevania-post-cache-profile-20261017`. A first offline analyzer lacked the new event IDs; its original error was retained, the decoder was extended, and the already captured data was reanalyzed under the same timestamp, race and count checks. This did not require changing or accepting any runtime result.
