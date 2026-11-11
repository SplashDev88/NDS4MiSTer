# FPGA 3D experiment, November 2026

This private branch adds FPGA scanline rasterization to the RC14 core. ARM
still performs geometry processing, texture decoding and 2D composition.
The released kit and original saves are preserved. This source is a candidate;
only a report for its exact bitstream/helper hashes can qualify the beta.

Supported raster work includes opaque and translucent modulated or untextured
polygons, partial texture alpha, Z/W depth, perspective and linear interpolation,
two-layer antialiasing, fog, decal texturing, shadow masks/polygons, toon/highlight
shading, and edge marking. Wireframe, bitmap clear, unsupported shadow modes,
and work exceeding the memory contract use the
original software renderer. No approximation or partial image is published.

## F3D6 producer and memory ownership

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
# CPU admission policy experiment (2026-11-08)

The live helper retains streamed command submission. Frames with at least
32 polygons but fewer than 32,768 estimated bounding-box pixels use the exact
native renderer before any FPGA ownership or texture upload. Small 3D models
do not necessarily repay the full-plane clear, resolve, and transfer cost.
After a late unsupported span or command-capacity failure, 60 subsequent
eligible render attempts use native rendering before trying the FPGA again.
Reset clears this retry counter after joining the render worker. This changes
renderer selection only; it does not approximate pixels or drop source frames.
Simple demos and heavier supported scenes retain FPGA rendering. This policy
is not a claim that geometry or all game scenes run in FPGA or at full speed.

# Scanout deadline correction (2026-11-08)

Live HDMI capture reproduced stretched, repeated scanlines with both FPGA
rendering and software rendering on C21. A completed HPS framebuffer alone
does not verify the displayed picture. C24 changes the two arbitration levels
that serve scanout; the renderer, video raster, framebuffer layout and clocks
remain the C21 versions.

The cartridge controller can acknowledge a requested word before its four-word
read-ahead completes. A subsequent cartridge miss may therefore be queued at
every idle edge. Pending channel-six display reads now take priority over that
traffic at transaction boundaries. The outer H3D fabric also receives the
pending-display hint before the busy-dependent legacy controller can advertise
its DDR command. Existing read and write bursts always finish before a grant
changes. Without the hint, saturated visible peers can leave the display
waiting for the periodic probe of an invisible legacy request.

Run `python3 tools/test_scanout_contention.py --output <directory>` to check
the real controllers and the full dual-output pixel path. The deadline test
checks exact read data and event-write ordering; disabling either correction
reproduces a missed display deadline. The integrated test checks every visible
pixel across 16 layout/order/analog-screen combinations with simultaneous
cartridge, accelerator and event traffic, plus the old-arbitration negative
control. Physical HDMI qualification is recorded separately with the built
core hash; simulation is not a substitute for that check.

The user authorized functional hardware testing without a static timing gate.
Timing reports remain diagnostic evidence. Earlier timing-based rejections
above describe their historical disposition, not the current acceptance rule.

## FPGA preparation CPU placement (2026-11-08)

On C24, the NSMB World 3 map published 15.87 and 16.07 completed frames/s
in repeated CPU0 controls. Moving only the existing raster thread to CPU1
raised the same scene to 26.07 frames/s; allowing either CPU measured 25.48.
These were diagnostic placement trials, not a new qualified release.

FPGA span preparation now temporarily uses CPU1 after feature admission.
It restores the caller's affinity on every return, including texture rejection,
timeout, and software fallback. Native two-worker rasterization therefore
retains its existing CPU split. The C24 bitstream, scanout priority, rendering
math, and frame publication rules remain unchanged. ARM tests check affinity
restoration along with exact fallback pixels. A rebuilt-helper gameplay result
is required separately; no 60 FPS commercial-game claim follows from this change.


## Commercial-game CPU work (2026-11-08)

The compiled scoped-placement helper measured 24.83 completed frames/s in the
same NSMB World 3 map, versus the average 15.97 baseline. Separating FPGA
emission from the native pixel loop measured 24.56, with no additional gain.
Recycling each uploaded CPU command row measured 25.26. Published physical
FPGA descriptors remain immutable; capacity accounting includes all previously
published commands. Actual-RTL tests cover capacity exhaustion after many
publications, cancellation, prefix ownership and 4 KiB boundaries.

The next candidate caches exact complete polygon command rows. The key stores
explicit rendering flags, texture layout and current physical binding, plus
all final vertex positions, colors, texture coordinates, W and Z. It compares
values rather than pointers or hashes. Current texture contents still upload
every frame. Shadow polygons retain the original producer. Incomplete rows
never become reusable; software fallback reconstructs all edge state. Retained
command capacity is bounded and old entries are discarded when that bound is
reached. CPU command reuse is separate from FPGA descriptor ownership.

The cache test compares warm frames against the cold producer and complete
native fallback pixels, changes each vertex/render input category, updates
texture bytes without changing the binding, and interrupts production before
recovery. Hardware FPS and HDMI checks are required before qualifying this
candidate. The commercial-game 60 FPS goal is not yet met.


The first logical-span cache (C28) measured 24.09 FPS on that map and was
rejected as a performance improvement. It copied too much command history.
C29 instead caches the FPGA-ready 64-byte descriptors and keeps only the
current packed scanline in the live producer. Cache hits bypass descriptor
packing. Batch fixture generation retains the readable 128-byte logical ABI.
The physical descriptor budget, immutable prefix and completion fences are
unchanged. Tests compare logical, packed and actual RTL memory paths,
including unknown opcodes, cancellation and cumulative capacity exhaustion.

C29 measured 25.13 completed frames/s on the same map, within the range of
C27 rather than an additional material improvement. C30 matches exact span
inputs across polygon reordering and rebinds reused descriptors to each
frame's fresh texture allocation. A hash selects a lookup bucket only; the
full input key must match. Both cache generations have a combined retained
capacity bound. The expanded 360-case test covers reordered geometry and
texture allocation changes in logical and streaming descriptors, fresh
texture bytes, and exact software fallback. All 706 native fixture files
remain byte-identical; 235 first-row timeouts, 192 shadow cases, transport
checks, actual RTL streaming negative controls, and the full service self-test
pass. C30 hardware performance and display qualification remain pending.

## C31 commercial compatibility candidate

F3D6 adds a third row of top depth/attributes for exact four-neighbor edge
marking. The previous row is resolved after its lower neighbor is rasterized;
edge marking precedes fog and antialiasing. Original native dirty bounds are
carried on each flush, including exceptional thin spans. Clear-border depth,
polygon ID and the eight edge colors are explicit frame configuration.

Decoded textures with at most 256 distinct RGBA values use a lossless palette
and byte indices. Textures with more colors remain raw. Every frame rebuilds
its contents; cached commands rebind both the physical address and encoding.
The 768 KiB texture arena and command publication boundaries are unchanged.
Toon/highlight tables are uploaded when used. Exceptional perspective spans
use native per-pixel attribute/depth setup, while FPGA texture sampling,
depth tests, shading, blending and coverage remain active.

The first synthesis passed, but fitting exceeded available logic blocks.
The candidate now uses a 2 KiB texture cache (32 lines of 64 bytes), releasing
six M10Ks for top/lower pixel attributes previously held in distributed RAM.
Indexed textures retain the same number of cached texels as the former 8 KiB
RGBA cache; raw textures have less cache capacity. This tradeoff requires
measurement on hardware. Core/helper pairing is mandatory; F3D5 is rejected.
Hardware correctness, visible output and game performance remain unqualified
until measured against the exact candidate hashes. No 60 FPS claim follows
from the new feature coverage.

C31 passed 621 hardware reference frames (30,523,392 pixels and 98,304 stencil
bytes), and the textured demo maintained 59.64 paired publications/s. Platinum
in Twinleaf Town used the FPGA continuously but fell to 18.27 publications/s
from the C24 baseline of 20.78. Its static spans were fully cached, while the
helper still waited about 26.5 ms for FPGA completion with indexed textures.
The next helper prefers raw texels when all unique decoded textures and the
full write-combined command budget fit together. Larger scenes keep lossless
indexed admission. This avoids palette loads without reducing supported
features or expanding the physical memory contract. Its performance requires
a new measured comparison; it uses the already-fitted F3D6 core.

## C32–C35 measured admission policy

C32's raw preference raised the Twinleaf Town comparison to 23.97 completed
publications/s (+15.3% versus C24), with matching FPGA completions. Indexed
admission also moved Dawn of Sorrow's first save room onto the FPGA, but its
18.15 publications/s regressed from the 48.34 native baseline.

C33 uses spare texture space for raw bindings, prioritizing scanline reuse
per added byte. C34 caches lossless encodings only after comparing every
current source byte against a retained snapshot, with a 4 MiB data limit and
512-entry limit. Recycled pointers and palette animation cannot reuse stale
encodings. Fresh physical texture bindings and ownership fences are retained.

C34 also preserves the native cached shader's unsigned color packing for
extrapolated narrow spans, including overflow between packed components.
Thirty-two new production scenes matched actual RTL and physical FPGA output
for 1,572,864 pixels; the 429 earlier fixture sets remain byte-identical.
This removes an observed Mario Kart span rejection without clamping colors.

These changes are functionally correct but do not make every hardware path
faster: C34 measured 26.47 publications/s in Dawn's save room and 19.18 in
Mario Kart's stationary 50cc Figure-8 race, versus C24's 48.34 and 23.00.
Both measured scenes ran essentially entirely on FPGA. Texture packing,
Device-memory command uploads, and FPGA texture traffic remain substantial.

C35 therefore defaults to native rendering when unique decoded texture data
exceeds 266,240 bytes: the space left after reserving all 8,128 descriptors
in the existing 768 KiB write-combined arena. Rejection occurs before texture
copying or hardware ownership. It does not depend on a game name. Smaller
supported scenes retain the FPGA path. The service-only diagnostic setting
`NDS4MISTER_FPGA3D_ALL_SUPPORTED=1` disables this performance guard for further
qualification; normal launchers do not enable it. The encoder, indexed FPGA
support, and exact software fallback remain available. C35 live measurements
are required before release; full-speed commercial 3D remains unfinished.

C35 retained 23.60 publications/s in Twinleaf Town, but its native Dawn path
measured 44.36. C36 moves the texture-budget decision before CPU1 preparation
affinity: a rejected frame must stay on its original CPU instead of competing
with the native raster worker after restoring an unrestricted affinity mask.
Eligible FPGA frames still use scoped CPU1 preparation. C36 needs its own
live comparison before this scheduling correction is qualified.

## November 10: native-resolution texture residency experiments

Two default-off experiments retain native pixels and guest graphics effects:
`NDS4MISTER_FPGA3D_TEXTURE_RESIDENCY=1` compares an exact CPU shadow and
uploads only changed texture runs after validating session, mapping, writer,
and completed-mailbox ownership. `NDS4MISTER_FPGA3D_PREPARED_TEXTURES=1`
reuses a prepared texture set only when every current source byte and source
size matches. Polygon order and row-use counts may change without rebuilding
the lossless raw/indexed bindings. Source snapshots are bounded to 4 MiB.

The prepared helper is built from
`2a7c3ce68a7c0c5243e13cb42aa4ee627a9a3c34`; its SHA-256 is
`67a820ba852e38536484442aa1e1828cf16bc1ce30ec535aee9a00328d65eb11`.
The unchanged F3D6 core is
`1b107bee976bfb893e72c4b5518f846c27c3e91b426f3f88799fca58f39cd680`.
Neither experiment changes FPGA clocks, geometry, resolution, or guest effects.

Each admitted scene has one 30-second window per arm, at 1 GHz, with frozen
private saves and before/active/after screenshots. These are completed display
publications per second, not unique-animation counts or RC15 Beta5 AA-Off
measurements. Small differences remain provisional; no repeat rounds were run.

| Scene | Software | Existing FPGA | Residency + prepared cache |
| --- | ---: | ---: | ---: |
| Mario Kart, stationary 50cc Figure-8 race | 25.83 | 19.26 | 21.10 |
| Dawn of Sorrow, save room | 46.03 | 27.30 | 24.16 |
| NSMB, World 3 map at the tower | 14.43 | 22.10 | 21.16 |

Residency alone measured 18.80 in Mario Kart, despite avoiding 99.86% of texture
writes. Adding prepared-set reuse reduces its texture preparation from 8.99
to 3.98 ms per accepted frame and raises the FPGA rate by 9.53%, but software
remains faster. Dawn's prepared-cache hit rate is only 25.33%; preparation grows
from 5.67 to 8.57 ms and FPS regresses 11.49%. NSMB's candidate loses 4.24%
against the existing FPGA path, even though both beat the software control.
No new variant beats the fastest existing path, so neither is enabled in the
current beta. RC15 Beta5 and its installed payload remain unchanged.

The transfer counts expose another lead: NSMB stages 215,808 texture bytes and
fits commands in the write-combined arena. Mario Kart and Dawn stage roughly
784,384 and 773,120 bytes respectively, forcing Device command
storage. Their upload timings include command writes and must not be treated
as texture-only transfer time. A dedicated fast command path for texture-heavy
scenes and workload-aware renderer selection warrant further experiments.

Validation includes the residency ownership/transition oracle, ARM admission
and helper self-tests, 36 production renderer fixtures, and both batch and
streamed RTL playback: 3,538,944 exact native-pixel comparisons. Texture/palette
mutation, resizing, reordered/moving geometry, mixed raw/indexed bindings,
native timeout fallback, and early-timeout recovery are covered. All accepted
hardware windows have zero protocol faults and stable session epochs. No new
FPGA timing-closure claim is made for the inherited F3D6 core.

Evidence and exact per-run fingerprints are retained in
`evidence/native-fpga-residency-20261110`. The cave profile is a separate
command-capacity fallback case. An incorrectly admitted menu window and a
startup image with zero publication sequence were excluded. Scene admission
now checks current-session publication before recognizing retained DDR pixels.


## RC15 integration and separate WC commands, November 10

The `experiment/rc15-fpga-command-20261110` branch merges RC15 Beta5's
renderer and display controls. FPGA command emission and polygon-cache keys
use `EffectiveDispCnt`, so the saved AA switch has the same meaning on both
renderers. Half Rows, quarter, tiny and disabled 3D retain the software path.
Cache-line streaming and registered GPU queue credit are integrated; the
working C36 HBlank/SWAP/busy synchronization configuration remains in place.
This combination still requires a new physical build and game qualification.

F3D7 adds a separate write-combined command arena. The flag
`NDS4MISTER_FPGA3D_FAST_COMMANDS=1` selects it only when textures are too large
to leave room for the complete command budget in the existing texture arena.
It is off by default pending measurement. Small frames keep their existing WC
command layout; Device mapping fallback keeps the Device arena. Conservative
FPGA admission and both experimental texture caches keep their prior defaults.

Every full-frame screen occupies 0x30000 bytes within its 0x40000-byte stride.
Across four paired banks, eight 64 KiB padding segments remain. Reserve the
first 4 KiB at 0x3FE30000 for existing optional telemetry. The other 520192
bytes hold all 8128 immutable 64-byte commands. For command index `i`, let
`slot=i+64`; its physical address is:

```
0x3FE30000 + (slot / 1024) * 0x40000 + (slot % 1024) * 64
```

Mailbox word 15 selects this layout only with the exact value `0x3FE31000`.
The final record ends at `0x40000000`. No descriptor touches visible pixels,
textures, or the telemetry reservation. Both mappings remain unchanged, so
there are no Device/WC aliases. The existing prefix fence, 4 KiB fetch boundary,
capacity limit, session check, cancellation drain and timeout quarantine apply.
The matched-display core disables ordinary FPGA framebuffer drains from reset;
the HPS publisher writes exactly 192 rows. The optional runtime telemetry
writer is confined to the reserved first page even if separately enabled.

The new physical candidate also registers the decoded texel and toon color
between cache/palette lookup and color arithmetic. Position, depth, validity,
early-depth result and attributes advance with that extra stage, using the
same stall enable. Pixel-store depth metadata receives the matching delay.
This addresses the C36 cache-to-color setup path; it does not approximate
colors or alter the command ABI. Physical timing must establish the benefit.

Validation includes full-capacity CPU/RTL streaming and batch submission while
the actual two-screen publisher writes all four banks, preservation of texture
and telemetry bytes, independent command-address checking, and deliberately
broken telemetry, segment-stride and unpublished-prefix implementations.
Eighteen live-AA fixtures use the production control mapping, unchanged-guest
AA transitions, an independent native renderer and timeout recovery. Reduced
and disabled modes have 24 checks that acquire no FPGA ownership. Existing
cache-stream, credit, publication and renderer oracles remain required.

Exact build hashes, timing gates and results belong to
`evidence/rc15-fpga-command-20261110` in the enclosing workspace. Source or
simulation success alone is not FPS evidence or permission to replace Beta5.
