# Architecture

Status: Unreleased HPS Engine B development branch based on Public Beta
v0.3.0-beta.6.

## Goal

NDS4MiSTer is an experimental Nintendo DS implementation for the MiSTer
DE10-Nano. The current design keeps the timing-sensitive console in FPGA logic
and uses the HPS for the parts that have proved too expensive to fit and run
well in the fabric: Nintendo DS 3D geometry/software rasterization and the
second 2D engine.

This replaces the project's original HPS-first benchmark architecture. The
current branch does **not** run the two DS CPUs, DMA, Engine A, sound, or
cartridge emulation in a headless melonDS instance.

## Current hardware/software split

| Subsystem | Current owner | Notes |
| --- | --- | --- |
| ARM9 and ARM7 CPUs | FPGA | FPGAzumSpass's GBA ARM7 implementation was the basis for the ARM9 work. |
| System timing, interrupts, IPC, timers, and DMA | FPGA | The FPGA remains the time authority. |
| Main memory, cartridge, VRAM mapping, palette, and OAM | FPGA | ROM data lives in MiSTer DDR; architectural memory behavior remains in the core. |
| Engine A 2D and HBlank/HDMA effects | FPGA | Includes the per-scanline effects used by games such as New Super Mario Bros. |
| Engine B 2D | HPS | The service reconstructs it from ordered FPGA register, palette, OAM, VRAM, and LCD-phase events. |
| 3D geometry and rasterization | HPS | A small service replays ordered FPGA events into melonDS's 3D engine and publishes completed 3D planes. |
| 2D/3D composition and final frame publication | FPGA plus HPS | FPGA merges 3D into Engine A; HPS publishes Engine B; FPGA atomically selects the physical top/bottom pair for scanout. |
| Sound | FPGA | GPL-licensed Nitro_DarkSide sound engine, built with `SOUND_ENABLE=1`. |
| Cartridge saves | FPGA plus MiSTer file interface | Profiles are generated from the vendored melonDS ROM database. |
| Input, OSD, scaling, and HDMI | FPGA/MiSTer framework | The current path is designed for reliable scaled HDMI output, including LG C-series TVs. |

## High-level data flow

```text
                     MiSTer HPS/Linux
               +-------------------------+
               | hybrid video service    |
               | melonDS GPU3D + GPU2D-B |
               +------------+------------+
                            ^ |
            ordered GPU/VRAM| |3D plane + Engine B screen
                      packets| v
                    +--------+--------+
                    | shared DDR/H3D1 |
                    +--------+--------+
                             ^
                             |
+----------------------------+-----------------------------+
| FPGA Nintendo DS console                                 |
| ARM9/ARM7 -> memory/DMA/cart -> Engine A 2D + 3D merge   |
|                         -> sound -> saves -> pair/scanout |
+----------------------------------------------------------+
                             |
                             v
                   MiSTer scaler, OSD, HDMI
```

The HPS renderer is a coprocessor, not the console's clock or memory owner. A
slow 3D result must not reorder CPU-visible writes or change the FPGA's DS
timeline.

## ROM loading and boot

The MiSTer file picker loads an `.nds` image into HPS DDR at physical address
`0x30000000`. The current file interface supports images up to 128 MiB.

The FPGA reads the cartridge header, copies the ARM9 and ARM7 program sections,
creates the direct-boot environment, writes the initial CPU state, and then
releases both CPUs. Redistributable melonDS FreeBIOS implementations provide
the direct-boot software interrupts; commercial Nintendo BIOS or firmware
dumps are neither required nor distributed.

After boot, the FPGA cartridge interface continues to read the ROM image from
DDR. Its bounded sequential read-ahead fetches 64 words with eight DDR commands
instead of the prior 32 in the focused host regression. Cartridge-access
latency remains a known bottleneck and can still cause assets or effects to
appear late or fail to load in some games.

## Hybrid 3D path

The Hybrid 3D ABI is named H3D1. The complete wire contract is documented in
[`hybrid-3d-abi.md`](hybrid-3d-abi.md).
The service ownership, launcher, and guarded-update procedure are documented
in [`hybrid-3d-hps-lifecycle.md`](hybrid-3d-hps-lifecycle.md).

### Command transport

1. The FPGA captures normalized GX commands, GPU register writes, virtual VRAM
   writes, and VRAMCNT writes.
2. Events are merged in DS-clock order and placed into committed packets. The
   transport cannot legally drop, duplicate, or reorder an accepted event.
3. The HPS service applies each packet to a ROM-less melonDS GPU/VRAM mirror.
   Sparse LCD markers and scanline-tagged writes preserve Engine B timing.
4. At the terminal packet for a frame, melonDS runs geometry and the software
   rasterizer for a complete 256x192 3D plane.
5. HPS also renders GPU2D-B scanlines and routes them to the physical top or
   bottom screen selected by the DS screen-swap state.
6. HPS writes inactive 3D and Engine B banks, performs cache maintenance and a
   release barrier, then publishes one composite descriptor last.
7. FPGA adopts only a complete descriptor, feeds tagged 3D pixels into Engine
   A as BG0, and pairs the complete Engine B screen at a scanout boundary.

The service renders only the missing Engine B path. Engine A and its native
HDMA remain in FPGA logic, avoiding a redundant full 2D shadow.

### Shared DDR layout

| Region | HPS physical address | Size and use |
| --- | ---: | --- |
| H3D1 control header | `0x3FC00000` | Session, ownership, packet/frame sequences, faults, and heartbeats. |
| Four packet slots | `0x3FC10000..0x3FC4FFFF` | Four 64 KiB ordered event packets. |
| 3D plane bank 0 | `0x3FD00000` | 256 KiB inactive/active 3D image bank. |
| 3D plane bank 1 | `0x3FD40000` | 256 KiB inactive/active 3D image bank. |
| Engine B screen bank 0 | `0x3FD80000` | 256 KiB inactive/active physical-screen image bank. |
| Engine B screen bank 1 | `0x3FDC0000` | 256 KiB inactive/active physical-screen image bank. |
| Final framebuffer banks | `0x3FE00000..0x3FFFFFFF` | Four 512 KiB banks for complete paired-screen frames. |

The four packet slots provide frame-scale slack. Backpressure propagates to the
original GPU or VRAM source if all slots are occupied, preserving lossless
architectural ordering.

### 3D composition

When Engine A enables 3D BG0, the published plane replaces the normal BG0
pixel input. Engine A still applies background priority, window masks, alpha
blending, color effects, and master brightness. A pixel with zero alpha is
transparent.

A line is accepted only when its session, frame, bank, and Y tags match the
current descriptor. A late or stale line becomes transparent rather than
stalling the 2D engine or displaying data from the wrong frame. This protects
2D correctness, although heavy 3D scenes can still show missing geometry or
fall behind.

## Frame publication and video

The FPGA drains Engine A into the normal final-framebuffer path. A composite
HPS descriptor supplies the complete Engine B physical screen from a separate
double buffer. Scanout adopts both only at a video frame boundary and stages a
full DDR line before promotion, so a late read cannot expose a partially
fetched line.

The release uses MiSTer's scaled HDMI path with nearest-neighbor integer
scaling and a compact scaler-only shell. The HDMI clock is independent from
the Nintendo DS console clock. This configuration was selected through tests
on LG C-series displays as well as other TVs.

Runtime video controls are:

- Video Layout: Left/Right, Top/Bottom, Left Only, or Right Only.
- Screen Order: Top First or Bottom First.
- Screen Gap: 0, 8, 16, or 24 pixels.
- 3D FPS Counter: Off or On. This reports distinct completed 3D frames
  delivered to FPGA scanout, not the fixed DS/HDMI refresh rate.

The FPS counter reports completed HPS 3D frame publications; it is not the
ARM9 instruction rate or the HDMI refresh rate. The touch cursor is a
scanout-only overlay on the physical bottom screen.

## Sound and input

Sound is generated in FPGA logic by the Nitro_DarkSide Nintendo DS sound
engine and is sent through MiSTer's normal audio path. The HPS 3D service does
not emulate or mix audio.

Controller buttons and MiSTer mouse packets are mapped through `hps_io`. The
right stick selects an absolute native DS coordinate and the remappable
`Touch` action holds pen-down. Relative mouse deltas update a saturated native
DS coordinate and the left mouse button holds pen-down. The most recently
active source owns the stylus. The SPI touch controller returns
melonDS-compatible 12-bit X/Y samples and direct boot installs matching
calibration data. A scanout-only crosshair is white while hovering and red
while pressed; it does not modify either framebuffer or generate DDR traffic.

## Cartridge saves

The FPGA selects the save-device profile from the game code using a compact
table generated from melonDS's ROM database. Supported profiles are:

- 512-byte, 8 KiB, 64 KiB, and 128 KiB EEPROM/FRAM.
- 256 KiB, 512 KiB, and 1 MiB Flash.

A 512-byte sector cache connects these devices to MiSTer's mounted-save
interface. Save files are stored in MiSTer's standard `/media/fat/saves/NDS`
location and persist across ROM reloads and power cycles. NAND saves and
emulator save states are not implemented.

## Clocks and performance policy

The current console clock family is 134.055928 MHz for memory, 67.027964 MHz
for the 2x domain, and 33.513982 MHz for the 1x DS domain. Moving the family
together preserves its 4:2:1 phase relationship. The HPS service requests the
board's tested 1 GHz operating point and launches at high scheduling priority
while leaving the main MiSTer process active for menus, input, and lifecycle
control.

For historical context, the 2026-08-29 beta.6 PSX-efficiency candidate fitted
in Quartus Prime 17.0.2 at:

- 41,299 of 41,910 ALMs (99%).
- 44,947 registers.
- 468 of 553 RAM blocks (85%).
- 69 DSP blocks.
- Four PLLs.

The project is therefore strongly area-constrained. New hardware features must
be judged by both their benefit and their effect on fitting/routing. Static
timing is useful diagnostic information, but a timing warning alone is not a
deployment gate for this experimental project; successful TV and gameplay
testing is required.

## Ownership, restart, and failure rules

The FPGA and HPS exchange an explicit session number and producer/consumer
sequences. A newly started service cannot silently inherit the renderer state
of an older process. Restart uses a quiesce handshake so HPS stops writing
before FPGA clears and reuses shared DDR.

The launcher verifies the installed service against its SHA-256 manifest. The
service has a singleton lock and publishes a heartbeat after it accepts a fresh
session. Missing service, heartbeat timeout, malformed packet, ownership
violation, or an impossible sequence sets a sticky fault and fails closed
instead of continuing with untrusted shared state.

Low-rate crash telemetry reuses the existing control header and is designed
not to touch the CPU, GPU, DMA, audio, cartridge, renderer, or display fast
paths. Reports contain counters and subsystem state, not ROM, save, texture,
or framebuffer payloads.

## Current limitations

- HPS Engine B is host-tested but has not yet passed a new real-hardware
  stability and compatibility run.
- Display-capture behavior, including games that alternate 3D between physical
  screens, has a focused software oracle but still needs live trace and
  hardware acceptance.
- Heavy 3D scenes can slow down, fall behind, lose geometry, or crash.
- Cartridge latency can cause missing or late objects and effects.
- The Reset menu command can hang; reselecting the ROM is the current restart
  workaround.
- NAND saves, save states, Wi-Fi, and microphone support are not implemented.
- Chrono Trigger has a separate boot failure under investigation.

The first public compatibility target is New Super Mario Bros.; this release
is an experimental beta, not yet a general Nintendo DS compatibility claim.
