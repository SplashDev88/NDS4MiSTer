# NDS Hardware Ground Truth

Extracted 2026-07-16 from the public NitroSDK reconstruction (`../NitroSDK`), cross-checkable
against GBATEK. File references are into that tree. This is the reference the RTL is written
against; keep it corrected as we learn more.

## Memory map

### ARM9 (`include/nitro/hw/ARM9/mmap_global.h`)

| Region | Base | Size | Notes |
|---|---|---|---|
| ITCM | mirrored through `0x01000000` window; real `0x01FF8000` | 32 KB | PU-mapped, movable window |
| Main RAM | `0x02000000` | 4 MB | retail; 8 MB on dev/DSi-TS |
| Shared WRAM (ARM9 view) | `0x037F8000` | 0–32 KB | WRAMCNT mapping, 4 modes |
| DTCM | linker-defined (`SDK_AUTOLOAD_DTCM_START`) | 16 KB | movable; IRQ vector ptr at `+0x3FFC` |
| IO | `0x04000000` | — | engine B block at `0x04001000` |
| Palette main/sub | `0x05000000` / `0x05000400` | 2×1 KB | BG+OBJ 512 B each |
| BG VRAM main / sub | `0x06000000` / `0x06200000` | ≤512 KB / ≤128 KB windows | bank-mapped |
| OBJ VRAM main / sub | `0x06400000` / `0x06600000` | ≤256 KB / ≤128 KB windows | bank-mapped |
| LCDC linear VRAM | `0x06800000` | 656 KB | all banks stacked |
| OAM main / sub | `0x07000000` / `0x07000400` | 2×1 KB | |
| GBA slot ROM / SRAM | `0x08000000` / `0x0A000000` | 32 MB / 64 KB | out of scope initially |
| ARM9 BIOS | `0xFFFF0000` | 32 KB | high vectors |

### ARM7 (`include/nitro/hw/ARM7/mmap_global.h`)

| Region | Base | Size | Notes |
|---|---|---|---|
| ARM7 BIOS | `0x00000000` | 16 KB | not in SDK headers; GBATEK |
| Main RAM | `0x02000000` | 4 MB | shared with ARM9, EXMEMCNT arbitration |
| Shared WRAM (ARM7 view) | `0x037F8000` | 0–32 KB | WRAMCNT |
| ARM7 private WRAM | `0x03800000` | **64 KB** | |
| IO | `0x04000000` | — | sound/SPI/RTC/wifi are ARM7-only |
| VRAM C/D as ARM7 WRAM | `0x06000000` | ≤256 KB | banks C/D MST=2 |
| Wifi MMIO | `0x04800000` | 32 KB window | not in SDK (closed blob); stub |

### Main RAM partition convention (`mmap_main.h`)
Default: 3.875 MB ARM9 "MAIN" / 124 KB ARM7 "SUB" / 4 KB shared mailbox at top
(`0x027FF000`). The shared block holds fixed-address structures the BIOS/firmware and both
CPUs rely on: card header copies (`0x027FFA80`, `0x027FFE00`), RTC buffer, touch buffer
(`0x027FFFAA`), PXI signal words (`0x027FFF80..8C`), and HW lock flags (`0x027FFFC0..F0`).
To the FPGA these are ordinary main RAM — but boot HLE must populate them.

## VRAM banks (the load-bearing table)

Sizes and LCDC addresses (`mmap_vram.h`), MST decoding (`libraries/gx/src/gx_vramcnt.c:10-132`).
VRAMCNT_x = byte regs at `0x04000240+x` (A..I, skipping `0x04000247` = WRAMCNT):
`MST` bits[2:0] (2 bits on A/B/H/I), `OFS` bits[4:3], enable bit7.

| Bank | Size | LCDC @ | MST0 | MST1 | MST2 | MST3 | MST4 | MST5 |
|---|---|---|---|---|---|---|---|---|
| A | 128K | `0x6800000` | LCDC | Main BG `0x6000000+OFS·20000` | Main OBJ `0x6400000+OFS·20000` | Texture slot OFS | — | — |
| B | 128K | `0x6820000` | LCDC | Main BG +OFS·20000 | Main OBJ +OFS·20000 | Texture slot OFS | — | — |
| C | 128K | `0x6840000` | LCDC | Main BG +OFS·20000 | **ARM7** `0x6000000+OFS·20000` (OFS 0/1) | Texture | **Sub BG** `0x6200000` | — |
| D | 128K | `0x6860000` | LCDC | Main BG +OFS·20000 | **ARM7** +OFS·20000 | Texture | **Sub OBJ** `0x6600000` | — |
| E | 64K | `0x6880000` | LCDC | Main BG `0x6000000` | Main OBJ `0x6400000` | Tex palette | BG ext pal slots 0–3 | — |
| F | 16K | `0x6890000` | LCDC | Main BG (OFS→`0/4000/10000/14000`) | Main OBJ (same OFS rule) | Tex pal | BG ext pal | OBJ ext pal |
| G | 16K | `0x6894000` | LCDC | Main BG (OFS rule) | Main OBJ (OFS rule) | Tex pal | BG ext pal | OBJ ext pal |
| H | 32K | `0x6898000` | LCDC | Sub BG `0x6200000` | Sub BG ext pal | — | — | — |
| I | 16K | `0x68A0000` | LCDC | Sub BG `0x6208000` | Sub OBJ `0x6600000` | Sub OBJ ext pal | — | — |

Total: **656 KB**. F/G OFS offset = `(OFS&1)·0x4000 + (OFS>>1)·0x10000`.
Hardware constraints (from `gx/gx_vramcnt.h` enums): only C/D can map to ARM7; sub BG only
C/H/I; sub OBJ only D/I; OBJ ext palette only F/G.

## IO register blocks (offsets from `0x04000000`)

| Block | Regs | CPU |
|---|---|---|
| Display A | DISPCNT `000` (32-bit!), DISPSTAT `004`, VCOUNT `006`, BG/WIN/EFF `008..05F` (GBA-like), DISP3DCNT `060`, DISPCAPCNT `064`, DISP_MMEM_FIFO `068`, MASTER_BRIGHT `06C` | 9 |
| Display B | mirror block at `0x04001000` (no 3D/capture/FIFO, no ext pal beyond H/I) | 9 |
| DMA | 4ch/CPU `0B0..0DF`, + ARM9 DMA fill regs `0E0..0EF` | both |
| Timers | 4/CPU `100..10E` | both |
| Keys | KEYINPUT `130`, KEYCNT `132`; X/Y/pen/lid via ARM7 `136` + SPI | both |
| IPC | IPCSYNC `180`, IPCFIFOCNT `184`, SEND `188`, RECV `0x4100000` | both |
| Card | AUXSPICNT `1A0`, AUXSPIDATA `1A2`, ROMCTRL `1A4`, CMD `1A8/1AC` (8 bytes), data `0x4100010` | both (EXMEMCNT owner) |
| SPI | SPICNT `1C0`, SPIDATA `1C2`; devices: TP=0, NVRAM=1, MIC=2, PM=3 | 7 |
| Memory ctrl | EXMEMCNT `204`, WRAMCNT `247`, VRAMCNT `240..249` | 9 (EXMEMSTAT `204` on 7) |
| IRQ | IME `208`, IE `210`, IF `214` | both |
| Math | DIVCNT `280`, DIV_NUMER/DENOM/RESULT/REM `290..2AC`, SQRTCNT `2B0`, SQRT_RESULT `2B4`, SQRT_PARAM `2B8` | 9 |
| Power | POWCNT `304` (bit0 LCD, 1 E2D-A, 2 3D-render, 3 3D-geom, 8 LCD-B, 9 E2D-B, 15 swap) | 9 |
| Sound | 16 ch × 16 B at `400..4FF` (CNT/SAD/TMR/PNT/LEN), SOUNDCNT `500`, SOUNDBIAS `504`, SNDCAP `508..51F` | 7 |
| RTC | `138` bit-banged (GBATEK; not in SDK) | 7 |
| Wifi | `0x04800000` block (not in SDK; stub) | 7 |
| 3D geom/render | `320..3FF`, `400`-series cmd ports `440..5C8`, GXSTAT `600` etc. | 9, out of scope phase 1 (stub GXSTAT sanely) |

Interrupt bits (`os/common/interrupt.h`): VBlank 0, HBlank 1, VCount 2, Timer 3–6, SIO 7,
DMA 8–11, Key 12, GBA-slot 13, IPCSYNC 16, FIFO-send 17, FIFO-recv 18, Card-data 19,
Card-IREQ 20, GXFIFO 21 (ARM9); PM 22?/SPI 23/Wireless 24 (ARM7 numbering per SDK).

## Key DISPCNT deltas vs GBA
32-bit register. New: bit3 BG0→3D output (engine A), OBJ 1D mapping strides [6:4]/[22:20]
incl. bitmap OBJs, display mode [17:16] (1=normal graphics, 2=VRAM-direct from bank [19:18],
3=main-mem FIFO), global char base [26:24] / screen base [29:27] (64 KB granularity, engine A
only). BGxCNT gains ext-palette slot selection; DISPSTAT LYC is 9 bits.

### OBJ per-line time budget (bit23)
DISPCNT bit23 "OBJ Processing during H-Blank" (relocated from GBA bit5) flips the
OBJ engine's per-line budget: **SET = it gets the H-Blank interval = 1210 cycles,
CLEAR = visible line only = 954**. The polarity reads opposite to GBA bit5
("H-Blank Interval Free", SET = CPU takes the interval = 954) — the NDS bit means
what the GBA one doesn't. Verified against GBATEK 2026-08-16. Charging, per
GBATEK and now pinned by `run_gpu_obj_budget.sh`: a normal sprite costs **1 cycle
per field pixel** (the sprite's whole field width, even the pixels a screen clip
keeps off-screen — hardware charges the field, not the landing), a rot/scal
sprite **10 (setup) + 2 per field pixel**. A line over budget loses its LAST
sprites in OAM order, i.e. the lowest priority. melonDS models neither budget,
so generated golden models expect the no-limit behaviour on scenes that would
exceed it (`nds_drawer_obj`'s `HW_TIME_LIMIT` generic, default on).

## Video timing (`hw/common/lcd.h`)
- System clock 33.513982 MHz (ARM7 & bus); ARM9 CPU at 2× = 67.027964 MHz.
- 6 clocks/dot; line = 256 + 99 = 355 dots = 2130 clk; frame = 192 + 71 = 263 lines
  = 560,190 clk ≈ 59.826 Hz. (GBA: 308×228×4 @16.78 MHz — same 59.7-ish class but
  different counts; dual 256×192 displays.)

## Boot (cart header + HLE contract)
`CARDRomHeader` (`include/nitro/card/rom.h:18-58`, 0x160 bytes at ROM offset 0):
ARM9 `rom_offset/entry/ram_address/size` at +0x20; ARM7 quad at +0x30; FNT/FAT/OVT tables;
`logo_crc`, `header_crc`. Boot HLE (what BIOS+firmware do before game entry):
1. Copy header to `0x027FFE00` and `0x027FFA80`.
2. Load ARM9 image `rom_offset→ram_address` (`size` bytes); same for ARM7.
3. Populate shared area: user settings from firmware NVRAM (`0x027FFC80`), RTC buf, boot flags.
4. Set default state: `POWCNT`, WRAMCNT=3 (all shared WRAM→ARM7 per firmware convention),
   ARM9 PU off at entry (crt0 sets it up), IME=0 both CPUs.
5. ARM9 jumps to `main_entry_address`, ARM7 to `sub_entry_address`.
crt0 behavior confirming entry state: `libraries/init/src/crt0.c:36-138` (IME=0 write, waits
VCOUNT==0, builds PU regions, DTCM stacks at top, decompresses/autoloads segments).

ARM7 runtime duties (drives what our HLE/RTL must service): sound mixing (all SND regs),
touch via SPI TP, firmware flash reads, power management, RTC, mic, wifi (stub), X/Y/lid keys.
Results posted to shared-RAM mailbox + IPC FIFO.

## Known gaps in SDK ground truth
- Wifi register block `0x04800000` — use GBATEK; phase-1 stub returning sane IDs.
- RTC register `0x04000138` bit-bang protocol — GBATEK.
- ARM7 BIOS contents/HLE — GBATEK + drastic/melonDS behavior as reference.
- Per-region wait states / bus contention penalties — GBATEK "DS Memory Timings"; the SDK
  encodes only EXMEMCNT and ROMCTRL gap fields.
