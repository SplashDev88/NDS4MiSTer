# Nitro_DarkSide production console closure

This directory vendors the production RTL dependency closure used by the
NDS4MiSTer Nitro console-island alternate revision, plus the preferred HLE
BIOS assembly sources and generators for the two generated BIOS RTL files.
Except for the explicitly documented donor-path adaptations below, every
retained donor file is byte-for-byte identical to the corresponding blob in
the pinned upstream Git tree.

- Upstream: https://github.com/MiSTfits-devel/Nitro_DarkSide
- Commit: `d2dabe03344c0a685cd0f00e42b1a89606710dee`
- Git tree: `5b7f2671bbab83855bad314ba8d00704bba035ef`
- License: GPL-3.0-or-later; see `LICENSE.md`, donor file notices, and SPDX
  headers where present.
- Integrity manifest: `SHA256SUMS`
- Product source order: `fpga/mister_nitro_console_island/files.qip`

The three adapted donor-path files are:

- `rtl/nds_dma9.vhd` and `rtl/nds_drawer_merge.vhd` carry the local hybrid-3D
  interfaces introduced by NDS4MiSTer commit
  `b7ad3656445752b62617f2f30aabd354efd7626e`.
- `rtl/nds_drawer_obj.vhd` additionally carries only the divider-removal hunks
  from upstream commit `c5004b85b9f19d0c2164d2f3624b120dd79e17d2`
  (`obj+vram: delete the inferred dividers, measured 72 -> 0`). No other live
  upstream donor file was imported. The equivalent three posted-write queue
  wrap hunks were applied separately to the active product-local
  `rtl/nds_nitro_vram.vhd` derivative.

## Exact vendored RTL inventory

The closure contains these 41 upstream files:

```
rtl/SyncFifo.vhd
rtl/SyncRamDualByteEnable.vhd
rtl/ddram.sv
rtl/export.vhd
rtl/gba_cpu.vhd
rtl/gba_timer.vhd
rtl/gba_timer_module.vhd
rtl/nds_bios7.vhd
rtl/nds_bios9.vhd
rtl/nds_cache9.vhd
rtl/nds_card.vhd
rtl/nds_cpu9.vhd
rtl/nds_debug.vhd
rtl/nds_dma7.vhd
rtl/nds_dma9.vhd
rtl/nds_drawer_affext.vhd
rtl/nds_drawer_merge.vhd
rtl/nds_drawer_obj.vhd
rtl/nds_drawer_text.vhd
rtl/nds_gpu2d.vhd
rtl/nds_gpu2d_fast.vhd
rtl/nds_gpu_timing.vhd
rtl/nds_ipc.vhd
rtl/nds_irq.vhd
rtl/nds_loader.vhd
rtl/nds_mainram.vhd
rtl/nds_membus7.vhd
rtl/nds_membus9.vhd
rtl/nds_perf.vhd
rtl/nds_rtc.vhd
rtl/nds_sound.vhd
rtl/nds_spi.vhd
rtl/nds_syscnt.vhd
rtl/nds_vram.vhd
rtl/nds_vram_map.vhd
rtl/nds_wram.vhd
rtl/proc_bus_gba.vhd
rtl/reg_nds_display.vhd
rtl/reg_savestates.vhd
rtl/reggba_timer.vhd
rtl/sdram.sv
```

`nds_sound.vhd`, `nds_debug.vhd`, and `nds_rtc.vhd` remain in the analyzed
dependency closure. The product wrapper fixes SOUND=0 and DEBUG=0, and supplies
an inert RTC boundary, so those product cones are constant-pruned/inert.

## Generated HLE BIOS corresponding source

`rtl/nds_bios7.vhd` and `rtl/nds_bios9.vhd` contain generated HLE ARM machine
code. The exact GPL assembly and generator scripts used by the donor are
retained as source-support files, but are not Quartus/QIP inputs:

```
sim/tests/hle_bios7/build.sh
sim/tests/hle_bios7/bios7.s
sim/tests/hle_bios9/build.sh
sim/tests/hle_bios9/bios9.s
```

The scripts require devkitARM to regenerate the checked-in VHDL. They mention
optional user-supplied retail BIOS hex files; no such files or retail BIOS
bytes are present in this tree.

## Product substitutions and exclusions

The product deliberately substitutes local adapted files for the donor top,
mixed-language wrapper, BIOSes, VRAM subsystem, ARM9 memory-bus boundary,
GPU2D line orchestrator, and framebuffer service:

- donor `nds_vram.vhd` -> `rtl/nds_nitro_vram.vhd`
- donor `nds_membus9.vhd` -> `rtl/nds_nitro_membus9.vhd`
- donor `nds_gpu2d.vhd` -> `rtl/nds_nitro_gpu2d.vhd`
- donor `nds_bios7.vhd` -> `rtl/nds_nitro_freebios7.vhd`
- donor `nds_bios9.vhd` -> `rtl/nds_nitro_freebios9.vhd`
- donor `nds_top.vhd` -> `rtl/nds_nitro_console_top.vhd`
- donor `nds_port_wrap.vhd` -> `rtl/nds_nitro_console_wrap.vhd`
- donor `nds_fb_ddr3.sv` -> `rtl/nds_nitro_fb_ddr3.sv`

The VRAM derivative retains the eight per-channel A..D line caches and adds two
ownerless victim lines keyed by physical bank and line.  It blocks a late
backing response from refilling either cache after a CPU or posted-write
invalidation.  This experimental optimization removed the bounded line-130
overrun, but the sustained frame test still dropped lines.  It is included for
board measurement and is not a zero-drop claim.

The memory-bus derivative serializes palette/OAM writes across the product's
related 2x-to-1x clock boundary.  The GPU2D derivative holds the selected BG
drawer family for the duration of an accepted scanline so a live DISPCNT mode
write cannot disconnect an outstanding request.  These derivatives retain the
donor entity names and replace, rather than accompany, their donor design units
in the QIP.

The two product BIOS ROMs are generated from the redistributable melonDS
FreeBIOS arrays in `third_party/melonDS/src/FreeBIOS_Data.h`. They provide the
direct-boot SWIs needed by the initial compatibility target without Nintendo
BIOS data; they are not full retail-BIOS equivalents. Corresponding source is
retained in `third_party/melonDS/freebios`, and the BSD-2-Clause notice is
`third_party/melonDS/freebios/drastic_bios_readme.txt`. Regenerate the VHDL
with `tools/generate_nitro_freebios_vhdl.py`; that script pins and verifies the
vendored header and both padded image hashes.

The donor `NDS.sv` was used only as an integration reference and is not
vendored or sourced by the product. Donor PLLs, HPS/LW shell logic, audio DDR
adapter, generic unused RAM primitives, DPRAM/DDR mux, and donor QIP files are
also excluded because the alternate revision keeps the NDS4MiSTer shell and
uses only the dependencies instantiated by its console island.

All other simulation/test trees, retail ROMs/BIOS, firmware images, generated
binaries, frame captures, build artifacts, and upstream Git history are
intentionally excluded. They are not product dependencies and may contain
redistributable or historical test payloads that must not enter the source
commit.
