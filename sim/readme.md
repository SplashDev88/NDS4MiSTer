# Simulation

Same flow as GBA_MiSTfits: [nvc](https://github.com/nickg/nvc), three logical libraries
(`altera_mf` stub / `mem` primitives / `work`), self-checking testbenches run by
`run_*.sh` scripts with `--exit-severity=failure` as the pass/fail gate.

Short unit tests run fine on a laptop. Full-system benches (CPU boot, game boot,
differential traces vs melonDS) go to the x86_64 k8s host — budget hours-to-days for
seconds of sim time and design the benches to be checkpointable/self-checking, never
eyeball-checked.

## Scripts

- `run_analyze_all.sh` — analyzes + elaborates every RTL file; the CI smoke gate.
  Run after every RTL change.
- `run_vram_map_tb.sh` — unit test for `nds_vram_map` (VRAMCNT decode) against the
  NitroSDK `gx_vramcnt.c` truth table. 84 checks.
- `run_vram_torture_tb.sh` / `run_mainram_tb.sh` — M1 memory-fabric benches.
- `run_arm7_island.sh` / `run_arm9_island.sh` — CPU islands with self-checking
  mailbox exit tests (M2/M3).
- `run_arm9_cache.sh` — nds_cache9 exercise (write-back, clean/invalidate,
  I-cache staleness) on the island harness.
- `run_arm9_trace.sh` — per-retired-instruction trace for the melonDS
  differential (docs/TRACE_DIFF.md); `LOADADDR=33554432` boots a main-RAM
  workload instead of the boot ROM. The melonDS side lives in
  `sim/melonds_tracer/`.
- `run_gpu_bg.sh` — M5 BG drawer line tests (text/affine/extended + ext
  palettes) vs the `gen_gpu_bg.py` golden model. Regenerate the hex inputs
  with `python3 sim/tests/gen_gpu_bg.py` (from `sim/tests/`) first.
- `run_gpu_obj.sh` — M5 OBJ drawer line tests (tile/bitmap/affine sprites,
  ext palettes, priority merge) vs `gen_gpu_obj.py`; same regenerate flow.
- `run_gpu_obj_budget.sh` — the OBJ per-line HW_TIME_LIMIT budget: proves the
  954/1210 H-Blank switch and the non-affine walk's exact truncation boundary
  on a 1024-hardware-cycle line (1 hw cycle per field pixel, clip elisions
  charged at setup/walk-end). No generated vectors.
- `run_vram_ls_tb.sh` — M5 VRAM line-server tests: the renderer BG/OBJ/
  ext-palette read channels of `nds_vram` vs the `gen_vram_ls.py` golden
  (independent GBATEK mapping model), with CPU-port differential reads and
  concurrent-channel arbiter checks; same regenerate flow.
- `run_gpu_merge.sh` — M5 merge tests (windows, priority, blending) vs
  `gen_gpu_merge.py`.
- `run_gpu_timing.sh` — nds_gpu_timing cadence/DISPSTAT/VCOUNT unit tests.
- `run_gpu2d.sh` / `run_gpu2d_frame.sh` / `run_gpu2d_timed.sh` — engine-A
  orchestrator: line cases, full frames (functional pacing), and full frames
  at the real dot cadence with the drop monitor as the fetch-budget gate
  (`CE_DIV=3` = the planned 100.5/33.5 MHz topology). Golden vectors from
  `gen_gpu2d.py` / `gen_gpu2d_frame.py`.
- `run_dual_boot.sh` — M4 exit: dual-CPU boot through the card-header HLE
  loader (`sim/tests/build_nds_dual.sh` image), IPC handshake, joint exit.
- `run_top_frame.sh` — M5 exit: boots a .nds through `nds_top` (the full
  integrated system: CPUs, membuses, WRAM/main RAM/VRAM, IPC/IRQ/timers/
  syscnt, gpu timing + gpu2d) and dumps every rendered engine-A frame.
  `HEXFILE=` picks the image (default the M4 dual-boot one;
  `sim/tests/nds_2d.hex` is the 2D scene, rebuilt by
  `sim/tests/build_nds_2d.sh`). Heavy — pod only. Compare against melonDS:
  `sim/melonds_tracer/build/melonds_fbdump image.nds mds.txt 10` then
  `python3 sim/tests/compare_fb.py top_frame_fb.txt mds.txt` — pixel-perfect
  is the M5 exit gate. Hand-rolled sample images must follow the melonDS
  PU/POWCNT rules documented at the top of `sim/tests/arm9_2d.s`
  (established on 0.9.5, unchanged in 1.1).
  Samples: `nds_2d` (text/affine/OBJ), `nds_2dh` (ext palettes + blending),
  `nds_2dw` (windows + mosaic), `nds_2dk` (Kirby: Squeak Squad's measured
  video mode — BG mode 0, BG3 256-colour *text* on the standard palette
  with a palno sweep that must be ignored, OBJ extended palettes, both
  engines rendering the same scene so every A-vs-B difference is the
  OBJ ext-pal path; `sim/tests/build_nds_2dk.sh`), `nds_sdk2d` (devkitARM/libnds-built
  DUAL-SCREEN C scene packed by ndstool — `sim/tests/sdk2d/build.sh`, needs
  devkitPro with the nds-dev group; custom crt0, because stock libnds
  2.x/calico needs the ARM7 BIOS IRQ trampoline and DMA, which don't exist
  yet). Engine B (M6) dumps to `DUMPFILE_B`; melonds_fbdump takes the
  bottom-screen file as its optional 4th argument. Frame-diff scene rules
  (melonDS-oracle constraints) live at the top of `sim/tests/arm9_2d.s` —
  plus: no OBJ V-mosaic (melonDS's OBJ mosaic-Y counter free-runs, so its
  phase depends on setup timing; BG V and OBJ/BG H are deterministic).

## Adding a bench

1. `tb_<x>.vhd` instantiating real RTL (+ `ddrram_model`/`sdram` from GBA sim when the
   fabric is involved), asserting a concrete end condition.
2. `run_<x>_tb.sh` following the existing pattern; generate any ROM/BIOS `.hex` inputs
   inline with python (see GBA_MiSTer/sim/run_gba2p_sdram_tb.sh for the reference).
3. Keep `STOP_TIME` overridable via env, default tight.
