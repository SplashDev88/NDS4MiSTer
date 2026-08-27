# Architecture

## Goal

Determine whether the MiSTer DE10-Nano HPS can run Nintendo DS emulation at full speed using melonDS as the base emulator.

The first milestone is intentionally measurement-driven. We should avoid FPGA offload work until the ARM benchmark identifies the real bottlenecks.

Current results show that stock-HPS melonDS interpreter-only is not enough for representative commercial games. The project now has two active architecture tracks:

- Track A: HPS runs melonDS, FPGA assists/offloads video.
- Track B: FPGA runs DS system core, HPS runs GPU renderer and framebuffer output.

Track B is documented in `docs/fpga-system-core-hps-gpu.md`.

## Target Platform

- Board: MiSTer DE10-Nano
- CPU: dual-core ARM Cortex-A9, ARMv7
- OS: Linux userspace on HPS
- FPGA role, phase 1: display/framebuffer sink only
- Emulator base: melonDS
- Initial renderer: software renderer

## High-Level Components

```text
+-------------------------+
| MiSTer frontend scripts |
+------------+------------+
             |
             v
+-------------------------+      +----------------------+
| nds_runner / nds_bench  | ---> | ROM / saves / config |
+------------+------------+      +----------------------+
             |
             v
+-------------------------+
| Headless melonDS port   |
| - ARM CPU emulation     |
| - DS GPU software render|
| - SPU/audio generation  |
+------------+------------+
             |
    +--------+--------+
    |                 |
    v                 v
+--------+       +----------+
| MiSTer |       | MiSTer   |
| video  |       | audio    |
+--------+       +----------+
```

## Backend Boundary

The local code owns the platform boundary:

- CLI and MiSTer integration.
- Timing and benchmark reporting.
- ROM path, save path, firmware/BIOS configuration.
- Video, audio, and input adapters.

melonDS should own DS emulation correctness:

- ARM7/ARM9 emulation.
- Scheduler and timing model.
- 2D/3D software rendering.
- SPU/audio generation.
- Save-state serialization, if usable headlessly.

This boundary keeps the first benchmark honest: we measure melonDS core performance without prematurely changing emulation behavior.

## Threading Strategy

Start single-threaded unless melonDS already exposes safe internal threading for a subsystem. The Cortex-A9 has two cores, but cross-thread synchronization can erase the benefit quickly.

Benchmark phases should record non-intrusive throughput first:

- Total frame time.
- Effective FPS and speed percentage.
- Backend overhead outside `RunFrame()`.

Component timing must be handled carefully on the Cortex-A9. High-frequency wall-clock probes inside melonDS' scheduler and GPU loop distort the benchmark enough to invalidate throughput conclusions. Use A/B diagnostic builds or a low-overhead profiler before changing architecture.

If full speed is missed on representative workloads, the profile determines whether to:

- Tune compiler flags and hot build options.
- Enable melonDS fast paths.
- Split rendering or audio onto the second core.
- Consider FPGA offload for a measured bottleneck.

## Full-Speed Target

Nintendo DS nominal display rate is about 60 frames per second. A 600-frame benchmark should complete in 10 seconds or less of wall time to be full speed.

For benchmark reporting:

- `elapsed_seconds <= frames / 60.0` means full speed or better.
- `speed_percent = target_seconds / elapsed_seconds * 100`.

## Phase Plan

1. Build a headless benchmark harness with stable output. Done.
2. Vendor melonDS and compile the minimal core on desktop Linux. Done.
3. Replace the null backend with melonDS. Initial direct-boot backend done.
4. Run the benchmark on MiSTer HPS with non-intrusive timing. Done for the smoke fixture.
5. Measure representative commercial/homebrew workloads.
6. Measure renderer and CPU ceilings on commercial ROMs. Done for Chrono Trigger and New Super Mario Bros.
7. Prototype GPU trace/replay to validate FPGA-system/HPS-GPU split.
8. Evaluate 2D renderer offload and FPGA-system-core tracks against measured replay cost.
9. Add MiSTer framebuffer output after the selected split is clear.
10. Add controller, audio, save, and menu integration.

## Current Performance Read

On the current `nds-bootstrap` smoke fixture, the MiSTer HPS can run the headless melonDS path at full speed:

- `mister-o3-lto-notiming-static`: 600 frames in 8.7446 seconds, 114.4% speed.
- `mister-o3-norender-notiming-static`: 600 frames in 3.5700 seconds, 280.1% speed.

This means the ARM interpreter/scheduler path is viable for this light ROM, while software video rendering is the dominant measured cost. The smoke fixture is not representative enough to declare Nintendo DS emulation generally viable; the next decision point must use heavier ROM coverage.
