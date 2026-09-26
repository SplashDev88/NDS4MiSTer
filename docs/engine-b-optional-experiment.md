# Engine B toggle experiment — 260925-EBO1

> Historical experiment notes. The accepted combined v0.5.1 build and
> current validation are documented in [V051_GRAPHICS_AND_PERFORMANCE.md](V051_GRAPHICS_AND_PERFORMANCE.md).

This is a private test on top of the published v0.5.0 source. It is not a new
release and has not yet passed MiSTer gameplay testing.

## What the setting does

- **Engine B (next Reset) On:** v0.5.0's paired Engine A and Engine B output.
- **Off:** render Engine A and show its completed picture in both screen
  positions. Skip B's sprites, 2D drawing and composition. Content that a game
  draws only with B is missing, including menus or touch-screen information.
- Apply a change with Reset or a completed ROM load. A menu edit alone, or
  restarting only the ARM service, does not change the running policy.

The DS CPUs, sound, saves, touch, TATE, display capture, GX readback, stock
1 GHz clock and write-combining path are retained. Off does not change the
guest's registers, disable guest B writes, or discard capture side effects.
Engine A-only is not the same as selecting one physical DS screen: games can
swap the engines between the two screens.

## Why a matching FPGA/helper pair is required

The old Off setting cuts palette, OAM, 2D/VRAM and LCD-phase transport needed
by the current ARM renderer, and disables its shared external scanout. EBO1
keeps that transport and scanout active for A-only rendering. H3P1 capability
bit 2 advertises the complete stream. B's drawing policy remains a separate,
immutable session flag. Old helpers reject the new capability; the new helper
rejects old matched Off sessions. Neither renderer may accept a partial stream.

Full-frame publication still owns two physical screen planes, including in
Off mode. Copying A into the other plane preserves the accepted framebuffer
ownership, TATE and reset behavior. DDR publication size and event transport
volume therefore remain unchanged. Savings come from omitting B rendering;
CPU, cartridge, transfer or 3D-limited scenes may gain much less.

## Validation

- Host and emulated ARM full service self-tests pass, including ordered
  replay, GX/capture paths, frame admission, delayed scanout acknowledgement,
  immutable published buffers and moving 3D comparisons in both modes.
- `nds_engine_a_only_test` compares 2,752,512 pixels against the normal paired
  renderer's A output. It checks routing changes, forced blank, power state,
  master brightness, changing palette/OAM and guarded direct framebuffers.
  Display capture VRAM is compared byte-for-byte (402,653,184 bytes checked).
  Profiling confirms zero B pixel, sprite or composition work in Off mode.
- Existing paired B cache and direct-output comparisons pass (7,077,888
  pixels per test), as does the separate display-capture oracle.
- `tools/test_matched_display.sh` checks the actual island's output gate,
  legacy/new matched policies at both memory latencies, reset/load latching,
  malformed/torn acknowledgements, quiescence, phase CDC and frame admission.
  The new output-gate test fails on the v0.5.0 source as expected.

In a 2,400-frame ABBA comparison under ARM emulation, Off uses about 50% less
rendering time when B scrolls, 27% less with B static, and 23% less with B blank.
The host also shows a reduction, with more scheduling noise during the build.
These are synthetic renderer workloads, **not game FPS measurements** and
not a physical Cortex-A9 benchmark. Test the same game scene in On and Off
before reporting a real gain. Known v0.5.0 regressions, including NSMB graphics
and speed, are not claimed fixed by this experiment.

## Private test kit

Install over the existing accepted v0.5.0/IFP3 installation. Extract the kit's
`Scripts` folder to the SD root. It adds two Scripts entries and hidden copies
of both complete core/helper pairs; it does not replace the published core,
Kickstart, saves, ROMs or MiSTer configuration during extraction.

1. Run **Scripts → NDS_Test_EngineB_EBO1_20260925**. It verifies the files,
   returns to MENU, stops the previous helper, selects the matched test helper,
   runs Kickstart, and loads the test core with no ROM.
2. Choose Engine B On or Off, then load the same game and scene. Reset or
   reload after each setting change. Check both picture and responsiveness.
3. To restore v0.5.0, run **Scripts → NDS_Restore_v050_20260925**. Set Engine B
   **On**, then reset/load the ROM; the published core still requires On.

Run the desired selector again after reboot or returning from another core.
The selector preserves the fixed service path required by the supervisor,
updates its checksum alongside the helper, and verifies the known launcher
and helper before changing anything. Do not manually mix the paired files.
