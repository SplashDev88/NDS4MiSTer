# r355 Nitro console-island alpha

This is a compile-time-separate, performance-first NDS MiSTer revision. It
replaces the serialized r343 CPU/HPS execution path with the coherent Nitro
ARM9 + ARM7 console island while retaining the repository's MiSTer shell,
OSD, controller input, scaler/HDMI, and physical memory interfaces.

It is currently a **pre-build candidate**, not a released RBF. Do not replace
the proven r343 or 17.3-FPS fallback artifacts with it until the focused
mixed-language compile, sustained renderer simulation, Quartus FIT, and board
gates have passed.

## First-alpha scope

- MiSTer OSD ROM picker: `Load NDS (max 128 MiB)`
- ARM9, ARM7, TCM/cache, DMA, timers, IRQ, IPC, card, SPI, WRAM/VRAM and both
  2D engines remain inside one coherent FPGA console
- direct boot with built-in BSD-licensed melonDS FreeBIOS
- native 256x192 main-screen raster into the retained MiSTer video shell; the
  core requests the largest sharp integer scale that fits
- standard MiSTer controller order: A, B, X, Y, L, R, Select, Start, Touch
- compact iterative DIV/SQRT implementation

Intentional first-alpha omissions:

- sound is disabled to preserve fit/performance headroom
- Wi-Fi and real-time-clock service are inert
- engine B is omitted for the first beta; engine A is displayed once instead
  of being duplicated into both halves of the output
- GX/3D is not implemented; 3D-heavy titles are not a compatibility target
- save persistence and sleep/lid behavior are not release-qualified
- iterative DIV/SQRT preserves polling-visible BUSY/result behavior, but may
  hold BUSY longer than original DS hardware (up to 64 ARM9 clocks for DIV
  and 32 for SQRT); fixed-delay math code is not yet qualified
- ROMs over 128 MiB are unsupported because the staged card address ABI is
  27-bit and wraps larger direct-DDR loads

No retail ROM, firmware, BIOS, key material, captured frame, or generated
bitstream is stored in this source tree.

## Source provenance

The retained donor closure is pinned to Nitro_DarkSide commit
`d2dabe03344c0a685cd0f00e42b1a89606710dee` (tree
`5b7f2671bbab83855bad314ba8d00704bba035ef`). Its production files and license
are recorded under `third_party/Nitro_DarkSide/d2dabe/`; verify them with:

```sh
(cd third_party/Nitro_DarkSide/d2dabe && shasum -a 256 -c SHA256SUMS)
```

The private source archive supplied for recovery is evidence/provenance only;
it is not a build input and is not included in this project.

## Focused host checks

From the repository root, with Icarus Verilog installed:

```sh
tools/test_nitro_console_island_host.sh
```

This covers the post-download DDR cache displacement, asynchronous pixel FIFO
ordering/reset/overflow, exact native raster cadence/prefetch count, compact
math results and extended BUSY behavior, and SystemVerilog island elaboration.
The VHDL console wrapper still requires the focused GHDL/Quartus gate.

## Quartus project

Use Quartus 17.0.2 and open `NDS4MiSTer.qpf` in this directory. The project is
an alternate revision; its QSF does not modify or source the r343 project.
Timing and fit results are acceptance evidence, not assumptions. A generated
RBF is not board-ready until the OSD-load, input, line-drop, and >=15 FPS board
profile also passes.
