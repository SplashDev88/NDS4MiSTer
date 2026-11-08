# FPGA 3D experiment, November 2026

This private branch adds FPGA scanline rasterization to the RC14 core. ARM
still performs geometry processing, texture decoding and 2D composition.
The released kit and original saves are preserved. This source is a candidate;
only a report for its exact bitstream/helper hashes can qualify the beta.

Supported raster work includes opaque and translucent modulated or untextured
polygons, partial texture alpha, Z/W depth, perspective and linear interpolation,
two-layer antialiasing, fog, decal texturing, and shadow masks/polygons. Toon mode, wireframe,
edge marking, bitmap clear, and work exceeding the memory contract use the
original software renderer. No approximation or partial image is published.

## F3D5 producer and memory ownership

| Physical range | Ownership |
| --- | --- |
| 0x3FC80000..0x3FC80DFF | Accelerator mailbox |
| 0x3FC80E00..0x3FC80FFF | Immutable 512-byte initial stencil state |
| 0x3FC81000..0x3FCFFFFF | Device command arena for batch callers |
| 0x3FD00000..0x3FD2FFFF | Completed 256x192 native-color output |
| 0x3FD30000..0x3FD301FF | Completed 512-byte stencil state |
| 0x3FD40000..0x3FDFFFFF | Immutable decoded textures followed by WC commands |

These are reserved matched-display graphics windows. Packet/control storage
and final paired framebuffers at 0x3FE00000..0x3FFFFFFF retain their ownership.
The existing Device and write-combined mappings are reused; no physical page
receives a conflicting alias. Logical fixture commands remain 128 bytes and
are packed into 64-byte records for the FPGA.

F3D5 magic prevents mixed helpers and bitstreams from submitting work. Mailbox
word 15 carries the aligned command base. The low 31 bits of word 2 publish
an immutable command prefix; bit 31 closes the producer. Textures and initial
metadata are visible before the sequence commit. Each scanline's packed
commands become visible before its prefix count advances. Hardware validates
the base, capacity, monotonic count, session and texture/command separation.
It waits when the published prefix ends, and reads at most 16 published
commands per burst without crossing a 4 KiB page. An open producer cannot
complete, even after line 191.

Feature admission occurs before starting hardware. If later span preparation
or capacity admission fails, the producer closes and drains its partial work;
the full frame is then rendered in software. Only complete successful output
is copied into the software renderer. A timeout quarantines the entire session
so command and texture bytes cannot be reused while the FPGA may still own them.
An accidentally abandoned active Frame also quarantines its session.

WC uploads overlap scanline preparation with rendering. Frames whose textures
leave insufficient WC space for all 8,128 descriptors use the separate Device
command arena, retaining F3D3's full admission capacity while streaming.
Device-only callers use that arena in batch mode. Telemetry distinguishes
CPU upload time, the remaining wait after closing the producer, and output copy
time. Completed paired-frame publication, not guest source-clock progression,
is the measure used for displayed-frame throughput.

## Raster pipeline and shared DDR

The exact nine-stage perspective divider feeds the pixel pipeline. Early depth
checks on both layers reject hidden fragments before texture access. An 8 KiB
cache stores 64-byte texture lines, fetched with eight-beat DDR reads and
invalidated for each frame. Descriptor prefetch is bounded by the CPU's
published prefix. Spans drain before their interpolation state can change.

Opaque edge coverage advances only after passing depth and alpha. Translucent
blending checks both layers' polygon IDs independently, with native fog flags
and optional depth writes. Fog resolves both layers before antialiasing,
including the native shift wraparound and density 127-to-128 promotion.
Blending uses the exact signed expression
`destination + ((source - destination) * weight >> shift)`; an exhaustive RTL
check covers 663,552 channel combinations.

Completed rows use 128-beat DDR writes. The control-port adapter separates local
enqueue from physical acceptance and retains read ownership through the last
response. Accepted writes and long reads drain across enable loss. The outer
fabric provides bounded rotating grant probes under saturated event, cartridge,
control and display traffic. Packet writes hold their payload until acceptance.
GPU source credits use registered occupancy to shorten CPU backpressure paths.

## Compatibility and validation

C12 and C13 passed accelerator timing but failed visual game startup, including
in software-only mode. C13's ARM9 telemetry showed a shared startup-ready polling
loop. The same new helper booted both NSMB and Mario Kart with C8's FPGA.
This candidate returns to C8's legacy HBlank storage, leaves GX SWAP retirement
and busy overrides disabled, and removes the diagnostic PC sampler from the
build. These controlled comparisons establish a working reference, but do not
identify compact HBlank storage as the sole cause; placement and inherited
whole-core timing also differ. Actual visual gameplay checks are still required.

Validation includes native software-renderer fixtures, streamed prefix and
address guards, shared-fabric contention, reset and enable-loss interruption,
CPU-to-RTL producer tests, and negative controls that deliberately violate
publication or cancellation. Native tests also force a timeout after the first
row and compare the complete software fallback image. Final acceptance requires
Quartus fit and four-corner accelerator timing, exact hardware pixel comparison,
visual game startup and gameplay, and measured completed-frame publication.
Simulator cycle rates alone do not establish full-speed gameplay. The inherited
whole-core timing failures remain a limitation; this experiment does not
claim general timing closure or full-speed compatibility with every DS game.

C14 synthesis expanded the descriptor prefetch RAM into 8,192 flip-flops and
failed device capacity. C15 uses one explicitly multiplexed synchronous RAM
read port, and doubles texture cache capacity to 8 KiB. Both changes require
fresh synthesis, pixel comparisons, and hardware qualification.

C15 fitted but failed accelerator setup timing by 0.710 ns and was not deployed.
C16 removes the resolve-mode selector from the raster depth-comparison path;
fog and antialias resolve read their own synchronous RAM outputs directly.
It preloads the next published descriptor while rasterizing the current one,
with one explicit command RAM read port and cancellation at short commands.

F3D5 uploads both stencil parity rows before starting a frame and copies the
completed stencil back only after successful color output. One additional
M10K stores two stencil bits and a 14-bit clear-generation tag per pixel.
Opcode 5 clears the current parity row in constant time; bounded command
capacity prevents generation wrap. Masks preserve the native two-layer depth
rules, and shadow blending preserves both opaque and translucent polygon-ID
rejection. Whole-frame software fallback restores mask-group state before
retrying. Synthetic fixtures compare pixels, stencil, and timeout recovery;
private game captures remain outside distributed artifacts.
