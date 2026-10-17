# Claude audit handoff — NDS4MiSTer private beta freeze

Copy the prompt below into Claude with repository access. The private package
and its SHA-256 sidecar are delivered separately; they are not GitHub Release
assets. No ROM, save, firmware dump or captured game data is required for an
initial source audit. Private hardware evidence can be reviewed locally by the
owner when a hypothesis requires it.

---

Please independently audit NDS4MiSTer for opportunities to improve speed,
frame pacing, input responsiveness, audio continuity and overall playability.
Start with a read-only review and give me a prioritized implementation plan.
The current private beta is frozen; do not change that baseline or publish a
release as part of the audit.

Repository: https://github.com/SplashDev88/NDS4MiSTer
Branch: `experiment/postfreeze-performance-20261017`.
The runtime source remains the frozen Beta12 implementation; post-freeze
reports on this branch describe separate private diagnostic/rejected prototypes.
The original freeze branch remains `experiment/castlevania-rooms-20261016`.
Use the freeze/source revision from the supplied package manifest. If reviewing
branch HEAD instead, report its exact commit and any difference from that freeze.
The renderer, host and FPGA have separate source identities and binary hashes.
Do not assume one branch checkout without the recorded FPGA overrides reproduces
all shipped artifacts.

My priority is faster, smoother play without broken graphics, changed game speed,
save loss or regressions in other games. Per-game ARM paths are acceptable when
selected from a verified cartridge identity and backed by controls. I am open to
larger architecture changes or FPGA/ARM repartitioning if measurements justify
them. Distinguish low-risk exact optimizations from compatibility compromises.

Read first:

Read the post-freeze measurement reports before proposing the same experiments:
`docs/PERFORMANCE_AUDIT_FOLLOWUP_20261017.md`,
`docs/PUBLICATION_PLACEMENT_20261017.md`,
`docs/RENDERER_CPU_PROFILE_20261017.md`,
`docs/PARALLEL_PHASES_20261017.md` and
`docs/PACKET_MAPPING_CONTROLS_20261017.md`. They supersede hypotheses about moving
publication to CPU1 and the expected benefit of parallel clear/final processing.
Instrumented setup CPU time is substantial, but a new setup optimization still
needs a breakdown of texture lookup/decode, polygon/edge preparation and
scanline-list construction. Do not assume setup is safe to parallelize: its
texture cache can mutate and decode textures.

1. `docs/PRIVATE_BETA_20261017.md`: final experiment decision, selected runtime,
   package/provenance, install and rollback, measured improvements and limitations.
2. `docs/architecture.md`, `docs/DEVELOPMENT.md`, `docs/hybrid-3d-abi.md`,
   `docs/hybrid-3d-session-policy.md`, `docs/hybrid-3d-hps-lifecycle.md`.
3. `docs/CASTLEVANIA_SCOPED_ADAPTIVE_PERFORMANCE_20261017.md`,
   `docs/CASTLEVANIA_PREPARED_SPRITE_PERFORMANCE_20261017.md`,
   `docs/CASTLEVANIA_POST_CACHE_PROFILE_20261017.md`,
   `docs/CASTLEVANIA_ADAPTIVE_BALANCE_PROFILE_20261017.md`, and the final
   `docs/CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md`.
4. `docs/CASTLEVANIA_PACKET_MEMORY_EXPERIMENT_20261017.md`,
   `docs/CASTLEVANIA_ADAPTIVE_RANGE_EXPERIMENT_20261017.md`, and other relevant
   rejection reports before proposing an already tested shortcut.
5. `docs/BUGFIX_EXPERIMENT.md`, `docs/GAME_CLOCK.md` and
   `tools/standalone_host/README.md` for correctness, frontend and RTC constraints.

Architecture facts to verify against code:

- DS ARM9/ARM7 execution, DMA, timers, interrupts, sound and console timing are
  in the FPGA. Both 2D engines, 3D geometry/rasterization and final composition
  run on the dual-core Cortex-A9 ARM helper. Complete screen pairs go back to FPGA.
- Intake and primary raster work share CPU0; ordered replay and the second
  raster worker share CPU1. Publication is bounded and prioritized on CPU0.
- The tested Dawn of Sorrow USA revision-0 profile is `ACVE`, revision 0,
  header CRC32 `c51a7d99`. Two matching header reads select the profile at a fresh
  session. Other games retain their established policies.
- Full-rate drawing is selected and frame skipping is off, including NSMB.
  Completed publication pairs, LCD tags and the OSD counter are not distinct
  animation FPS, guest CPU speed or input latency.
- Header/policy/packets use Device memory. Pixel publication uses a separate
  WC/Normal-NC mapping without memory-type aliases. The input-NC prototype is
  rejected and absent from the freeze. Keep all lifecycle checks and barriers.
- The package runs at the stock tested 1 GHz ARM point. FPGA routing completed
  but static timing closure is unresolved. Performance gains must not be bought
  by an undisclosed overclock or changed emulated timing.

Focus workloads:

- Castlevania: Dawn of Sorrow, the cave immediately left of the Lost Village
  save room, standing on the middle platform near the respawning bat.
- The upper-right combat room reached left, up one screen, then right, with
  Warg, armored enemy and spawning zombies. Enemy state/damage vary between runs.
- New Super Mario Bros. castle/lava/rotating-hazard scene as a required live
  regression control. Include Mario Kart DS heavy saved-scene controls for
  scheduling changes, plus non-profile/unknown-header and profile-transition tests.

What measurements already suggest:

The accepted Beta11 comparison delivered about 22.10 cave and 21.47 combat
publication pairs/s, with NSMB about 44.66. Against Beta10, those changes were
+2.386%, +3.935% and +0.762%. The freeze selects Castlevania Beta12: its 40%
worker-range follow-up observed 22.64 cave, 21.88 combat and 44.84 NSMB pairs/s,
or +2.493%, +1.836% and +1.055% against its matched Beta11 runs. Target p95 gaps
improved, while NSMB p95/max gaps were slightly higher. Native snapshot costs
also remain disclosed in the final report. There is no validated 60 fps result.

After prepared-sprite reuse, sampled Engine B composition cache hit about 97.5%
of lines. Instrumented 3D raster wall time was around 15.3 ms, with primary
worker around 14.1 ms and secondary around 10.6–11.0 ms; these overlap and cannot
be added. CPU leaf samples emphasized flat rectangles, gray rectangles, packet
acquisition, geometry execution, replay and polygon submission. Matrix multiply
alone was about 0.112% in the sampled cave, so matrix-only FPGA offload is not
the leading demonstrated opportunity. This does not rule out a broader geometry
partition; quantify its transport, readback and synchronization costs.

Please investigate, without treating these as proven wins:

- Remaining exact scalar work, SIMD opportunities, load/store traffic and branch
  behavior in rectangle/gray-overlay rendering. Preserve DS rounding, AA,
  transparency, depth, stencil and translucent polygon-ID behavior.
- CPU0 contention, wakeups, task granularity, load estimation, cache locality and
  worker handoff. Explain why a proposal differs from rejected global queue/band
  changes and from the final profile-specific balance experiment.
- Packet acquisition/replay overhead and query/geometry stalls. Look for avoided
  duplicate work or safer batching without weakening ownership, record validation,
  backpressure, FIFO credits or quiesce guarantees.
- Phase-correct sprite preparation and cache overhead. Already prepared sprite
  identity yields gains; blindly reusing OAM/VRAM revisions previously failed.
  Measure dynamic-workload costs and memory footprint, not only cache-hit scenes.
- End-to-end pacing and latency across guest progress, picture readiness,
  publication, scanout and audio. Higher average throughput can still hide worse
  tail latency, repeats, audio underruns or input delay.
- Correctness and maintainability risks in the accumulating fast paths, including
  overflow/undefined behavior, invalidation gaps, reset/profile transitions and
  missing regression coverage. A simpler implementation may outperform another
  special case; show the evidence.

Do not repeat these unchanged:

- Publication on CPU1: the exact frozen helper lost about 1.75% cave, 1.24%
  combat and 3.98% NSMB throughput across four runs per setting per scene.
- Parallel clear/final processing: exact-output checks passed, but none of the
  three option combinations met native gates. NSMB final-only saved-scene
  improvements remain an unvalidated game-specific hypothesis.
- The fresh same-binary packet-input NC experiment: cave improved about 2.30%
  against OFF, combat fell 0.31%, and OFF did not agree with the frozen baseline
  in those rooms. Preserve the inconclusive baseline decision and all samples.
- Global adaptive scheduling: a Mario Kart control regressed about 5.7%.
- Packet-input NC: cave +1.510%, combat +1.243%, NSMB -1.179%; failed the declared
  NSMB limit. The NSMB comparison did not isolate mapping from binary layout.
- Linear attributes plus vertical edges: NSMB -1.272% despite target gains.
- Vertical edges alone: native improvements did not survive the live cave test.
- Packed alpha / early alpha rejection: correct output but no acceptable speed win.
- Input-row sprite cache: changing/VRAM workloads regressed roughly 11–17%.
- Validation fast paths: fallback/non-pair cases regressed. Keep strict validation.
- Whole-tile temporal reuse: zero exact unchanged tiles in the sampled active
  workload. That is evidence against that workload/approach, not all possible reuse.

Validation expectations for each proposed change:

1. State the mechanism, affected files/functions, expected scope, evidence,
   uncertainty, likely gain range and exact failure/fallback conditions.
2. Preserve full color, depth and attribute outputs, including hidden buffers;
   test AA, shadow, windows, capture, mosaic, VRAM/palette changes, delayed workers,
   fresh sessions and profile transitions. Include a negative control where useful.
3. Test exact-output oracles and full service checks on a host or ARM-emulation
   Docker environment. Never run the aggregate service self-test on the MiSTer;
   it can exhaust memory. Existing build/test entry points are in DEVELOPMENT.md.
4. Separate stock-clock native cost tests from unprofiled live comparisons.
   Use fresh suspend copies for every launch, at least four runs per arm and
   balanced order. Prefer same-binary switches, with exact frozen-helper controls
   and a predeclared option-off baseline-agreement gate for rebuilt helpers.
   Improve combat start-state repeatability before chasing small effects.
   Retain every valid sample; disclose exclusions and variable
   enemy/timer states. Existing target gate is >1% improvement in both scenes,
   with NSMB mean no worse than -1%, plus correctness and health checks. These
   engineering gates are not statistical confidence intervals.
5. Report median, p95/p99 and worst delivery gaps, repeated pictures, audio
   behavior and input response where actually measured. Add longer gameplay and
   transition coverage. Do not substitute source counters or thresholded noisy
   analog changes for distinct animation FPS. Separate inherited tests from reruns.
6. One owner controls the RetroTINK rig. No extra SSH polling, profiling, heavy
   builds or image inspection during capture windows. Preserve all saves/settings,
   restore original NSMB/OBS/clock state and visually verify restoration. Local
   evidence and access are provided by the owner, not embedded in public source.

Deliver a concise executive assessment followed by a prioritized table of findings
and opportunities: source references, evidence vs hypothesis, expected benefit,
regression risk, effort, validation plan and an accept/reject criterion. Include
quick wins, medium changes and at most a few justified architectural options.
Separate observed defects from performance ideas. Finish with the next three
bounded experiments you would run and why. Clearly identify anything you could
not verify. Do not claim measurements you have not performed.
