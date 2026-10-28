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
- Experimental review recordings run at deterministic replay game time.
  They do not demonstrate a native MiSTer speedup. Their H.264 picture is
  compressed; retain the original full-resolution hashes and lossless stills
  when discussing tiny color differences. MOV audio is checked sample for
  sample against the original stereo PCM. MP4 copies use AAC and cannot
  substitute for the original audio in an audibility assessment. Recording
  a failed candidate does not accept it, its combination with another patch,
  or its full-game/native behavior.
- Two native FFTA2 guest-patch screening series each contain one candidate
  session per patch and two short Luso windows. Vertex's first approximately
  3.4% publication gain was not reproduced: the second session is +1.328%
  idle and +0.167% movement/menu, with movement between adjacent controls.
  Decoder repeats at +0.463% idle/+1.036% movement, with idle between adjacent
  controls and movement within the broader control range. Neither patch has
  a qualified gameplay-speed claim. The subsequent Fire series is recorded
  below; preserve all results.
  Native staged-cartridge readback does not directly verify live ARM9 RAM
  or instruction-cache contents. Consumed-save equality does not qualify
  new save/write/reload, reset, ROM switch or combined-patch behavior.
  Existing RAM/audio and bounded framebuffer differences remain recorded;
  both experimental candidates remain disabled in release defaults.
- The first native Fire series gives vertex +1.621% publication throughput
  in the spell/menu window but -0.139% idle and -0.515% movement/menu. Decoder
  changes -0.578%, -0.075% and -0.158%, respectively. One vertex spell result
  is not a dependable speed claim; the one focused repeat and closure are
  recorded below. Decoder has
  no current benefit case for promotion or combined-patch testing.
  Actual Fire damage differs even among unpatched controls (27,23,31) with
  the same visible target and preview. Setup timing is not locked from boot,
  so native RNG equality is unqualified. Preserve actual outcomes rather
  than assigning patch causality or benignness from screenshots alone.
- Decoder Pina idle in the native Fire series fails the silence gate:
  70 ms of consecutive 10-ms windows below -80 dB, with 73.333 ms of exact
  stereo zeros about 13.678 s into the measurement. Audio timestamps remain
  continuous; fourteen other captures pass the signal check. Source audio,
  capture-path and patch causality are unresolved. Preserve the recording and
  `FFTA2_GUEST1_FIRE_WHITE_IDLE_D1_GAME_AUDIO_DETAIL.json`. A failed audio gate
  must remain explicit even when descriptive throughput is available and the
  file-preservation audit passes. The user's earlier software-clip review
  does not qualify this newly observed native interval.
- The predeclared vertex-only Fire repeat does not reproduce a benefit beyond
  surrounding controls. Fire is +0.349% against their mean but lies between
  the two controls; movement is -0.337% and idle +0.208%, barely above the
  higher idle control. Close this version without another unchanged repeat,
  combined-patch test or release promotion. Preserve the first +1.621% Fire
  observation and the earlier variable Luso results.
- Unpatched-guest control C5 movement in that repeat also fails the silence
  gate: 80 ms below -80 dB, including 60 ms of exact stereo zeros about
  8.951 s into the measurement, with continuous timestamps. This is a separate
  retained observation from the decoder interval. Both use the experimental
  host and capture path; their causes and relationship remain unresolved.
  Do not attribute either interruption solely to the guest patch, infer a
  common cause, or treat a file-preservation pass as an audio behavior pass.
- FFTA2 already caches partial cartridge blocks. Its 2,518 physical reads in
  the selected Luso window correspond to 1,109 asynchronous archive requests;
  two requests are served entirely from that cache. Only 12 request keys
  repeat, totaling 18,656 bytes in five complete asset ranges. A new block
  cache must not count existing cache hits or alignment spill as fresh gains.
  The shared archive context and low-level LR do not identify a logical file.
  All request/callback observations are unpatched: they do not prove that
  faster completion preserves live audio reads, IRQ ordering or asset lifetime.
  No new scratch, cache, guest patch or native gain is established by this
  result. Candidate archive names come from the retained hash/collision map;
  full asset ownership and processing callers still need dynamic evidence.
- FFTA2 was parked by explicit user direction after diminishing returns;
  unfinished asset-lifetime, viewport-hoisting and ARM7 math leads are not
  evidence of a failed completion gate or permission to resume that game.
  Platinum is now active, with prior player/furniture fixes preserved.
- Platinum CPUE revision 1 has 122 ARM9 overlays. Initial main/autoload ARM
  pattern matches are unprofiled and exclude Thumb/overlay coverage. Do not
  transplant FFT's rejected halfword-copy rewrite or reuse an overlay RAM
  address without exact overlay identity and a verified reload mechanism.
- Platinum's initial movement enters the rival dialogue; inputs issued while
  it is open do not qualify free walking or menus. The repeated 6,000-frame
  route later reaches menus and bedroom movement, but stair attempts remain
  inside the bedroom. Transitions, battle, save-write/reload and native
  pacing are still unqualified. Exact reference repetition is only a baseline.
- The owned filename labelled Platinum Europe reports CPUE revision 10 in
  its header. Do not identify/admit it by filename or infer retail provenance.
  The preserved original save backup is entirely `ff`, not a gameplay seed.
- Platinum's sampled fixed-destination word stream is not ordinary memcpy;
  actual destination and callers remain unobserved. Its large IRQ and
  DIV/SQRT context-preservation sample shares do not establish idle work or
  avoidable software arithmetic. Preserve full ARM7/overlay threshold lists,
  not only the easier-to-disassemble ARM9 ranges.
- Platinum's guarded census resolves those destinations: geometry FIFO for
  the word stream and almost exclusively OAM for halfword copies. Preserve
  the 19,800 zero-length calls as no-access cases and the one word-stream call
  that crosses a frame boundary. The 2/6-byte OAM fields include 2-mod-4
  addresses. Argument equality is not command/pixel-data recurrence, and a
  theoretical branch-entry reduction is not a tested or native speed gain.
- Platinum's word-stream predication candidate is rejected and disabled.
  Although 1,680 synthetic cases and all 6,000 screen pairs pass, 175,017
  stereo samples differ (maximum signed-16 delta 2,146). Five fixed RAM
  checkpoint sets and save data match, while 247 main-RAM, 348 DTCM and 107
  ARM7-WRAM per-frame hashes differ. No timing-only or audibility judgment is
  established. Its 1.267% reference instruction reduction is not native speed;
  no native trial or unchanged repeat is warranted under the current budget.
- Platinum overlay 5 is identified by its entire decoded body at five
  checkpoints, and guarded Thumb captures confirm empty resource queues and
  dummy HBlank callbacks in frames 4200–4319. This does not prove that every
  scene has an empty queue, that no IRQ mutates it, or that callbacks remain
  dummy. Preserve inactive record payload bytes and callback registration.
  Neither proposed optimization is qualified for native use.
- Generic `guest_byte_patch` now admits guarded, same-size uncompressed ARM9
  overlay-file diagnostics through the existing virtual stream. Compressed or
  flagged overlays remain rejected. Shared reader `prepare.read_overlay`
  honors the compression flag; the old unconditional autodetection failed on
  uncompressed Platinum overlay 62. The unchanged overlay-5 control matches
  the entire original cartridge and all 100 baseline replay files, but proves
  no changed-code fetch/cache visibility or actual reload safety. No overlay
  optimization is enabled. Never use an address-only patch or assume scratch.
- Platinum ARM7 samples include substantial sound arithmetic, dirty-flag
  processing and reference FreeBIOS SWI dispatch/completion. The embedded
  BIOS bytes are matched to the oracle; this is not a native BIOS identity
  check or proof of the actual SWI argument mix. Already-dirty-checked sound
  writes and required channel-status reads must not be removed as dead work.
- Platinum's unchanged overlay control now also matches all 166 files on a
  12,000-frame soft-reset/Continue route. The body is replaced during title/menu
  and restored before 1,800 guarded queue entries. Optimized bytes, native cache
  behavior, room transitions, battle and save-write/reload remain unqualified.
  Full-body-aware comparison now handles original/replacement and absent or
  replaced bodies; the new unpatched frontend matches all 100/166 golden files.
  Never blindly mask an address or treat an unmatched body as a recognized load.
- Platinum's empty-tail compaction candidate is rejected and disabled. It
  preserves 6,000 screen pairs, five fixed RAM checkpoint sets and save data,
  but changes 1,660 stereo samples (maximum signed-16 delta 312). Transient
  main-RAM/DTCM/ARM7-WRAM frame hashes also differ. The 4.679939% executed
  reference instruction reduction is not native speed or permission to accept
  audio changes. Do not transfer FFT's perceptual approval. The 1,338 synthetic
  cases and 2,700 unpatched paired calls support only the declared ordinary-
  memory contract; wider scenes, native timing and optimized reload are untested.
  The first unpatched observer run rejected a byte-reversed return opcode;
  corrected V2 guards pass, and the failed attempt remains in evidence.
- Platinum's HBlank `used` flag is not an atomic empty-callback predicate:
  registration and deletion update it in a different order from the callback
  pointer. Caller-side IRQ exclusion has not been established. The original
  dummy call also changes LR. Naive skips are unqualified; a whole-empty fast
  path needs a proven layout and callback/lifecycle contract. Static instruction
  counts cannot establish native cycle benefit or exhaust all alternatives.
- Platinum now has a reproducible software route downstairs and into Twinleaf
  Town: 16,800 screen pairs, audio/save and per-frame game RAM hashes match,
  with 235 identical full files. The repeat intentionally changes only the
  profiling window; counter/PC-file differences are audited, not game-state
  allowances. Town idle does not qualify outdoor combat, save writes, optimized
  overlay transitions or native performance. Never confuse removing empty
  IRQ-table scan iterations with suppressing selected IRQ handlers.
- Platinum's mask census selects bit 21 in 57,600 of 57,840 calls; an empty-tail
  exit offers almost no benefit. The same-size set-bit rewrite passes 12,262
  synchronous synthetic cases and 57,840 guarded candidate table contracts,
  but changes one screen frame, all 11 fixed main-RAM/DTCM/ARM7-WRAM checkpoint
  sets and 6,591,626 stereo samples. It is rejected and disabled despite a
  2.178710% reference-entry reduction. Do not infer harmless timing, mask heap
  differences, transfer FFT approval, rerun unchanged or trial it natively.
- The generic mask detector also flags an unsampled ARM7 variant. ARM9 CLZ
  bytes cannot be used on ARM7. Verify CPU instruction support and multiply
  operand restrictions independently of a newer-architecture emulator's
  synthetic result; no SDK identity or cross-game patch is established.
- Platinum pitch inputs repeat substantially, but recurrence is not a cache
  contract. A 16-entry hypothetical LRU covers 55,815 of 57,827 calls; a single
  global last-result slot only 1,233. No safe guest storage, voice lifetime,
  full CPU-effect proof, native gain or ARM7 patch delivery is established.
  Do not use a normalized BIOS lookup index as the whole pitch-function key.
- Zero pitch returns the base timer in 13,874 observed calls, but this does not
  authorize skipping the helper: the observed base range excludes its lower
  clamp, and register/flag/BIOS effects remain proof obligations. Zero pitch and
  zero normalized index differ when an octave offset is present. Stateful sound
  envelopes and existing dirty-write checks must remain intact.
- Platinum's one-byte ARM7 carry-predicated MLA candidate passes 6,800 local
  cases and observes a zero multiplicand in all 57,827 captured calls. It is
  still disabled: the current loader rejects ARM7 autoload targets, and no
  full patched replay, lifecycle or native timing result exists. Nine entries
  remain nine entries; avoided multiply work is not a measured speed gain.
  A synchronous proof cannot rule out changed interrupt/audio timing. Preserve
  the BIOS call and its effects; do not silently substitute the larger variant.
- For carry-derived arithmetic screening, verify the instruction's encoded S
  bit. This Capstone build reports ADC as updating flags even with S=0. Reject
  S=1 and clobbered carry/register context; disassembly text alone is insufficient.
- ARM7 autoload delivery now has an explicit virtual-stream path for a narrow,
  pinned uncompressed WRAM layout. This is preparation of cartridge bytes,
  not a runtime hook or proof of cache visibility. The ARM7 boot prefix and
  copy table are preserved. Do not assume the existing ARM9 main/overlay RAM
  comparison can normalize ARM7 WRAM or an overwritten staging buffer.
- Explicit ARM7/main staging comparison is now qualified by 241-file town and
  83-file boot controls. Only exact code context is normalized; partial loads
  and reused staging remain raw. The one-byte candidate itself is rejected:
  all 16,800 screen pairs and save hashes match, but 73,833 stereo samples and
  main-RAM/DTCM checkpoint 14300 differ. Native benefit and audibility are
  unmeasured. Do not rerun unchanged, trial natively, combine or transfer FFT's
  perceptual approval. Broader active gameplay profiling remains unfinished.
- The replay oracle's formatted input reader silently stops at comments or
  malformed tokens. Platinum outdoor probe V1 therefore never submitted its
  appended movement. It is excluded from active-gameplay evidence, rather than
  interpreted as a collision. Preflight the complete file with
  `validate_replay_inputs.py`, pin its hash, and independently inspect actual
  motion before profiling. A successful process exit is insufficient.
- The oracle emits `save.bin` even if the frame limit interrupts an in-game
  save operation. Platinum's first story-save probe still changed save hashes
  through frame 19598 of 19600 and showed "Saving" in its last capture. Its
  output is excluded as a new seed. Extend the same input route, confirm save
  completion and a stable tail, then cold-load and repeat before admission.
