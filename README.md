# NDS_MiSTfits — Nintendo DS core for MiSTer

An in-progress Nintendo DS core for the MiSTer FPGA platform (DE10-Nano, Cyclone V 5CSEBA6U23I7).

## Thesis

Robert Peip established that an NDS core is feasible — his unreleased prototype ran 2D titles
(e.g. Kirby: Squeak Squad) correctly — and described the NDS as "roughly the GBA2P core with
bolts on." The blockers were never correctness; they were **resources**:

1. **Memory banks.** The NDS has a very large number of small, independently-addressed,
   tightly-timed memories (9 remappable VRAM banks, shared WRAM with 4 mapping modes,
   TCMs, per-engine palette/OAM, ARM7 WRAM…) that all want to be BRAM, on a device where
   BRAM is the scarcest commodity.
2. **Fitting.** Two CPUs (ARM946E-S + ARM7TDMI), two 2D engines, 16ch sound, and the card
   interface must fit alongside the MiSTer framework.

This project starts from **GBA_MiSTfits**, a heavily resource-optimized fork of the GBA2P
core. The optimization headroom won there is the budget we spend here.

## Scope

- **Implemented / compatibility work:** 2D games — ARM9 + ARM7, both 2D engines, VRAM
  banking, IPC, DMA, timers, sound, card interface, touchscreen, firmware/RTC/SPI,
  and save memory.
- **Now on the roadmap:** the 3D geometry and rendering engines; games requiring 3D are
  not compatible yet.
- **Out:** wifi (stubbed), GBA-slot compatibility mode, and DSi extensions.

## Layout

- `rtl/` — core RTL. NDS-specific sources are `nds_*.vhd`; shared primitives inherited
  from GBA_MiSTfits keep their names.
- `docs/` — architecture, the NDS→DE10 memory budget (read `MEMORY_MAP.md` first — it is
  the load-bearing analysis), and the roadmap.
- `sim/` — nvc-based simulation harness, same flow as GBA_MiSTfits. Run heavy benches on
  the cluster: `build/remote-sim.sh run_<x>_tb.sh` (see `build/`; `DIRTY=1` for the
  working tree, `ENV="OPCOUNT=..."` for generics).
- `build/` — k8s pod driver for remote nvc runs, patterned on GBA_MiSTer's
  `build/remote-build.sh` Quartus flow.
- `sys/` — MiSTer framework (copied from GBA_MiSTer, unmodified).

## Reference material

- `../GBA_MiSTer` — GBA_MiSTfits fork: donor core and proving ground.
- `../NitroSDK`, `../NitroSystem` — public reconstructions of the official SDKs; used as
  hardware ground truth (register maps, memory maps, boot protocol) alongside GBATEK.

