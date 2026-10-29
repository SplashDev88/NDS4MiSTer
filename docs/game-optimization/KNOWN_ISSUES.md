# Optimization investigation limits

- HeartGold IPKE r0 uses compressed ARM9 code and 127 compressed overlays.
  Explicit overlay-only append delivery now reuses FMV relocation and leaves
  both stored CPU images untouched. It does not enable compressed main-code or
  ARM7 patching. The unchanged-code control shifts compression/load timing:
  its repeat matches 154 files, but it differs from the original in 4,550 top/
  22 bottom frames and 6,911,734 stereo samples. Keep raw evidence; do not call
  this control bit-exact or assume its audio is imperceptibly different.
- HeartGold's disabled terrain candidate skips 728 of 1,158 eligible draws and
  uses 4.356% fewer reference ARM9 instruction entries. It completes the bounded
  route with an exact save buffer, but 4,315 top/8 bottom frames and 6,053,116
  stereo samples differ. Still pairs retain expected scenes and movement;
  full-motion/listening, native gain and lifecycle remain pending. The user's
  functional budget permits continued investigation, not an invented native
  speed result or automatic promotion.
- A fixed trace window can begin halfway through a function. The decoded
  HeartGold control has one leading prop-test return without a captured entry;
  retain and exclude that partial call from paired counts. Do not force counts
  to match a timing-shifted candidate. Earlier writes to an overlay's future
  addresses also do not establish mutation of that overlay's live constants.
- The hot HeartGold DIV/SQRT routines preserve arithmetic hardware context
  across scheduling; they are not cache maintenance or dead work. ARM7 code
  below 03800000 in this replay is backed by shared WRAM, not ARM7 private WRAM.
  A diagnostic using the wrong backing array is excluded and corrected.
- HeartGold's owned save was entirely `ff`; early button-only input routes
  stayed in introductory help screens. Neither the save filename nor valid
  input syntax establishes gameplay coverage. Optional touch replay reuses
  the same oracle; its disabled path must preserve every baseline output.

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
  2.178710% reference-entry reduction under the historical exact-only gate.
  The later functional-budget trial completes the inspected first battle and
  native walking/menu sequence, but finds no useful native gain. Keep disabled
  for that reason; retain raw heap/audio differences and do not infer inaudibility.
  One new battle call has IRQs enabled, unlike the earlier all-masked town census.
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
  unmeasured. The later functional budget supersedes this exact-only rejection.
  The shipped-core cost screen now parks the candidate for insufficient expected
  benefit: three local beats per observed call, about 5.18ms across 1,800 frames.
  This is not a measured native speedup or an all-game bound. Reopen only with
  a substantially higher representative call rate or an ARM7 pacing bottleneck.
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
- Platinum's early private contact sheets decoded legacy `.rgba` snapshots as
  RGBA, although the renderer writes BGRA8888. This swaps red and blue only in
  those previews. New battle review sheets use the existing BGRA convention;
  the original raw captures, hashes and exact replay comparisons are unchanged.
  The close-up shows the rival trainer at frame 18000 and Chimchar at 19000
  and 19500; the suspected retained-trainer sprite is not supported. Do not
  change the renderer or texture cache on that preview evidence.
- The old private FFT native-session wrapper requires a 65,536-byte save and
  FFT evidence ownership. Platinum uses 524,288 bytes. Reuse the existing rig
  with a properly isolated Platinum configuration and fresh ownership checks;
  do not launch the FFT wrapper unchanged. Native PC collection also requires
  a diagnostic bitstream tag, whose presence in exact rc12 is unqualified.
- Platinum's font generator uses a different stack from the idle task seen at
  video-frame checkpoints. A first observer incorrectly requested main-RAM
  stack bytes and aborted on the mapping guard; that run is excluded. The
  corrected census observes 8,900 entry SPs in `027e3510–027e3700` and records
  registers plus the main-RAM table, without claiming dynamic stack captures.
- An already-correct font table does not authorize a bare early return. The
  original generator leaves specific volatile registers/flags and 72 bytes of
  stack effects. Reproduce those under the strict gate; do not normalize them
  away. The three stored colors predict the correct table in this bounded
  replay, but input-domain truncation, asynchronous readers, reset/lifetime,
  code capacity and native benefit remain unqualified for a replacement.
- The implemented 164-byte Platinum font-table reuse patch passes 8,672
  synthetic cases and the observed battle-call contract, but changes five
  upper-screen frames and 61,453 stereo samples in the 23,400-frame replay.
  Six fixed RAM checkpoint sets and saves remain exact. Its 2.264% reduction
  in ARM9 reference entries does not justify acceptance or a native trial.
  Keep it disabled; do not mask transient RAM, normalize audio, repeat the
  unchanged version, or borrow FFT's perceptual budget. Native cache/lifecycle
  safety and native performance remain unqualified.
- The user's 28 October perceptual-trial request supersedes historical
  no-native-trial restrictions for the three explicitly screened Platinum
  candidates only. It does not accept their mismatches. Their isolated native
  walking/menu/Bag trials show no worthwhile gain; all remain disabled. Native
  battle benefit, cache readback and broader lifecycle behavior remain open.
- Platinum's first short walking control/candidate pair ended on different
  vertical tiles. The apparent publication-rate increase is excluded. Later
  boundary-anchored trials remove that route mismatch and show no improvement.
  Count source-frame IDs separately from screen publications and avoid calling
  either unique animation FPS. Native RTC/setup durations still vary.
- OBS's first audio stream in these native recordings is silent; the second
  contains game audio. Native review remuxes must select the audible stream.
  Early remuxes retained packet bytes but rounded video timestamps by less than
  half a microsecond; the V2 copies preserve and verify exact rational packet
  PTS/DTS/duration. Original OBS recordings were never altered.
- A protected-file snapshot accidentally included the trial's own disposable
  save after staging recovery. Reseeding then correctly failed the C2 preflight
  before launch. V2 excludes only that owned save; V3 refreshes inode metadata
  already backed by full content-hash verification. Retain the failure receipt.
- Identical normalized geometry payloads do not establish that the framebuffer
  can be reused. VRAM/palette contents, external state and readbacks may differ.
  Platinum has 102 adjacent repeated intervals in its qualified outdoor trace,
  but no draw or frame is skipped on that evidence. Most observed traffic is
  DMA; the interrupted CPU PC must not be called the DMA producer.
- Identical material or polygon parameter values can still have other effects.
  For example, material assignments may update current vertex color. Preserve
  those effects before treating a repeated assignment as unnecessary work.
- A Thumb instruction-entry sample at an address divisible by four can retain
  the next halfword in the upper 16 bits of `CurInstr`. The memory-watch loader
  accepts a 16-bit expected Thumb opcode but currently compares the full sampled
  word. Platinum's box-test entry guard therefore stopped before producing a
  usable census. Observe a verified adjacent site with intact arguments or
  separately qualify an instruction-decoding fix; never weaken identity checks
  or use the failed run as behavioral evidence.
- Platinum's box-test getter returns raw GXSTAT bit 1: zero or **two**, not a
  normalized zero/one boolean. Preserve raw outputs. One model pointer is used
  by multiple instances with opposite visibility outcomes; pointer-only caching
  and reused stack addresses cannot establish equivalent query inputs.

- Promotion update,2026-10-28: the user approved the terrain video/audio and
  explicitly requested promotion. The exact48-byte CPUE revision1 terrain patch
  is enabled for private Platinum Beta1; historical disabled/pending statements
  below describe earlier gates. Six outdoor screen differences and RAM/audio
  differences remain real. Complete RAM-reader liveness and full-game coverage
  remain unqualified; do not relabel this as bit-exact or transfer its approval
  to another candidate. Native ordinary Save/reset/cold-load/room transitions
  and unpatched save compatibility passed in bounded Twinleaf coverage.
- The initially disabled Platinum terrain visibility experiment skips 610 of 1,200 terrain
  draws, but introduces 1,200 synchronous box tests and fails exact RAM/audio
  comparison. Six top-screen frames before the measured walking route also
  differ. Direct constant pointers replace stack copies; no dynamic RAM region
  is excluded from comparison. Do not equate draw-count reduction with native
  speed, assume all differences are benign, or enable before review/measurement.

- Platinum terrain visibility has a repeated native publication-throughput gain
  (+13.162%) and was initially held disabled: six banner/transition frames, checkpoint RAM
  and audio differ. The largest audio differences occur earlier than the outdoor
  target window; the expanded V2 review includes them. Human review, RAM-effect
  classification and wider lifecycle tests remain separate from this speed result.
- Platinum terrain checkpoint words `021cd008/021cd00c` are live graphics
  transfer cursor/remaining-length fields, not timing counters. Observed transfer
  bookkeeping completes consistently in both runs, but this does not authorize
  excluding those fields or all DTCM differences. CPU snapshots include different
  live graphics/IRQ execution points; stack liveness remains open. The private V6
  runner's legacy checkpoint-RAM summary field covers only its early mainram.bin;
  use the explicit checkpoint comparison and overall rejection status instead.

- Platinum's accepted terrain beta changes a fixed-input first-battle trajectory.
  The user permits timing/RNG differences provided the game functions. Preserve
  exact mismatch evidence without blocking work on RNG equality; continue to
  check gameplay, progression, saves and audiovisual defects. The diagnostic
  watch at0223f4cc aborted on an instruction/mode mismatch in a reused overlay
  address. It did not validate RNG steps and is not evidence of a game crash.
- The new disabled OAM inline loop assumes normal manager indices0/1 and ranges
  within128 sprite slots. Synthetic complete-function tests preserve all ordered
  OAM accesses and the separate affine halfwords. They do not prove interrupt,
  DMA or native behavior. Repeated source bytes alone cannot justify dirty skips.
- Native battle control `PLATINUM_BC1_COMBAT` section 1 was intended to execute
  an attack, but the ending screenshot shows Tackle selected at 35/35 PP with
  both combatants undamaged. Retain it as move-selection coverage; it cannot
  establish attack timing. `PLATINUM_BC1_TACKLE` starts from that verified menu
  and records an actual Leer/Tackle turn. Its near-60 publication rate remains
  a buffer-throughput measurement, not unique gameplay FPS.

- Current font battle update: the user's functional budget permits the later
  terrain-plus-font screen despite its strict replay mismatch. Full-route key
  coherence passes, but native menu/turn publications and identical-message
  timing show no useful gain. Font remains disabled. The earlier statements
  that native battle was unmeasured describe historical coverage only.
- The font candidate's first Tackle misses while the prior control hits; whole
  turn lengths cannot be compared. Native HP/background also differ with
  uncontrolled RTC/setup timing. Their cause is not isolated. Identical-message
  PTS timing is only one observation per arm, with no claimed regression or
  full-game equivalence. Candidate victory/save-write/reset remain unqualified.

- Platinum's accepted-terrain visibility trace disproves a model/transform-only
  cache:519 repeated-input observations have different results when camera data
  is omitted. Captured full-submission keys have no conflicts, but this does not
  prove external GPU-state completeness or removable side effects.
- Visibility reuse is a proposal only. No scratch/code storage or lifetime is
  qualified. A 16-entry simulation covers 57.0% overall but 15.97% of held-button
  calls; the larger all-history repeat count is not a small-cache speed claim.

- Platinum cartridge census covers ARM9's CPU-driven worker, not the separate
  DMA path or total cartridge traffic. Existing partial-block buffer hits are
  excluded. Repeated source offsets do not establish actual payload equality,
  safe scratch, completion behavior or native cache benefit.
- Overlays 12 and 14 both occupy 0221fc20; repeated loads cannot be blindly skipped.
- The original resident-font proposal has now been tested and rejected below. Its loader does
  not check Heap_Alloc for failure before reading. Each font needs 32,576 bytes;
  live allocation success/headroom, freeing and all relevant scenes must be
  validated before acceptance. No font-residency patch is enabled.

- All-font residency faults during field setup at frame 1318 despite successful
  startup buffers. Heap 8 has a null handle; ARM9 remains in abort mode. Reject
  this variant under the functional budget. Battle-time free-space snapshots
  missed this earlier demand. A smaller policy requires independent validation.

- Two-font residency completes the first-battle reference but leaves only 3,892
  application-heap bytes free at field checkpoints. It is disabled in favor of
  investigating message-only residency. Different HP/turns make the apparent
  5.327% battle instruction reduction unsuitable as a native/equal-work claim.

- Message-only residency completes the bounded battle reference with 36,500
  sampled free application-heap bytes and exact cached payloads. It remains
  disabled: native benefit, listening/video review, save-write/reset, font free
  lifecycle and broader heap demands are not qualified. Its earlier battle end
  and higher fixed-window instruction count both mix different workloads.

- Message-font residency is now parked after its native screen: roughly 50ms
  less elapsed time on a two-second dialogue line, with no publication-throughput
  improvement in sign/dialogue sequences. Single cold pair, two line repetitions;
  no general slowdown or full-game safety claim. Its 32,608-byte extra heap cost
  and unqualified lifecycle outweigh this bounded gain. It remains disabled.

- Raw ARMv5 Thumb prefetch can contain a second instruction in the upper half.
  The memory observer now uses the executing halfword and retains exact mode
  checks. Earlier archive census guard aborts were instrumentation failures,
  not demonstrated game failures; exclusion receipts are retained.
- Platinum archive layouts have useful constants, but fixed-layout metadata
  precomputation is now tested in the path reader but not enabled. Item records
  are uniform-sized with padding; do not infer their stride from size.
  File-position/completion effects and already cached reads must be accounted
  for before a patch is admitted.


- Platinum's size-only archive skip passes the bounded return contract and
  reference progression screen, but is parked after a native screen. Four Bag
  cycles per arm give the same 1.7583s mean combined near-black time and almost
  identical publication rates. Timing, stack and battle trajectory mismatches
  are retained; the earlier battle end is not a speedup. Native routine workload,
  listening and broad lifecycle remain unqualified. Do not repeat this exact
  screen expecting a new result.
- Replacing a graphics size/allocate/read sequence with the existing combined
  archive allocator would remove the caller's null-allocation guard: that helper
  reads into the result without checking it. This shortcut was not implemented.
- All 215 owned NARCs share 16-byte headers and 16-byte BTNF chunks. This is a
  guarded-revision fact, not a universal format guarantee. The path-reader
  candidate uses these constants and is parked after insufficient native gain.

- The archive reader explicitly supports reads spanning multiple members: one
  observed call reads 7,488 bytes from the first 16-byte move record. Preserve
  explicit lengths rather than adding a member-bound clamp.
- Fixed reader metadata passes synthetic payload and full reference progression
  screens, with fewer associated cartridge transfers. Different later battle
  trajectories prevent interpreting whole-route totals as speedup. Live payload
  bytes, audio listening and broad lifecycle remain unqualified. Its native
  first-battle transition improves only 50ms (16.1333s to 16.0833s) in one cold
  pair, with no publication improvement. Keep it disabled; do not repeat this
  same screen unchanged or infer a whole-game speedup.
- The battle queue early-exit trial changes caller-clobbered R2 from the full
  unsigned sum to the first nonzero byte. Five owned callers use Boolean R0;
  the other return registers, flags, stack and writes match focused cases.
  Do not generalize this to signed/overflowing sums or callers that consume
  the sum. The queue timeout reset must remain on the empty path.
- This trial completes the bounded first-battle reference with one top-frame
  difference and 293,543 differing stereo samples; bottom frames and save
  match. The current functional budget permits continuing investigation, but
  these data do not establish inaudibility or whole-game safety. The completed
  native first-turn screen shows no worthwhile gain: publication throughput is
  flat and identical text takes 1.2333s versus 1.2500s with overlapping bounds.
  Keep disabled; do not repeat that screen without new workload evidence.
  Native victory, listening and broader lifecycle remain unqualified.

## HeartGold native terrain screen

- Identical timed walking input diverges spatially between original and
  unchanged-code delivery controls. Use the matched plaza save/standing screen
  for the3.1–3.5% native publication-throughput result; do not claim the larger
  moving-window difference as equal-work speedup or whole-game FPS.
- Transient diagonal white lines occur in unpatched native footage as well as
  control/candidate footage. They are an existing observed rendering artifact,
  not evidence by themselves that this terrain patch introduced a defect.
- Native Save/reset/cold load, house and Bag checks plus the separate indoor
  replay are bounded. Starter/battle, long-game progression and human
  full-motion/listening review remain open. Direct native guest RAM/cache
  tracing was not added; staged cartridge bytes and normal load behavior are
  the available native delivery evidence.
- A single-manifest replacement would drop accepted Platinum terrain selection.
  HeartGold Beta1 resolves this through the existing loader's explicitly pinned
  embedded catalog. Both complete game images match their previously qualified
  hashes, as do retained Portrait/Ni no Kuni/NSMB images; both game selections
  cold-load on the actual installed launcher. Keep these cumulative regression
  checks when adding future games. Starter/battle and long-game HeartGold
  coverage remain open; no new human audiovisual approval is inferred.
