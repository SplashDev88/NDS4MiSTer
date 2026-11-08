# FPGA 3D experiment, 2026-11-07

Base: rc.14 commit `1cb66a5727549a5185d8a7460af18180eadb452e`.
This is a private experimental branch. The released core is untouched.

The target is hardware scanline rasterization with the existing ARM geometry,
texture decoding and 2D composition. Initial compatibility is deliberately
bounded: opaque modulated or untextured polygons, binary texture alpha,
Z/W buffering, perspective and linear interpolation. Unsupported frames must
fall back in their entirety before submitting hardware work. Geometry, shadows,
translucency, antialiasing, fog and edge marking are not claimed as FPGA features.

The rasterizer uses scanline color/depth RAM and shared DDR. Its nine-stage
exact perspective divider feeds a pixel pipeline, with one pixel per clock on
a texture-cache hit. A 512-entry direct-mapped texel-pair cache is invalidated
for every frame; a miss freezes the pipeline until its DDR response arrives.
Spans drain before the next descriptor can change interpolation state. The baseline has 35,094/41,910 ALMs and
538/553 M10Ks. Actual fitting and hardware measurements are required; simulator
cycle rates alone do not establish full-speed gameplay.

Reserved matched-display-only memory (never cartridge storage):

| Physical range | Ownership |
| --- | --- |
| 0x3FC80000..0x3FC80FFF | Accelerator mailbox |
| 0x3FC81000..0x3FCFFFFF | Immutable command stream, 128-byte records |
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
controls for premature acceptance, combinational grants, and hidden requests.
GPU source credit uses registered queue occupancy; an initially full queue
reopens on the cycle after a pop to shorten the sink-to-CPU timing path.
