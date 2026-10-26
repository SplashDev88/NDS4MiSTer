# Runtime optimization patterns

Reuse `tools/standalone_host/fmv/hook_guard.py`, `prepare.VirtualRom`, the existing native ARM9 PC sampler and graphics-replay tests. These entries are evidence and admission rules, not permission to patch another title automatically.

## Redundant graphics state within a primitive

Detector: repeated writes of the same value to a graphics register with only vertex/texture-coordinate submissions between them. Classify the complete dependency set first. Castlevania ACVE r0 writes NORMAL four times per background quad at `0x02004280`; its two static callers are `0x02003dfc` and `0x020041fc`.

Do not infer redundancy from equal command values alone. NORMAL also changes lighting and, in texture mode 2, texture coordinates. Matrices, materials, lights, active light masks and shininess are dependencies. Removing commands changes pipeline timing even when all pixels match. The three-NOP Castlevania trial passed 3,000 video frames but failed RAM/audio equivalence and was rejected.

Exact alternative tested and rejected for insufficient native gain: memoize the pure lighting calculation in the existing HPS interpreter while retaining each command, texture-coordinate side effect, pipeline update and cycle charge. Invalidate conservatively on every command outside the proven color/normal/texcoord/vertex whitelist, on reset and on GPU restore. This generalizes to games using the same graphics API without needing guest addresses.

## Repeated asset content is not unchanged content

Detector: decoded texture hashes that return to a small set of values. The cave backgrounds alternated between two actual palette results in a 25-input capture. A monotonic revision is safe for invalidation but cannot recognize a returning content state. A hash alone cannot authorize exact reuse: retain and compare the actual source bytes.

Reject unconditional palette-upload suppression. Precompute/cache only after matching all content and rendering dependencies. Include allocation, matching, copying, changing frames and dual-core synchronization in the cost model; repeated frozen frames alone are not an acceptance benchmark.

## Native waiting versus reference instruction counts

Reference instruction sampling identifies executed loops. Native PC sampling measures observed wall time, including halt/DMA periods. Neither is a cycle counter. For ACVE the first cave capture observed 37.2% halted samples; the native geometry stream already submitted about 60 frames/s while completed screen publications were about 21.3/s. Prioritize the limiting stage, not the largest reference loop by itself.

## Opaque draw order and hidden pixels

Detector: long runs of opaque, constant-depth, screen-aligned rectangles, interrupted by translucent effects or other ordering dependencies. A nearest-first order can let existing depth tests reject hidden shading, but can also turn a vectorized write into a slower scalar rejection. Measure on the target CPU.

An experimental conservative predicate requires unchanged color, rectangular corners, opaque supported texture formats, ordinary depth testing, and no fog/edge-marking/clear-image effects. Sort pointers, not large raster state objects; keep ties stable and preserve unsafe barriers. Test randomized depths, polygon IDs, equal-depth operations, AA state changes and the original scene replays. A four-pixel rejection is valid only when every source pixel is strictly farther and none has a live lower AA layer.

## Resident decoded variants

A returning palette state can reuse the already decoded texture in its original allocation. Record all source ranges at decode, including wrapped texture data, auxiliary compressed data and the palette. Compare the small palette first, then every relevant source byte. On a hit, restore the complete cache entry and its identity; on eviction, return storage through the original free list. Limit memory and preserve reset/remap semantics. This avoids decoding an image merely to discover that it matches a prior image.

## Sparse callback-table traversal is not idle polling

Detector: a bounded loop with a constant record stride, a nullable loaded function pointer and an indirect call, rather than a fixed MMIO address. In ACVE runtime RAM, `0x020126f4` and `0x020128e4` traverse 0x110 records with stride 0x2a0. The second loads `[r5]`, skips nulls and calls `blx r1`; the first also checks `[r5+4]` and flags at `[r5+0xc]`. These account for the two previously unresolved >2% native PC sample sites, but samples are not cycle shares.

An active-record index could reduce empty scans only if every registration, deletion and reordering operation is captured and callback order remains identical. Treat an object-update role as an inference until symbols or write watches establish it. Do not replace this with halt or skip callbacks. It is not the current throughput priority while geometry already runs near 60 submissions/sec.
