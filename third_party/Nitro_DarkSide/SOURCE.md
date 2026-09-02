# Nitro_DarkSide ARM9 donor source

This directory contains the attributed donor source set needed to analyze the
experimental Nitro_DarkSide ARM9 CPU in the NDS4MiSTer r343 product base.

- Upstream: https://github.com/MiSTfits-devel/Nitro_DarkSide
- Commit: `d2dabe03344c0a685cd0f00e42b1a89606710dee`
- Source tree: `5b7f2671bbab83855bad314ba8d00704bba035ef`
- License: GPL-3.0-or-later. See `LICENSE.md`.
- Copyright: See the SPDX headers in the source files.

Imported files:

- `rtl/export.vhd`
- `rtl/proc_bus_gba.vhd`
- `rtl/reg_savestates.vhd`
- `rtl/nds_cpu9.vhd`
- `rtl/SyncRamDualByteEnable.vhd`
- `rtl/nds_cache9.vhd`
- `rtl/nds_membus9.vhd`
- `rtl/nds_bios9.vhd`

The RAM primitive compiles in `MEM`. The other files compile in
`nitro_arm9`. These libraries prevent package and entity names from colliding
with the current core.

Local NDS4MiSTer changes to the imported memory files are:

- `nds_membus9.vhd` adds an optional cold external boundary. It also leaves
  DTCM offsets `0x3C0` and `0x3FFC` on the current r343 boundary in this mode.
- `nds_cache9.vhd` adds an optional D-cache exclusion generic and an optional
  serialized-fill response mode. Upstream behavior remains the default.
- `nds_bios9.vhd` imports `IEEE.std_logic_textio` and reads the optional
  simulation hex word as `std_logic_vector`. This preserves the generated HLE
  BIOS and hardware RAM behavior while making `hread` visible to Quartus 17.

The adapter runs the donor CPU on the current r343 clock and scheduling
boundary. It does not reproduce Nitro_DarkSide's 67.027964 MHz ARM9 clock.
The path is default-off and keeps a one-unit scheduler placeholder because the
donor has no normalized instruction-cycle report. It is not time-qualified.

## Local LCD timing behavior

`rtl/nds_local_lcd_control.sv` derives the base LCD cadence, register masks,
IRQ conditions, DMA phase conditions, and timing constants from this upstream
source:

- File: `rtl/nds_gpu_timing.vhd`
- Commit: `f00c133e5a0588ac52b90aaea5ba21c05cffc935`
- Blob: `062a2f1c89cf9aa8ab33d33dfe93be857832c478`
- License: GPL-3.0-or-later

The natural-VCOUNT VBlank order follows melonDS. A delayed VCOUNT override
changes VMatch and live HBlank DMA state. It does not move physical VBlank.

Rendering stays on HPS. Before this default-off feature can be enabled, HPS
must drain queued LCD events through each DISPSTAT or VCOUNT request timestamp.
It must then complete the access and mirror each completed write. This rule
makes LCD MMIO blocking. It does not make every LCD boundary blocking.

## Local DMA donor source

The default-off slow DMA pair comes from Nitro_DarkSide commit
`6dda76860f3c48480120b5f99aef0e98a1f86794`.

- `rtl/nds_dma7.vhd` source blob:
  `d52fc9f7d2d71cecfe08e40f5b88c8571c641fb7`
- `rtl/nds_dma7.vhd` current product blob:
  `6abd72f9c6be3f9e6ef42085ecec67ff330e4def`
- `rtl/nds_dma9.vhd` source blob:
  `28e0052cd4074f080baf3d25f0a609f97bb564af`
- `rtl/nds_dma9.vhd` current product blob:
  `55938a158ae81e1d866d14073ce30a10e9e42aad`

DMA7 starts from the donor file and adds a sticky fail-closed report for card
timing without a card-ready owner and for WiFi/GBA-slot timing. DMA9 starts
from the donor file and adds display-start mode 3 for physical raster lines 2
through 193, display stop at line 194, and the same fail-closed contract.
Display FIFO mode 4, card mode 5 without a card-ready owner, mode 6, and GX
FIFO mode 7 clear enable and set this report. They do not start a slow memory
request.

The product path uses the current CPU memory port. DMA pauses only its owner,
waits for that CPU port to drain, and bypasses ARM9 ITCM and DTCM. Completion
IRQs enter the existing lossless IF8 through IF11 SET path. The feature stays
off through `LOCAL_LCD_ENABLE = 0`. The current top ties both card-ready inputs
low and has no GX FIFO DMA trigger owner. These absent trigger paths now fail
closed. Board testing remains gated by the HPS LCD batch consumer and the
combined source tests.
