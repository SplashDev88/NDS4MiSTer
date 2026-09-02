# Hybrid 3D ABI (H3D1)

## Goal

H3D1 adds Nintendo DS 3D to the FPGA console core. The FPGA keeps the two
CPUs, timing, DMA, memory, VRAM, Engine A 2D, input, sound, saves, and video
timing. A small HPS service runs only melonDS 3D geometry and software
rasterization. Engine B is synthesized out of the current public beta.

## Rules

1. The FPGA is the time and memory authority.
2. The FPGA normalizes packed and direct geometry writes into ordered command
   records. Register and virtual-VRAM records preserve address, width, byte
   enables, source CPU, and data.
3. The packet link must not drop, repeat, or reorder an accepted record.
4. HPS publishes a complete 3D frame before FPGA can use it.
5. A late or invalid 3D line is transparent. It must not stop the 2D engine.
6. The 3D plane enters engine A as BG0 before priority, window, blend, and
   master-brightness operations.
7. High-volume per-pixel telemetry stays off. Public crash telemetry may only
   reuse an existing control-header transaction and must not touch the CPU,
   GPU, DMA, audio, cartridge, renderer, or display fast paths.

## DDR map

The MiSTer DDR bridge adds `0x30000000` to the local FPGA byte address.

| Use | FPGA byte address | HPS physical address | Size |
| --- | ---: | ---: | ---: |
| H3D1 control and packet mailbox | `0x0FC00000` | `0x3FC00000` | 320 KiB used |
| 3D frame bank 0 | `0x0FD00000` | `0x3FD00000` | 256 KiB |
| 3D frame bank 1 | `0x0FD40000` | `0x3FD40000` | 256 KiB |
| Final framebuffer bank 0 | `0x0FE00000` | `0x3FE00000` | 512 KiB |
| Final framebuffer bank 1 | `0x0FE80000` | `0x3FE80000` | 512 KiB |
| Final framebuffer bank 2 | `0x0FF00000` | `0x3FF00000` | 512 KiB |
| Final framebuffer bank 3 | `0x0FF80000` | `0x3FF80000` | 512 KiB |

Each 3D frame bank stores 256 by 192 little-endian 32-bit pixels. Pixel bits
`5:0` are R6, bits `11:6` are G6, bits `17:12` are B6, and bits `22:18` are
A5. Other bits are zero. The HPS service converts melonDS's sparse native
pixel word to this packed form before publication.

Each final framebuffer bank holds the paired 256x192 top and bottom screens.
The FPGA publishes only a completely drained, order-valid pair; video scanout
selects that bank only at its own frame boundary. Four banks keep the next
source frame from overwriting the displayed frame, an unacknowledged
publication, or a complete frame that is still draining.

## Control header

All fields are little-endian. All 64-bit fields are naturally aligned.

| Offset | Field |
| ---: | --- |
| `0x00` | magic `H3D1`, ABI version, header size |
| `0x08` | FPGA session |
| `0x10` | 32-bit committed-packet sequence plus zero reserved word, written by FPGA |
| `0x18` | 32-bit applied-packet sequence plus zero reserved word, written by HPS |
| `0x20` | separate 32-bit sticky FPGA and HPS fault words |
| `0x28` | HPS service state and accepted session |
| `0x30` | 32-bit published frame sequence plus zero reserved word |
| `0x38` | 32-bit acknowledged frame sequence plus zero reserved word |
| `0x40` | published frame descriptor |
| `0x60` | FPGA heartbeat and one slowly rotating tagged telemetry word |
| `0x68` | HPS heartbeat and a normally-zero manual snapshot token |
| `0x70` | 32-bit FPGA quiesce generation plus zero reserved word |
| `0x78` | 32-bit HPS quiesce acknowledgement plus zero reserved word |
| `0x10000` | first 64-KiB packet slot |

The service state is ready only after HPS resets its GPU and VRAM state and
accepts a freshly initialized FPGA session. The console stays in reset until
that ready state is visible. A service process may never resume an existing
session: losing the process also loses the melonDS renderer state that led to
the current consumer sequence.

### Quiesce and restart

Header magic `H3DQ` is the quiesce phase. Before reusing DDR, FPGA holds the
console in reset, reads the persisted generation, chooses the next nonzero
generation, writes it at `0x70`, and publishes `H3DQ`. HPS stops every packet,
plane, state, fault, and heartbeat write, destroys the renderer, executes a
system barrier, and writes the same generation to `0x78` as its final write.
FPGA waits indefinitely for that exact acknowledgement before it clears any
HPS-owned word or packet counter. It then publishes a new nonzero session and
`H3D1` magic last.

The service holds a singleton process lock. A newly launched service can
acknowledge `H3DQ`, but if it finds an already active `H3D1` session it writes
`RestartRequested` and becomes read-only until FPGA starts the quiesce flow.
This prevents a fresh renderer from resuming at an old consumer fence or
overwriting the active plane bank. A quiesce-generation mismatch makes an old
service read-only even if a prior session number is repeated after FPGA
reconfiguration.

### Public crash reports

The HPS service keeps a 128-sample flight recorder at 10 Hz. Each sample reads
the existing 128-byte control header; it creates no new FPGA DDR command and
runs in a `SCHED_IDLE` thread behind renderer work. A packet-consumer stall,
frame-acknowledgement stall, or sticky FPGA fault writes a versioned
`NDS4MISTER_FPGA_CRASH_V1` text report under `/media/fat`. The report contains
counters, ownership state, frame metadata, CPU progress, and tagged FPGA
subsystem telemetry. It never contains ROM, save, texture, framebuffer, or
other game payload data.

`SIGUSR1` requests a manual snapshot. HPS publishes a fresh token in control
word `0x68`; FPGA detects it through the normal header poll and holds ARM9 and
ARM7 for at most about 100 ms. During that bounded hold the HPS recorder takes
a short high-rate burst, writes the report, and clears the token. FPGA releases
the CPUs on its own even if HPS dies. Ordinary gameplay never enters this hold.

Fatal HPS signals write `NDS4MISTER_ARM_CRASH_V1`, including native ARM
registers, a small stack snapshot, and the same shared control state. Automatic
stall detection starts after two seconds without relevant forward progress.

## Frame-packet mailbox

Four 64-KiB slots occupy `0x3FC10000..0x3FC4FFFF`. Packet sequence `N` uses
slot `(N - 1) mod 4`. A slot begins with a 64-byte `H3B1` header followed by
at most 60 KiB (3,840 records) of payload. Its fields are:

| Header offset | Field |
| ---: | --- |
| `0x00` | magic `H3B1`, version 1, header size 64 |
| `0x08` | session plus zero reserved word |
| `0x10` | packet sequence plus zero reserved word |
| `0x18` | DS frame number and flags (`CONT` or `FRAME_END`) |
| `0x20` | payload bytes and record count |
| `0x28` | slot index plus zero reserved word |
| `0x30` | reserved zero |
| `0x38` | commit sequence plus zero reserved word, written last |

FPGA writes the payload first, header beats 0 through 6 next, the slot commit
last, and only then publishes the producer sequence at control offset `0x10`.
HPS snapshots the full header, copies the payload, snapshots the header again,
and accepts it only when both copies and all reserved fields match. It applies
the complete packet in record order and publishes one acknowledgement only
after every record is applied. It revalidates the active lifecycle and packet
session immediately before that acknowledgement.

Each payload record is 16 bytes:

```text
word 0: kind[7:0], tag[15:8], byte_enable[19:16], reserved[31:20]=0
word 1: address or auxiliary value
word 2: data[31:0]
word 3: data[63:32]
```

Record kinds are:

| Kind | Meaning |
| ---: | --- |
| 1 | Normalized GX command. The tag is the command ID. |
| 2 | ARM9 3D/GX register write. |
| 3 | Virtual VRAM write from ARM9 or ARM7. |
| 4 | VRAMCNT mapping write. |
| 5 | Engine A/B 2D register write. |
| 6 | Palette write. |
| 7 | OAM write. |
| 8 | HBlank marker. |
| 9 | Three normalized GX commands packed into one transport record. |

For ordinary write records, tag bits 1:0 carry access width and VRAM-write tag
bit 2 selects ARM7. VRAM writes retain their virtual address and byte enables
so melonDS continues to own VRAM mapping and overlap behavior. Kinds 5 through
8 preserve the HPS GPU/VRAM mirror's state and ordering and also support the
diagnostic shadow path. The public service does not publish HPS-rendered 2D.

Kind 9 uses tag bytes in metadata bits `15:8`, `23:16`, and `31:24`. The three
corresponding 32-bit command values occupy words 1, 2, and 3. The normal
byte-enable and reserved-bit interpretation therefore does not apply to a
packed-GX record.

The FPGA owns a real 256-entry normalized GX FIFO and reports its level in
GXSTAT. Packed GXFIFO words are decoded before entering that FIFO. Accepted
records from the GX FIFO, direct GPU registers, ARM9 VRAM, and ARM7 VRAM are
merged by their captured DS-clock timestamps; equal times use GX/GPU, ARM9,
then ARM7 priority. Timestamps order the FPGA transport only and are not
stored in packet records.

`SWAP_BUFFERS` must be the final record in a terminal packet. A VBlank token
also closes a partial or empty frame when software issued no swap. Oversize
frames are split into `CONT` packets followed by one `FRAME_END`; HPS advances
the renderer at each continuation boundary and renders only the terminal
packet. A new session resets all packet ownership.

## Backpressure and faults

The source side uses a dual-clock record FIFO between `clk1x` and the 60 MHz
DDR clock. Four committed packet slots provide frame-scale slack. When they
are full, backpressure reaches the GX FIFO and the original GPU/VRAM source;
architectural completion occurs only after lossless acceptance.

No accepted record can be discarded. Source mutation while stalled, CDC
failure, malformed or non-contiguous packets, session mismatch, or reuse of
an unacknowledged slot sets a sticky fault and holds the console in reset.

After HPS reports Ready, FPGA also requires the HPS heartbeat to advance at
least once per second. A dead renderer or supervisor therefore sets the sticky
service fault and resets the console without waiting for all packet slots to
fill. The timeout is intentionally much longer than a valid frame render or
copy stall.

## Frame publication

HPS writes the inactive 3D frame bank. It completes all cache maintenance and
a release barrier before it publishes this descriptor:

```text
32-bit sequence plus zero reserved word, FPGA session, DS frame number, bank,
pixel format, width/height, stride
```

Each physical bank is fully initialized before its first publication in a
session. Later publications compare against that bank's packed HPS shadow and
write only changed 32-bit words; the descriptor is still published every
frame, including an unchanged frame.

FPGA latches a new complete descriptor at VBlank. It acknowledges the
descriptor before HPS can reuse the old bank.

FPGA fetches one 256-pixel line into one of two ping-pong line RAMs. A line
record carries session, frame, bank, and Y tags. A tag mismatch or a missed
deadline makes every pixel in that line transparent.

## Engine-A blend contract

When engine-A `DISPCNT.BG0_3D` is set, the returned 3D pixel replaces the
normal BG0 pixel input. BG0 priority, windows, and target masks still apply.

Alpha zero is transparent. For a visible 3D top pixel and an enabled second
target, the blend is:

```text
eva = alpha5 + 1
evb = 32 - eva
out = min(63, (source6 * eva + destination6 * evb + 16) >> 5)
```

Other effects use the existing 2D merge rules. Engine B has no 3D BG0 input.

## Public-beta acceptance gate

The initial public compatibility target is New Super Mario Bros.

1. The service accepts one full session with zero packet faults and zero drops.
2. The title and first playable 3D scene have stable polygons and textures.
3. Existing 2D layers, windows, and blends stay correct over the 3D plane.
4. All selectable integer layouts and physical controls still pass.
5. Kirby remains a 2D regression test.
6. Missing HPS service fails closed. A slow 3D frame becomes transparent and
   does not reduce the 2D frame rate.
