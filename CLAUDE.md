# Nitro_DarkSide — Nintendo DS core for MiSTer

2D-only NDS core for the DE10-Nano. Started from GBA_MiSTfits (a resource-optimized
GBA2P fork); the optimization headroom won there is the budget spent here.

**Status:** Kirby: Squeak Squad is playable on hardware. Not built: 3D, wifi,
divider/sqrt (`0x04000280`–`0x2B8` reads as 0), savestates, save persistence past
power-off (the 8 KB AUXSPI EEPROM lives in BRAM only).

## Device budget — read this before writing RTL

`5CSEBA6U23I7`: **41,910 ALMs, 553 M10K, 4,191 LABs.** The shipping audio image is
at 98% ALM / 100% LAB. **The fit closes by about 2 LABs.** Anything that adds
registers can reopen it, so cost new RTL in LABs before you write it.

- **Predict in LABs, not ALMs.** Summing "ALMs needed" per hierarchy node
  over-counts badly once register packing is involved (a 920-ALM estimate came in
  at 501). The LAB estimate has been reliable.
- **Seed spread on an *unchanged* netlist is 1.5–4 ns.** One fit never establishes
  that a slack change is real. Sweep seeds; it is worth more than placer effort.
- **Area work does not buy timing.** Measured three times: freeing 2,159 ALMs moved
  2:1 slack 0.4 ns; freeing 501 more moved it 0 ns; and the config with *more* free
  area has *worse* slack. 70% of the ARM9 critical path is interconnect.
- **`nds_sound` is a dead end for area** — 5,945–6,016 ALMs across 12 measured
  builds, 71 ALMs of spread. Three serialization attempts each made it *bigger*.

## Build configurations

Generics are in **`nds_port_wrap.vhd` at the repo root** (not `rtl/`), line ~212.
Two images ship, and they are **mutually exclusive**:

| | SOUND_ENABLE | DEBUG_ENABLE | HDMI | notes |
|---|---|---|---|---|
| audio | 1 | 0 | no | analog only, needs the IO board; `nitrodbg` will not work |
| hdmi | 0 | 1 | yes | no audio at all; this is the `nitrodbg` image |

Measured costs: **HDMI +3,579 ALMs / +344 LABs / +51 M10K**, **DEBUG_ENABLE +614
ALMs / +46 LABs**. Audio+HDMI is short ~3,057 ALMs — a fixed-resolution SPG in place
of ascal saves ~2,200, which still does not close it. Audio+`nitrodbg` misses by ~44
LABs.

HDMI's pixel clock is **marginal on seed**, sitting within ±0.22 ns of zero; sweep
rather than assume. `NDS_HPS_AUDIO=1` adds the DDR3 audio ring (~198 ALMs) — the
transport is built and proven on silicon with `tools/audio-tone.sh`, but the SPU
daemon is not, so that is not game audio.

## Workflow

**There is no local Quartus.** Fits and long sims run on k8s pods.

```bash
build/remote-sim.sh run_analyze_all.sh          # smoke gate, run after every RTL change
DIRTY=1 build/remote-sim.sh run_top_frame.sh    # working tree instead of HEAD
ENV="OPCOUNT=200000 SEED=7" build/remote-sim.sh run_vram_torture_tb.sh
build/remote-build.sh                           # Quartus fit
build/ablation-matrix.sh                        # 4 fits, 2 pods, ~45 min
```

Sim throughput is ~675 traced instructions/wall-second. Booting a real cart to
display-on is an overnight job; **breakpoint-bisecting on hardware with
`tools/nitrodbg.sh` is ~4000× faster** and is the right tool for boot-path bugs.

Deploy with `tools/deploy-core.sh` (refuses to overwrite a remote name, verifies
sha256 on the device).

## Memory strategy

VRAM **E–I (144 KB) is M10K**; **A–D (512 KB) is SDRAM**. If A–D also had to be BRAM
the core would not fit — this split is the whole reason the port works.

The renderer reads A–D over `sdram.sv` ch1, **64-bit line-addressed**, with one
cached line **per channel**. Sizing was measured before it was built, and the obvious
design is the wrong one: a single *shared* line buys **1%** (eight channels interleave
and evict each other); per-channel buys **76%**. Line alignment is load-bearing — a
sequential SDRAM burst wraps inside its aligned block, so an unaligned request returns
the same eight bytes rotated.

Main RAM is SDRAM ch2, borrowed by the CPU VRAM A–D path. Card ROM (≤128 MB),
firmware, mailbox and framebuffer are DDR3.

Clock plan is exactly 1:2:3 — **33.513982 / 67.027964 / 100.541946 MHz**. The ARM9
island runs 2:1 at 67.028 MHz, the real ARM946E-S clock. Only integer ratios are
viable: cross-domain setup budget follows edge alignment, not period.

## Traps that have each cost days

1. **`ldm^`/`stm^` banking.** r8–r12 are banked **only in FIQ**; r13/r14 in every
   privileged mode. Both CPUs had the redirect wrong. Fixed; regression is
   `sim/tests/arm7_ctxrestore` (expect `PASS bitmask=0000000F`). Nothing in GBA code
   exercises this — it takes a preemptive scheduler, which is what NitroSDK has.
2. **A derailed ARM7 never faults.** `0x00000000` decodes as `andeq r0,r0,r0`, so it
   marches +4 through I/O space until it hits an undecodable word. The reported fault
   address can be ~1.2M instructions downstream of the cause. Do not anchor on it.
3. **Everything ties off to `startVal`, never to zeros.** `REG_SAVESTATE_CPUMIXED`'s
   is `0xCC0` — supervisor mode with FIQ/IRQ masked. Zero it and the ARM9 boots in
   user mode with interrupts live.
4. **A defaulted `in` port on `nds_top` turns a missing testbench connection into a
   silent deadlock**, not an elaboration error. Adding a port means updating every
   bench that instantiates it.
5. **M10K read ports are registered.** A testbench that serves memory
   combinationally will hand back the word at addr+4 — which looks like working RTL
   right up until every boot-ROM workload executes word[1] of its own vector table.
6. **`nitrodbg` caveats:** `DEBUG_ENABLE=0` compiles out `nds_debug` *and*
   `nds_perf`. peek/dump is exact for main RAM and returns convincing garbage
   elsewhere. `step9 1` never retires an instruction — use ≥10. Before believing a
   `REACHED`, **check the occurrence count**: only a PC whose *first* occurrence is
   inside the window says anything, so prefer `count == 1` PCs.
7. **`NDS_LW_DEBUG` hangs the board.** Check the QSF before touching the LW bridge.
8. **Choosing a timing cut off endpoint names alone** is how a build got spent on
   logic that turned out not to be on the path. Read the full path element by
   element from `NDS.paths_fam.rpt`.

## Verification discipline

melonDS 0.9.5 is the oracle for differential traces (`docs/TRACE_DIFF.md`), **and it
is fallible** — the ARM9 trace found 1 RTL bug and 2 melonDS bugs. Where DS test ROMs
do not exist, generate them: `gen_arm9_torture.py`, `run_shifter_equiv` (294,912
cases), `run_mosaic_equiv` (6,144), `run_vram_torture_tb`.

**Frame benches do not catch drawer regressions** — use the equivalence benches
(`run_drawer_affext_equiv.sh`, `run_drawer_text_equiv.sh`, `run_sound_equiv.sh`).
And verifying that control flow resumes is not the same as verifying that *context*
resumed: an earlier version of the `ldm^` regression passed while checking only the
resume address and the T bit.

## Open

- **ARM9 2:1 does not close static timing** — Fmax ~62.8 MHz, TNS −26.6 ns after four
  measured cuts. It ships anyway and works on this silicon. The residual is the
  barrel shifter feeding `membus9|state`; the path traverses the shifter *twice*
  through a forwarding loop, so a register inside the shifter breaks only one pass.
- **Five SDC-cut paths are asserted, not proven** (`0a4713b`) — one setup, four hold.
  If the `clkMemIndex` reasoning is wrong the symptom is corrupted main-RAM reads on
  silicon, not a failing testbench. Re-derive before trusting an RBF built with them.
- **No sim reproduces the affine OBJ path as built** — `nds_drawer_obj.vhd` wraps its
  affine bounds guard in `synthesis translate_off`.
- Compatibility list is one title. Save persistence, savestates, div/sqrt, 3D, wifi.

## Docs

`docs/MEMORY_MAP.md` is the load-bearing analysis — read it first. Then
`ARCHITECTURE.md` (subsystem→donor map), `NDS_HARDWARE.md` (hardware ground truth),
`SDRAM.md`, `HPS_AUDIO.md`, `TRACE_DIFF.md`, `NTR_EVA_TESTER.md`, `ROADMAP.md`.

**Docs go stale faster than the tree.** Check the RTL before repeating a doc's claim,
and prefer `git log -- <file>` over a status line written weeks ago.
