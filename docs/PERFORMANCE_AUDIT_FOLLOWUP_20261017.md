# Performance audit follow-up — 17 October 2026

The approved post-freeze comparisons are complete. **Frozen private Beta12
remains the selected runtime.** No accepted pointer, ZIP, FPGA image, host
binary or public Release was changed. This branch adds measurement reports
and updates the architecture/audit notes; the diagnostic and rejected prototype
sources remain preserved privately with build receipts and exact patches.

## What the measurements changed

| Experiment | Evidence | Decision |
| --- | --- | --- |
| Publication on CPU1 | Exact frozen helper, four runs per setting per scene; throughput fell 1.75% in the cave, 1.24% in combat and 3.98% in NSMB. | Retain CPU0. |
| Renderer CPU versus wall profiling | Setup uses about 2.84/2.65 ms CPU per rerendered cave/combat pair; clear plus final processing uses 1.07/1.02 ms. | Substantial serial compute is measured, but these are instrumented costs, not a promised saving. |
| Parallel clear/final prototype | Full service and 2,960 complete-buffer comparisons passed. All three option combinations failed native qualification across five saved scenes. | Keep phases unchanged in the accepted runtime. |
| Packet-input Normal-NC | Four runs per arm per scene: frozen BASE, same-binary OFF and ON. | INCONCLUSIVE_BASELINE_SHIFT; no promotion. |

| Scene | Mapping ON vs same-binary OFF | ON vs frozen BASE | OFF baseline agreement |
| --- | ---: | ---: | --- |
| BAT | +2.297% | +2.843% | Fail |
| FIGHT | -0.313% | +1.482% | Fail |
| NSMB | -0.256% | +0.123% | Pass |

Publication pairs are not unique animation FPS. Four balanced samples are
descriptive; they are not a confidence interval. All valid samples remain in
the reports, with exclusions and unresolved trace gates identified. A changed
option-off baseline prevents attributing the entire ON-versus-BASE difference
to the option, while same-binary ON/OFF differences remain useful observations.
There is no validated 60 FPS result or measured absolute ceiling.

NSMB meets the packet experiment's throughput limit and option-off baseline
agreement, but its complete pacing gate remains unresolved: one frozen-baseline
capture contains two raced Replay snapshot records. Its throughput and video
remain retained; no runtime fault was observed.

## Coverage of the audit's theories

| Audit item | Current coverage |
| --- | --- |
| Q1 / M3: serial phase ranking and setup CPU versus wall time | Measured. Setup exceeds the proposed 1.5 ms CPU threshold in both Castlevania rooms. Its internal cost breakdown and a validated optimization remain open. |
| Q2: move publication to CPU1 | Tested live with the frozen helper; rejected for lower throughput in all three scenes. The optional host-poll change was not combined with it. |
| Q3: parallel pre/post-raster work | Parallel clear and final processing built and correctness-tested; native performance did not qualify. Moving polygon copying to CPU1 was not implemented because the working polygon/edge state needs an explicit ownership design. |
| M1: same-binary Normal-NC packet mapping | Completed with frozen/OFF/ON controls; did not qualify. |
| M2: cacheable packet input plus explicit maintenance | Not implemented. Kernel/cache correctness and stale-slot tests would precede performance work. |
| M4: interleaved framebuffer planes | Not implemented. Direct memory-behavior measurements are still missing. |
| M5: narrower texture-cache invalidation | Coherence CPU cost measured; invalidation/decode breakdown and optimization remain open. |
| M6: consolidate rectangle classifiers | Not implemented; a maintainability proposal with no demonstrated speed gain. |
| A1 / A2 / A3: IRQ intake, coherent transport, FPGA geometry | Deferred. No FPGA change or new evidence qualifying these architectural changes. |

The audit's separate risk list is not fully resolved. D2/D3/D4 informed the
expanded profiling and controlled comparisons; combat-state variability remains.
The always-on X-partition invariant (D1), ordered-readback counters (D8) and
guest-stall/replay-occupancy instrumentation (D10) were not added in this batch.
Shipping trace policy (D5), intake polling (D6), classifier consolidation (D7)
and polygon-copy ownership (D9) remain unchanged. No claim is made that the full
audit has been implemented or that its estimated cumulative 5–12% gain exists.

## Next bounded work

Improve combat setup repeatability alongside the next measurement. This batch
started with HP97–110, EXP69/70 and gold0/100 despite fresh suspend copies;
enemy phases and camera position also varied. Predeclare start-state checks or
investigate setup aligned to emulated frame progress before timing. Preserve
failed setup attempts and never filter completed measurements by their rate.
All twelve combat samples in this report remain retained.

1. **Break down polygon setup before changing it.** Measure texture lookup and
   decoding, polygon-state/edge preparation and scanline-list construction.
   Count adjacent texture-binding hits, repeated nonadjacent keys and unique
   keys per frame. Measure the added profiler's overhead in the same executable.
   `SetupPolygon` can mutate/decode the texture cache, so splitting its loop
   between workers requires explicit ownership; it is not an independent map.
2. **Investigate combat texture-coherence work.** The diagnostic measured about
   0.89 ms CPU in combat versus 0.07 ms in the cave, after separating the
   start-of-frame palette diagnostic. Count invalidated entries, scanned dirty
   regions and actual decoding work before proposing a narrower invalidation
   strategy. Preserve changing-VRAM/palette and remapping controls.
3. **Measure raster memory behavior before changing layout.** More SIMD and
   several traversal changes already failed. Cache-miss/traffic measurements
   can distinguish an arithmetic problem from a locality problem. The current
   evidence does not measure DDR bandwidth or prove every raster path is
   memory-bound. Any layout prototype needs full AA/depth/attribute oracles and
   NSMB/Mario Kart controls before live testing.

A separate NSMB-only final-pass experiment may be worth considering: the native
same-binary final-only arm reduced saved-scene wall time by about 4.7–4.9%, but
it did not improve the Castlevania combat target and has no live NSMB validation.
It is a future game-specific hypothesis, not an enabled feature.

Do not repeat unchanged the publication CPU1 setting, parallel clear/final
combination or the prior packet experiment. A changed experiment must state its
new question and gates before sampling; do not reinterpret a failed historical
gate as a pass. No new FPGA build, cacheable input mapping or overclock is
justified by these measurements alone.

## Reports and reproducibility

- [Publication placement](PUBLICATION_PLACEMENT_20261017.md): all live samples,
  query-priority audit correction, tail limitation and restoration.
- [Renderer CPU profile](RENDERER_CPU_PROFILE_20261017.md): phase CPU/wall costs,
  display flags, rejected snapshot and diagnostic limits.
- [Parallel phases](PARALLEL_PHASES_20261017.md): deterministic worker tests,
  complete-buffer checks and all 100 native timing measurements.
- [Packet controls](PACKET_MAPPING_CONTROLS_20261017.md): all live arms, paired
  differences, tail statistics, visual notes and module-lifecycle limitations.
- [Architecture](architecture.md), [updated audit handoff](CLAUDE_AUDIT_HANDOFF_20261017.md)
  and [frozen package](PRIVATE_BETA_20261017.md).

Tests ran at the stock 1 GHz point with one rig owner and no competing build.
Every qualified contact sheet and fresh restored NSMB snapshot was viewed.
All 54 protected paths, original save, clock and OBS settings were restored.
Private source patches, hashes, test harnesses and raw evidence are retained;
no game data or compiled artifact is added to public Git history.
