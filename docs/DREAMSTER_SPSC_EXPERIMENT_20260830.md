# DreamSTer-style ARM synchronization experiment

## Scope

This branch is based on the exact `v0.3.0-beta.3` public source checkpoint.
It changes only the ARM hybrid-3D service; the known-good FPGA RBF, HDMI
timing, save logic, sound, touch input, emulated GPU state, and raster results
are unchanged.

The earlier DreamSTer review ranked a fixed replay arena plus SPSC indices as
the next low-to-medium-risk transport optimization after write-combined plane
publication. The public checkpoint already had the fixed 513-slot arena, but
every packet publication and claim still entered a mutex. This experiment
completes that optimization and also removes the same mutex overhead from the
software renderer's producer/consumer semaphores on Linux.

## Changes

- Publish and claim fixed replay slots with release/acquire monotonic indices.
  Each Cortex-A9 writes only its own cache-line-separated index.
- Use the producer and consumer indices as Linux private-futex words when the
  queue is truly empty or full. Normal backlogged packet transfers do not
  enter a mutex or the kernel.
- Preserve a condition-variable fallback for non-Linux host tests.
- Preserve the 513 physical slots / 512 visible packet invariant. A claimed
  slot cannot be overwritten while replay is using it, even when the producer
  fills all other slots.
- Use an atomic counting semaphore plus private futexes for the Linux headless
  renderer. The macOS test implementation remains unchanged.

No packet, command, frame, or polygon is skipped by these changes.

## Evidence

Existing hardware telemetry recorded a replay queue high-water mark of
512/512, so reducing saturated producer/consumer arbitration targets an
observed condition rather than a hypothetical one.

Five retained AArch64 Linux A/B runs of the headless semaphore measured:

- 18.096 microseconds median round-trip handoff with this branch;
- 19.664 microseconds median with the public implementation;
- approximately 8.0% lower wall-clock handoff latency and 9.3% less process
  CPU time per handoff;
- approximately 29.9% lower median time for a 100,000-token burst.

Five AArch64 Linux runs of the complete 1,024-packet validated replay-arena
fixture measured a 1.864 microsecond median per packet, compared with 1.957
microseconds for the public mutex queue: approximately 4.8% lower end-to-end
packet retirement time in that synthetic workload.

The portable macOS replay benchmark intentionally exercises the fallback and
does not predict the HPS futex result. It is retained as a correctness and
ownership stress test. ARMv7 hardware telemetry is required before claiming a
whole-game FPS improvement.

## Acceptance gates

- Hybrid-3D service self-test, including two complete replay-arena turns.
- Fake shared-memory lifecycle and session-reset test.
- Headless semaphore ping-pong, burst, reset, and timed-wait test.
- Static ARMv7 hard-float service build and self-test.
- MiSTer A/B gameplay and telemetry are intentionally left for maintainer
  approval; this experimental branch must not replace the public build without
  that hardware check.
