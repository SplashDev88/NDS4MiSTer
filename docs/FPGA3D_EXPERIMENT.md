# FPGA 3D experiment, 2026-11-07

Base: rc.14 commit `1cb66a5727549a5185d8a7460af18180eadb452e`.
This is a private experimental branch. The released core is untouched.
The FPGA project retains the exact QSF configuration from RC14's shipped
`components/dv1-yc-fpga-inputs.tar.gz` (source 4554f915). Repository defaults
omit three overrides that the released binary uses: GX SWAP retirement,
compact HBlank run storage, and GX busy status. Restoring those settings is
required to preserve the released geometry/transport behavior; source defaults
alone are not a faithful rebuild of the shipped bitstream. The separate source
archive comparison records the remaining accelerator and optional-source changes.

The target is hardware scanline rasterization with the existing ARM geometry,
texture decoding and 2D composition. The expanded F3D3 candidate supports opaque and translucent modulated or
untextured polygons, partial texture alpha, Z/W buffering, perspective and
linear interpolation, two-layer antialiasing, and fog. Unsupported frames
fall back in their entirety before submitting hardware work. Geometry, shadow
polygons, toon/decal modes, wireframe, edge marking, and bitmap clear remain
outside this accelerator. Capacity checks also retain whole-frame fallback.
Earlier F3D1 work is archived in a separate worktree. It exposed a Mario Kart compatibility regression from omitted release build settings; the current branch restores all three settings from the shipped RC14 FPGA configuration.

The rasterizer uses two layers of scanline color/depth/attribute RAM and
shared DDR. Opaque edge coverage advances only after passing depth and alpha
tests. Translucent blending checks polygon IDs independently on both layers,
with the native fog-flag conjunction and optional depth writes. Fog processes
both layers before antialiasing and preserves 32-bit depth-shift wraparound,
table interpolation, density 127-to-128 promotion, and alpha-only mode.
The F3D3 mailbox magic prevents mixing this helper with the earlier F3D1 or F3D2 cores.
The scanline clear descriptor carries render flags; a leading fog descriptor
holds the immutable color, offset, shift, and 34 density-table entries. Its nine-stage
exact perspective divider feeds a pixel pipeline, with one pixel per clock on
a texture-cache hit. A 512-entry direct-mapped texel-pair cache is invalidated
for every frame; a miss freezes the pipeline until its DDR response arrives.
Texture sizes and masks are latched once per descriptor to shorten the
coordinate-to-address timing path. Spans drain before the next descriptor
can change interpolation state. Actual fitting and hardware measurements are required; simulator
cycle rates alone do not establish full-speed gameplay.

Reserved matched-display-only memory (never cartridge storage):

| Physical range | Ownership |
| --- | --- |
| 0x3FC80000..0x3FC80FFF | Accelerator mailbox |
| 0x3FC81000..0x3FCFFFFF | Immutable command stream, 64-byte packed records |
| 0x3FD00000..0x3FD2FFFF | Completed 256x192 native-color output |
| 0x3FD40000..0x3FDFFFFF | Immutable decoded texture arena |

These reuse unused legacy graphics windows only in matched display mode.
Control and packet traffic through 0x3FC4FFFF and final paired framebuffers
at 0x3FE00000..0x3FFFFFFF retain their existing ownership.

Acceptance: differential RTL tests, malformed-command/address containment,
backpressure/reset testing, Quartus fit/assembly/timing inspection, hardware
oracle and throughput tests, and isolated-save game smoke tests. Until those
finish this directory is source work, not a qualified full-speed beta.

The control-port adapter retains one command independently of the outer grant.
It forwards physical acceptance separately from local enqueue and locks read
ownership through the last response. This prevents control requests from
becoming invisible under event burst-write and display contention. The tests
include all four clients, burst write/readback sequence checking, and negative
controls for premature acceptance, combinational grants, and disabled grant
probes under saturated traffic. The outer H3D fabric probes every enabled
client once per eight eligible transactions, rotating the probe owner. Priority
video still returns its borrowed grant before another probe turn is consumed.
This bounds access even for producers that wait for busy to drop before
advertising work. The packet writer holds each request through physical
acceptance, including write bursts with waitrequest asserted.
GPU source credit uses registered queue occupancy; an initially full queue
reopens on the cycle after a pop to shorten the sink-to-CPU timing path.

Completed rows use 128-beat DDR writes. The adapter retains the first beat,
then advances the scanline RAM only on physical acceptance. An enable loss
drains the accepted burst before resetting the renderer; tests interrupt
beats 1, 2, 63 and 127 and reject a deliberately broken abort implementation.

The ARM transport skips unused descriptor padding and uses aligned volatile
64-bit stores on the existing Device command mapping. Texture upload and
output copies use memcpy only when the existing publication mapping is WC;
the Device fallback retains scalar accesses. No physical pages acquire a
second mapping or a different owner. The transport test covers alignment,
maximum command capacity, both mapping paths and surrounding memory guards.

The physical command arena holds 8,128 packed 64-byte descriptors. Native fixtures
retain 128-byte logical commands and are packed by the same transport used on the
board. Perspective spans omit unused linear recurrence calculations; bounded
linear recurrences use an exact reciprocal and remainder correction. Narrow
linear spans that revisit the preceding pixel retain their original recurrence
through a shifted origin and scaled denominator, with whole-frame fallback when
the result cannot fit the hardware contract.

The C11 build was rejected before installation because the two-product blend
path missed setup timing. Blending, fog, and AA now use the equivalent signed
form `destination + ((source - destination) * weight >> shift)`. An exhaustive
RTL test covers 663,552 channel combinations. Secondary color and primary
attributes each use one scanline RAM; the primary color remains banked for
64-bit burst output. Timing still requires a fresh four-corner hardware build.

C13 compatibility isolation: C12 passed four-corner accelerator timing, 238
synthetic hardware frames, and 81 native game-frame pixel comparisons, but
both NSMB and Mario Kart displayed black screens while source-frame counters
continued. NSMB was also black with acceleration explicitly disabled. The
same C12 helper displayed NSMB correctly with the original released FPGA.
This diagnostic build retains compact HBlank storage, disables the two GX
retirement/busy overrides, and exposes existing ARM9 PC telemetry. These are
isolation settings; this candidate is not qualified until visual gameplay
and actual published-frame measurements pass. Raster RTL is unchanged from C12.
