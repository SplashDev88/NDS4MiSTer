# Architecture

Status: Public Save Beta B, 2026-08-27.

## Goal

NDS4MiSTer is an experimental Nintendo DS implementation for the MiSTer
DE10-Nano. The current design keeps the timing-sensitive console in FPGA logic
and uses the HPS only for the part that has proved too expensive to fit and run
well in the fabric: Nintendo DS 3D geometry and software rasterization.

This replaces the project's original HPS-first benchmark architecture. The
shipping beta does **not** run the two DS CPUs, DMA, 2D engines, sound, or
cartridge emulation in a headless melonDS instance.

## Current hardware/software split

| Subsystem | Current owner | Notes |
| --- | --- | --- |
| ARM9 and ARM7 CPUs | FPGA | FPGAzumSpass's GBA ARM7 implementation was the basis for the ARM9 work. |
| System timing, interrupts, IPC, timers, and DMA | FPGA | The FPGA remains the time authority. |
| Main memory, cartridge, VRAM mapping, palette, and OAM | FPGA | ROM data lives in MiSTer DDR; architectural memory behavior remains in the core. |
| Engine A 2D and HBlank/HDMA effects | FPGA | Includes the per-scanline effects used by games such as New Super Mario Bros. |
| Engine B 2D | Not in this beta | It is synthesized out to fit the device; both logical screen positions currently show Engine A. |
| 3D geometry and rasterization | HPS | A small service replays ordered FPGA events into melonDS's 3D engine and publishes completed 3D planes. |
| 2D/3D composition and final frame publication | FPGA | The 3D plane enters Engine A as BG0 and is merged using DS priority, window, and blend rules. |
| Sound | FPGA | GPL-licensed Nitro_DarkSide sound engine, built with `SOUND_ENABLE=1`. |
| Cartridge saves | FPGA plus MiSTer file interface | Profiles are generated from the vendored melonDS ROM database. |
| Input, OSD, scaling, and HDMI | FPGA/MiSTer framework | The current path is designed for reliable scaled HDMI output, including LG C-series TVs. |

## High-level data flow

```text
                     MiSTer HPS/Linux
               +-------------------------+
               | hybrid 3D service       |
               | melonDS GPU3D + software|
               | rasterizer only         |
               +------------+------------+
                            ^ |
            ordered GPU/VRAM| |complete 3D planes
                      packets| v
                    +--------+--------+
                    | shared DDR/H3D1 |
                    +--------+--------+
                             ^
                             |
+----------------------------+-----------------------------+
| FPGA Nintendo DS console                                 |
| ARM9/ARM7 -> memory/DMA/cart -> Engine A 2D + 3D merge   |
|                         -> sound -> saves -> video/input  |
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
DDR. Cartridge-access latency is still a known bottleneck and can cause assets
or effects to appear late or fail to load in some games.

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
4. At the terminal packet for a frame, melonDS runs geometry and the software
   rasterizer for a complete 256x192 3D plane.
5. HPS writes an inactive plane bank, performs cache maintenance and a release
   barrier, then publishes its descriptor last.
6. FPGA adopts only a complete descriptor, prefetches tagged lines, and feeds
   valid pixels into Engine A as BG0.

The production service does not render a shadow copy of the FPGA 2D engines.
That keeps the high-volume 2D and HDMA work in hardware and limits the HPS
workload to 3D.

### Shared DDR layout

| Region | HPS physical address | Size and use |
| --- | ---: | --- |
| H3D1 control header | `0x3FC00000` | Session, ownership, packet/frame sequences, faults, and heartbeats. |
| Four packet slots | `0x3FC10000..0x3FC4FFFF` | Four 64 KiB ordered event packets. |
| 3D plane bank 0 | `0x3FD00000` | 256 KiB inactive/active 3D image bank. |
| 3D plane bank 1 | `0x3FD40000` | 256 KiB inactive/active 3D image bank. |
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

The FPGA drains a completed screen pair into one of four final-framebuffer
banks. Scanout changes banks only at a video frame boundary, so HPS or FPGA
writers cannot overwrite the displayed frame.

The release uses MiSTer's scaled HDMI path with nearest-neighbor integer
scaling and a compact scaler-only shell. The HDMI clock is independent from
the Nintendo DS console clock. This configuration was selected through tests
on LG C-series displays as well as other TVs.

Runtime video controls are:

- Video Layout: Left/Right, Top/Bottom, Left Only, or Right Only.
- Screen Order: Main First or Touch First.
- Screen Gap: 0, 8, 16, or 24 pixels.
- FPS Counter: Off or On.

Because Engine B is absent, the current beta duplicates Engine A in both
logical screen positions. The FPS counter reports completed HPS 3D frame
publications; it is not the ARM9 instruction rate or the HDMI refresh rate.

## Sound and input

Sound is generated in FPGA logic by the Nitro_DarkSide Nintendo DS sound
engine and is sent through MiSTer's normal audio path. The HPS 3D service does
not emulate or mix audio.

Controller buttons are mapped through `hps_io`. A Touch button and analog
coordinates reach the console boundary. The right stick selects an absolute
native DS coordinate and the remappable `Touch` action holds pen-down. The SPI
touch controller returns melonDS-compatible 12-bit X/Y samples and direct boot
installs matching calibration data.

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

The current console clock family is 132 MHz for memory, 66 MHz for the 2x
domain, and 33 MHz for the 1x DS domain. Moving the family together preserves
its 4:2:1 phase relationship. The HPS service requests the board's tested
1 GHz operating point and launches at high scheduling priority while leaving
the main MiSTer process active for menus, input, and lifecycle control.

Public Save Beta B fitted in Quartus Prime 17.0.2 at:

- 41,199 of 41,910 ALMs (98%).
- 481 of 553 RAM blocks (87%).
- 3,459,840 of 5,662,720 block-memory bits (61%).

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

- Engine B is disabled, so both displayed screen positions show Engine A.
- Heavy 3D scenes can slow down, fall behind, lose geometry, or crash.
- Cartridge latency can cause missing or late objects and effects.
- The Reset menu command can hang; reselecting the ROM is the current restart
  workaround.
- Basic controller touchscreen input is present, but Engine B is not displayed,
  so precise touch-screen games remain limited. NAND saves, save states, Wi-Fi,
  and microphone support are not implemented.
- Chrono Trigger has a separate boot failure under investigation.

The first public compatibility target is New Super Mario Bros.; this release
is an experimental beta, not yet a general Nintendo DS compatibility claim.
