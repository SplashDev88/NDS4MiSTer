# Optimization investigation limits

- The three-NOP background NORMAL patch is rejected: video equality did not imply RAM/audio equality. No relaxed budget was requested or assumed.
- Palette uploads in the target room change real colors. Do not remove them or freeze weather/lighting.
- Whole-ROM hashes and game-code guards do not establish that an overlay is currently loaded. Overlay hooks need live identity checks; no overlay hook is installed by this experiment.
- FPGA guest RAM is not ordinary HPS memory. A software reference HLE does not establish a native trap mechanism. No RTL or new HPS service is authorized here.
- Core save states remain unsupported. Derived GPU-cache reset/restore tests do not add persistent core save states.
- `BASE_FIGHT1` reached the data-selection menu after player death. Its 58.5 publications/s is invalid as a combat measurement and excluded.
- The parked partial-image cache helped frozen repetitions but slowed changing inputs; it is not a beta candidate. Its row-copy path also needs explicit X-partition ownership before parallel use.
- Publication pairs are completed screen updates, not necessarily unique animation frames or end-to-end display FPS. OBS timestamps and detector counts are secondary evidence.
- Native ARM7 PC/cycle counts, per-frame FPGA CPU cycle accounting, missed VBlanks and total cartridge/DMA-byte counters are not all exposed by the retained bitstream. Missing measurements must remain unavailable.
- ARM7's FFTA2 hotspots include interrupt/scheduler work, timer overflow
  correction and live sound-status scans. They are not established idle or
  dead loops. A top-15 profile list omitted an additional >2% window; threshold
  analysis must use the full profile. Fixed-stride instruction sampling can
  alias periodic service work and is not native cycle accounting.
- FFTA2's dispatch misses are real fallbacks between handler tables. Do not
  delete the dispatch call or return a cached handler result: handlers may
  have effects. Five tables stayed unchanged after boot in one full library
  replay, which does not prove immutability in other scenes or reset paths.
  The 5,384,388 calculated comparisons are original work, not measured savings.
  No search patch or new beta is qualified by the classification trace.
- The later FFTA2 postindexed search patch passes 1,520 synthetic cases and
  preserves handler link values and ordered accesses, but fails the full
  library gate: one changed bottom frame, 405,899 changed stereo samples and
  non-code RAM differences. Its 0.713% reference instruction reduction is not
  a native speed result. It remains disabled; no battle/lifecycle/native
  qualification is claimed for this rejected version. New checkpoints show
  two changed elapsed-time words, which does not justify masking other RAM
  or classifying the audio difference as benign.

- **Native flag verification is mandatory.** The release supervisor intentionally strips inherited `NDS*`/`H3D_*` variables. The early lighting and cache A/B launches therefore tested disabled paths in both arms. Those live results cannot establish candidate performance. The isolated supervisor now admits only declared private Boolean flags and asserts the helper's actual environment; the rig checks that record before input/measurement.
- The native bat-room route uses timed input. Small differences in jumping can put the player on a different platform and change the camera. Inspect the video, exclude mismatched positions, and prefer a reproducible in-game suspend seed. `C3_A` was floor-level while `C3_B`/`C3_A2` were platform-level.
- GPU restore can launch a renderer worker. Standalone paired tests must consume that completion before starting another render. Otherwise the next completion can belong to the restore rather than the measured draw.
- Native raster buffers contain inactive backing pixels: when no top edge refers to a lower pixel, or antialiasing is disabled, those stale bytes are not displayed. Comparison masks only such lower storage, never top color/depth/attributes or live AA data. Complete framebuffer/RAM/audio/save replays remain required.

- The first newly created suspend (`SEEDBAT`) was still in the save room, because exiting requires jumping over the left stair. The resulting ~47 updates/s runs are excluded. `SEEDCAVE` was visually confirmed in the actual bat cave and repeated from the same resume position.
- Texture stress testing exposed an existing dirty-bitset wrap bug: the array index mask counted blocks, not 64-bit words, allowing an out-of-bounds read for wrapped texture ranges. The candidate corrects the word mask; independent wrap tests and 6,000-frame screen/RAM/audio/save replay comparisons pass.
- The guarded opaque-order candidates passed correctness checks but increased target CPU time. They are not included. Lighting-result reuse passed exactness checks but its approximately 0.36% nominal native gain was below the observed scatter; it is also removed.

- `PUBF1` is excluded: an early pause press occurred while the suspend was still loading, and the benchmark subsequently counted the pause menu. The harness now proves the pause screen before measuring. A fixed eight-second OBS sample can precede active play; capture validation now uses the recorded measurement interval.

- `PUBK1` is excluded from the Mario Kart speed comparison: the first interval was still at cup selection, and the second crossed the countdown. The qualified regression route adds spaced confirmation presses and checks actual racing captures.

- FFTA2's retained rc12/Beta2 runtime does not expose the ARM9 diagnostic PC tag
  in the inspected header. Existing sampler source alone does not mean the
  loaded bitstream supports collection. No RTL modification is authorized by
  the current guest-patch workflow; mark missing native metrics unavailable.
- FFTA2's branch-heavy copy candidate is rejected and disabled. Its 1,276
  synthetic passes did not survive full replay: 16 top-screen frames, audio
  and non-code RAM differ. The 1.565% instruction reduction in the selected
  window is not a qualified performance result. No native trial was run.
  Callers include toon-table MMIO, VRAM and palette destinations. The cause
  of whole-game divergence is unresolved; do not mask it as harmless timing.
- FFTA2's cartridge polling loop transfers required data. Do not treat it as
  pure idle work. Its nibble decoder feeds live PCM rings through intervening
  copies; it cannot be removed as dead work. Source-content recurrence and
  predictor-state identity remain unproven for any caching proposal.
- FFTA2's vertex shift compaction fails the current bit-exact gate. Luso's
  4,400 screen pairs match, but Fire has one changed bottom frame and library
  has two. Library audio changes 233,754 stereo samples, with maximum signed-16
  delta 3,203: the initial Luso maximum of 77 is not a global bound. Two RAM
  words are live elapsed-time fields; other differences include existing
  thread stacks and resumable ARM7 context. Do not normalize these away or
  call the audio harmless. The user authorized timing investigation only;
  the patch remains disabled with no native performance measurement.
  Library tracing matches 3,286,148 completed block payloads/end states and
  539,880 ordered sound-register writes, but 755 sound writes cross a different
  mix-callback boundary. V5 subsequently matches all 46,439,652 actual FIFO
  words and 371,300,720 paired decoder steps in library; 37 unmatched steps
  remain at 15 note ends with shifted start/stop boundaries. Channel outputs
  in two captured windows are explained exactly by observed sample/control
  timing. This does not qualify other scenes, native behavior or audibility.
- Full battle tracing disproves a whole-game timing-only assumption for the
  vertex candidate: Luso reads three different source words from the same
  addresses at the same sound callback. They change 1,182 decoded values.
  Neighboring words match two separate cartridge sequences across an apparent
  buffer overwrite frontier. V6 identifies the writer below; the high-level
  ownership policy remains unproven. Fire has exact source/decoded values and four control-timing output
  differences. Explaining the mixer arithmetic does not establish source-data
  equivalence or make Luso's buffer reuse safe. Keep the patch disabled.
- V6 identifies that writer as ARM9's cartridge receive instruction `02010180`,
  with no executing DMA. All 17,272 observed write payloads match, and every
  one of 9,959 sound fetches per arm agrees with preceding observed stores.
  Three stores cross from after the sound fetch to before it; channel 6 is
  still enabled at volume 3/128 and stops 480 callbacks later. This resolves
  the bounded overwrite-order mechanism in the software reference. It does
  not prove native interleaving, high-level ownership safety or acceptance.
- FFTA2's decoder-arithmetic candidate passes 4,885 synthetic equivalence cases
  but fails the Luso RAM/audio gate. All 4,400 screen pairs and save hashes
  match; 7,694 stereo samples differ, maximum signed-16 delta 427. Frame-2600
  main RAM matches outside code, but DTCM/ARM7 WRAM and transient RAM differ.
  The 2.512% selected-window instruction reduction is not native speed.
  Loading-time table guards, a write watch and observed entry indices cover
  the tested routes only. Native timing and lifecycle remain unqualified;
  the vertex candidate's explanation does not classify these new differences.
  Keep this patch disabled pending a complete, explicitly approved budget.
- The same decoder candidate fails Fire more substantially: 1,892 bottom
  frames and 132,737 stereo samples differ; maximum signed-16 delta is 65,535.
  All top-screen/save hashes match, and the selected instruction reduction
  is 2.4985%. Matching a prior frame explains some image hashes, not the
  whole failure. Four samples cross between opposite clipping limits. The
  follow-up matches every Fire source word and decoded sample; fourteen note
  starts shift and control writes move by up to 682 mixer callbacks. Actual
  samples/control timing explain every captured channel output. Upstream
  visual/event scheduling, native behavior and audibility remain unqualified.
  Do not transfer the vertex or Luso timing explanations, approve the patch,
  or run native qualification
  on the strength of the synthetic arithmetic proof alone.
- The decoder candidate's library/forest route is exact across 30,000 frames,
  including audio/RAM/save checks after only the declared code normalization.
  The selected instruction total is unchanged. This outside-target pass does
  not override either battle failure or establish full-game safety.
- Luso's decoder candidate changes three actual source words and 1,182 decoded
  values. A fresh writer trace confirms identical ARM9 cartridge stores occur
  15,605 raw timestamp ticks earlier and cross the active channel's read.
  This is observed producer/consumer interleaving, not purely sound-control
  timing. All observed writes and subsequent sound reads are internally
  consistent, but ownership safety and native behavior are unqualified.
  Keep this version rejected under the current budget.
- FFTA2's whole-block audio-decoder cache has no reuse in the full 4,400-frame
  Luso reference route: 12,456 distinct compressed inputs and complete
  predictor/count keys across 12,456 calls, despite only eight source
  addresses. The selected window also has zero hits. A cache would add
  matching/copy/storage work without a hit in this workload; do not allocate
  scratch or implement it on the strength of repeated buffer addresses.
  This is a route-specific negative result, not proof that all assets or
  smaller operations are unique throughout the game.
- FFTA2's rectangle predicate has substantial content reuse in a 120-frame
  library window, but one reused pointer pair supplies 171 inputs and both
  return values. Pointer-only caching is demonstrably unsafe. A last-result
  cache has no hits; most reuse is 180 calls later. A 256-entry table needs
  at least 5,120 payload bytes before metadata and any additional state.
  Scratch availability, lookup benefit, changing-view coverage, other callers
  and timing equivalence remain unproven. No cache is enabled or accepted.
- Moving-scene rectangle reuse does not make a cache automatically useful.
  Luso needs 512 hypothetical LRU entries to retain its 94.931% recurrence;
  Fire achieves 82.751% hits at that capacity. Payload alone is 10,240 bytes.
  The optimistic average lookup/maintenance allowance is about 19–22
  instruction entries per call before any gain, with memory cycles still
  unknown. A second caller passes a halfword-aligned rectangle, so word-load
  shortcuts need alignment handling. The third static caller remains
  unobserved, and storage and native timing are unqualified.
- The first concrete rectangle-cache lookup is rejected at cost preflight.
  Its hit costs 26 ARM entries / 60 data-access bytes versus the original's
  11–26 / 26–32. Actual direct-mapped hits are only 11.6–19.8% in the retained
  captures; an optimistic integration model adds 77.2–82.9% instruction
  entries to this predicate. Even perfect aligned hits do not improve any
  call's entry count. This is not a native slowdown measurement or an
  exhaustive rejection of all memoization. Do not allocate game scratch or
  install this component; volatile/flag integration and miss insertion are
  deliberately unimplemented.
