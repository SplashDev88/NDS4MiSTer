# ARM 3D next-step evidence and viewport experiment (2026-09-05)

## Scope and baseline

This experiment starts at the exact public `v0.3.0-beta.7` commit
`43c49ac8`. The baseline ARM service was rebuilt with the release ARMHF/LTO
wrapper and reproduced the published SHA-256 exactly:

```text
bc7971606f958799a855b043757e3989aec3046ceafea34fb07f6ba70a92631a
```

No FPGA RTL behavior, clock, screen layout, touch path, saves, sound, frame
admission, publication ownership, or pacing policy is changed in this lane.
No ROM or save is used by the local tests.

The public source already contains the retained DreamSTer-style work: a fixed
packet arena, cache-separated SPSC indices and futex waits, CPU affinity,
write-combined/direct plane publication, adaptive dual-core raster work,
four-band scheduling, obsolete-frame cancellation, packed GX replay, NEON
vertex transforms, batched perspective interpolation, and complete-frame
catch-up. Those are baselines rather than new opportunities here.

## Ranked opportunities

| Rank | Opportunity | Evidence and expected hot-path impact | Correctness risk | ARM / FPGA cost | Required measurement |
| --- | --- | --- | --- | --- | --- |
| 1 | Share the native viewport denominator and replace two Cortex-A9 software divides per submitted vertex | Exact beta.7 ARM disassembly executes two `__udivsi3` calls in `GPU3D::SubmitPolygon`. Historical hardware samples put `SubmitPolygon` at 6.25% of the whole service and 13.7-15.3% of replay-thread samples, although those profiles predate some beta.7 work. The local ARM-target microbenchmark below measures this exact pair 3.343x faster. | Low: quotient range is bounded after clipping and every result is exactly corrected against integer division; malformed state retains stock division. | +208 bytes in `SubmitPolygon`; complete service binary +64 bytes; zero FPGA cost. | Exact equivalence, ARM disassembly, service self-test, then a same-scene MiSTer A/B of geometry-flush time and displayed frame cadence. |
| 2 | Retest an 8-pixel NEON block for the dominant cached opaque modulation path | The retained Mario Kart mode trace counted 7,957,557 cached-modulate scanlines, 99.1% opaque. The current beta.7 path batches perspective attributes and lookup indices in four lanes but still applies cached modulation lane by lane. The unmerged `experiment/steward-block-span-20260831` implemented an exact eight-pixel block, so this is retest-worthy rather than speculative new design. | Medium: batching must preserve depth rejection, alpha test, texture wrap, secondary-buffer behavior, and partial-span tails. | ARM code and temporary-lane storage only; zero FPGA cost. | Current beta.7 post-optimization `perf` attribution first, exact pixel/depth/attribute hashes, isolated block benchmark, then normalized `renderer_3d_raster_ns`. |
| 3 | Remove duplicate edge advancement when a four-band worker claims a nonadjacent band | `RenderRasterBandJobs` calls `AdvanceRasterContext` through skipped rows; telemetry already counts those rows as `renderer_3d_band_queue_advanced_scanlines`. This is intentionally duplicated work and can grow when worker completion is imbalanced. A direct boundary reconstruction could help the heaviest scenes if current hardware telemetry shows a material advanced-row count. | Medium-high: every mutable edge/interpolator and active-polygon bit must match sequential advancement, including clipped starts. | More ARM scratch state or boundary setup; zero FPGA cost. | First correlate advanced scanlines with raster time on a fixed scene. Require complete native color/depth/attribute oracle hashes for every band ownership order. |
| 4 | Fold shadow safety-prefix work into polygon-list preparation | Mario Kart's retained trace was 13.61% shadow-mask plus 12.61% shadow scanlines. `RasterBandQueueSafe` currently performs two full 192-line active-polygon traversals on a heavy shadow frame before rasterization. Reusing already-built scanline lists/prefix state could reduce setup and admit safe shadow frames more cheaply. | High: `PrevIsShadowMask` and parity-reused stencil rows are ordering-sensitive; an error produces visible corruption rather than a small numerical drift. | Small ARM prefix metadata; zero FPGA cost. | Profile `RasterBandQueueSafe` separately and count shadow fallbacks; require the existing shadow-band and shadow-gate oracles plus adversarial boundary fixtures. |
| 5 | Profile-guided ARM service layout/inlining | The service is statically linked with LTO, but no representative post-beta.7 PGO profile is applied. A profile can improve branch layout and inline decisions across replay/geometry/raster code without algorithm changes. | Low functional risk, medium representativeness risk: training on one game can regress another and stale profiles are misleading. | ARM binary/layout only; zero FPGA cost. | Train and validate on multiple legally supplied traces; compare normalized replay, geometry, raster, and publication times on held-out traces. |
| 6 | Compile out native-service-inactive high-resolution vertex work | The hybrid service disables high-resolution coordinates, but the shared `SubmitPolygon` binary retains the conditional high-resolution path and four 64-bit divide call sites. A service-specialized core build could reduce instruction-cache footprint, but the branch is already not taken. | Low-medium: the core library is shared by other host tools, so the specialization boundary must be explicit. | Smaller ARM text; zero FPGA cost. | Binary size and instruction-cache/perf counters; no FPS claim without a measured change. |

Two previously measured ideas should not be repeated without new evidence:

- Changed-tile plane copy was 2.04% slower than the fused full copy because
  83.51% of Mario Kart tiles changed.
- More transport synchronization, IRQ, or lightweight-bridge work is lower
  priority while the queue is healthy; the public SPSC/futex path already
  avoids the normal mutex/kernel transition.

## Implemented rank 1: exact paired viewport division

For each post-clip vertex, native melonDS computes X and Y with the same
positive `2*W` denominator. On Cortex-A9, upstream's two `/` expressions call
the fully general software divider twice. The new ARM-only path:

1. proves the architectural denominator and quotient bounds at runtime;
2. normalizes the denominator once to its leading ten bits;
3. reuses the existing 512-entry compile-time magic-reciprocal table for both
   coordinates;
4. calculates both estimates with `UMULL`;
5. corrects each against a widened exact product; and
6. falls back to the original operations if malformed state violates the
   post-clipping contract.

The desktop path retains upstream integer division because the x86 benchmark
has hardware division and is faster there. This avoids a host regression while
targeting the Cortex-A9 limitation.

## Exactness evidence

`tools/test_gx_clip_math.sh` passes on the host and ARM target runtime. It
checks:

- every quotient from 0 through 511 at representative reciprocal, shift, and
  24-bit boundary denominators with exact and adjacent remainders;
- 500,000 randomized valid numerator pairs against the language `/` oracle;
- the largest and midrange representable quotient at every denominator from
  1 through `0x00FFFFFE` (16,777,214 denominator values); and
- explicit malformed/out-of-bound fallback behavior.

The existing soft-renderer fast-divide regression also passes after moving the
already-retained tables into a shared header, proving the extraction did not
change the raster helpers.

The complete ARM service builds and passes all built-in service oracles,
including four-band raster, obsolete-raster cancellation, shadow-band and
shadow-fallback gates, texture round-trip, packet arena, and service lifecycle.

## Performance evidence

Three independent ARM-target benchmark invocations, each using seven
alternating medians over 2,097,152 valid viewport-pair calls, measured:

| Run | Stock two divides | Paired exact path | Pair speedup |
| --- | ---: | ---: | ---: |
| 1 | 187,007,042 ns | 55,493,250 ns | 3.370x |
| 2 | 186,694,000 ns | 55,843,500 ns | 3.343x |
| 3 | 187,816,458 ns | 56,491,541 ns | 3.325x |

Median pair speedup: **3.343x**.

This is an ARM-target compiler/runtime microbenchmark, not a MiSTer whole-game
FPS result. ARM disassembly confirms the normal `SubmitPolygon` path has one
shared `CLZ`/table lookup and four `UMULL` operations; its two `__udivsi3`
calls remain only in the cold malformed-state fallback. The function grows
from 6,268 to 6,476 bytes (+208), while the complete static service grows only
64 bytes (2,459,144 to 2,459,208 bytes).

Candidate ARM service:

```text
build-armhf-viewport-pair-3dnext/nds_hybrid_3d_service
SHA-256 9629ec9beba9ed4e26ea155f3286ec1bf1e2350e2f468128bcb3a435eaba2a2e
```

MiSTer A/B telemetry remains the acceptance gate before making any whole-game
speed claim or combining this branch with a public release.
