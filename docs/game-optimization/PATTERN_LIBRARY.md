# Runtime optimization patterns

Reuse `tools/standalone_host/fmv/hook_guard.py`, `prepare.VirtualRom`, the existing native ARM9 PC sampler and graphics-replay tests. These entries are evidence and admission rules, not permission to patch another title automatically.

## Establish code delivery and real input coverage before transferring a pattern

Decode the owned CPU images and overlay table before choosing a patch target.
A structural match in decoded code does not make its stored bytes directly
patchable. HeartGold IPKE r0 has compressed ARM9 code and 127 compressed
overlays out of 129. The default same-layout adapter rejects that main image.
The explicit `append-decoded-overlays-v1` mode now reuses FMV relocation for
overlay-only selections while preserving both stored CPU images. Require exact
stored/decoded identities, layout guards and unchanged-code delivery qualification
first. An identical-byte patch can still change compression/load timing. Never transfer
Platinum offsets or assume its native gain from a matching instruction shape.

HeartGold's unchanged main/autoload scanner finds ten static leads: three
nibble-arithmetic sequences, two mask walks, one halfword copy, three header
reads and a zero multiply. No execution frequency, SDK identity or safe
replacement follows from those matches. Overlay screening remains separate.

A valid button script can remain in help screens. Review the actual scene,
and use the existing oracle's optional touch windows when the interface needs
them. Pin coordinate events, preserve exact button-only controls after any
harness change, and qualify a real saved checkpoint before collecting a
gameplay benchmark. An all-`ff` save file is not evidence of prior progression.

The qualified HeartGold idle-room control later attributes 4.469% of ARM9
samples to the halfword-copy span and 6.151% to an incrementing-source,
fixed-destination word stream. Their original decoded bytes match loaded RAM.
These are useful runtime leads, not native cycle shares or proof that the
destination is graphics FIFO. Capture arguments, lengths and content during
movement before selecting an optimization. The initial IRQ-dispatch prefix
reads and acknowledges real interrupt state; high sample weight does not make
it dead work.

The later moving HeartGold census authenticates 147,600 tiny OAM copies and
120,380 fixed-destination stream calls, including 10,242 empty calls. Nonempty
streams target geometry FIFO; DTCM sources are common. A code-context snapshot
can authenticate leaf entries/returns without assuming every stack is in one
RAM mapping. Keep register/counter/opcode/pairing guards and explicitly state
that stack/payload bytes were not observed. The observer must preserve the
unchanged replay. High transfer weight does not prove removable traffic.

## Exact correspondence between replay and native trials

Carry the same guarded virtual cartridge into the existing disposable native
loader. Pin the manifest and compare the entire emitted image with the replay
image hash before measuring. Native opt-in patch IDs may select experimental
disabled candidates, but do not change release defaults. Keep control and
candidate on the same host/renderer/bitstream, and apply one patch at a time.
The worker terminates before guest execution; patching initial code under reset
needs no new HPS service. Do not extend this admission rule to runtime overlays,
autoload targets or live instruction caches. Perceptual review of selected
videos is useful evidence, separate from native speed and lifecycle coverage.

## Redundant graphics state within a primitive

Detector: repeated writes of the same value to a graphics register with only vertex/texture-coordinate submissions between them. Classify the complete dependency set first. Castlevania ACVE r0 writes NORMAL four times per background quad at `0x02004280`; its two static callers are `0x02003dfc` and `0x020041fc`.

Do not infer redundancy from equal command values alone. NORMAL also changes lighting and, in texture mode 2, texture coordinates. Matrices, materials, lights, active light masks and shininess are dependencies. Removing commands changes pipeline timing even when all pixels match. The three-NOP Castlevania trial passed 3,000 video frames but failed RAM/audio equivalence and was rejected.

Exact alternative tested and rejected for insufficient native gain: memoize the pure lighting calculation in the existing HPS interpreter while retaining each command, texture-coordinate side effect, pipeline update and cycle charge. Invalidate conservatively on every command outside the proven color/normal/texcoord/vertex whitelist, on reset and on GPU restore. This generalizes to games using the same graphics API without needing guest addresses.

## Repeated asset content is not unchanged content

Detector: decoded texture hashes that return to a small set of values. The cave backgrounds alternated between two actual palette results in a 25-input capture. A monotonic revision is safe for invalidation but cannot recognize a returning content state. A hash alone cannot authorize exact reuse: retain and compare the actual source bytes.

Reject unconditional palette-upload suppression. Precompute/cache only after matching all content and rendering dependencies. Include allocation, matching, copying, changing frames and dual-core synchronization in the cost model; repeated frozen frames alone are not an acceptance benchmark.

## Stateful decoder content recurrence

Repeated source addresses can be reused staging buffers, not repeated assets.
Capture the actual source bytes, sample/byte count and complete predictor,
dictionary or other carried state at entry. Capture every output byte and
updated state at exit, and verify invocation pairing and pointer advances.
Fixed tables and other dependencies require separate immutability evidence.

Reuse the instruction observer's declarative `NDS_REPLAY_MEMORY_WATCH` spans.
It requires CPU/mode/opcode/register guards and copies backing bytes without
emulated reads. Default main-RAM spans reject TCM and aliases; an explicit
ARM9 DTCM span validates the local mapping and uses its separate backing. A passed
unpatched golden replay is required before analysis. The generic
`analyze_memory_recurrence.py` compares complete byte tuples, checks repeated
keys for differing outputs, and reports reuse distances and bounded LRU hits.
It cannot establish cache safety, spare memory, timing equivalence or native gain.

FFTA2's Luso route has 12,456 decoder calls at eight source addresses, but
12,456 distinct 128-byte source blocks; adding the eight-byte predictor state
and sample count also yields no repeated keys. The selected battle window
has 7,696 calls and zero hits. A whole-block cache is not justified in this
workload even with unlimited capacity. Do not extrapolate address repetition
or a decoder's large sample share into a caching opportunity.

## Repeated spatial predicates with stack inputs

Structural lead: signed halfword loads from two small records, coordinate
subtractions, four axis-aligned boundary comparisons, conditional early returns,
and a boolean result consumed before graphics submission. Check signedness,
boundary equality, arithmetic width, all return paths and actual callers.
Such work can be necessary even when one viewport record stays constant.

Capture every relevant input byte, including caller-built stack values. A
shared stack address does not identify unchanged data. Instruction callbacks
occur before predication: evaluate CPSR before treating a conditional POP as
a return, and verify the saved entry registers and stack frame. Explicit
DTCM observation must use ARM9 local memory, not an ARM7/main-RAM alias.

FFTA2's bounded library capture has 21,600 calls, 171 complete 16-byte keys
and 99.208% recurrence with identical boolean results. One pointer pair has
both true and false results, ruling out pointer-only reuse. Median reuse
distance is 180 calls, so a last-result cache has no hits and a 128-entry LRU
has few; 256 entries retain all repeated keys in this window. A large hit rate
does not establish a win for a 15–26-entry predicate: account for matching,
indexing, storage and invalidation, and preserve clobbers and whole-game timing.
The first early-return path has 11 entries but was not taken in this capture.
No cache implementation, unused-memory proof or native improvement is implied.

Repeat the content census across moving scenes and view changes. In FFTA2,
Luso's moving window has 94.931% recurrence across 19 viewport translations;
Fire has 85.286% across 51. The complete input working set and miss cost matter:
a 256-entry LRU captures only 63.784% of Luso calls, versus 94.931% at 512.
The latter needs at least 10,240 key/boolean bytes before metadata. Derive a
weighted lookup budget from actual return paths, retaining unavoidable hit
work and charging every extra miss, preservation and invalidation operation.
Do not treat hypothetical associative-LRU hits as a free lookup algorithm.

Observe alignment per caller. One FFTA2 caller uses a rectangle pointer at
2 mod 4; a blind word-load substitution changes ARM9 semantics. Calls can
also straddle emulator frame boundaries. Pair complete invocations using
their stack and saved-register guards; a same-frame assumption can discard
valid evidence. These obligations precede any cache or native-speed claim.

Measure a concrete guest lookup before allocating storage. The reusable
`boolean_cache_lookup_armv5.S` is an isolated 512-slot, complete-16-byte-key
boolean lookup, not a game hook. `check_boolean_cache_lookup.py` reuses the
existing Unicorn runner for collision/validity/alignment checks and counts.
Its hit costs 26 entries and 60 data-access bytes; FFTA2's original predicate
takes 11–26 entries and 26–32 bytes. It therefore establishes no instruction
headroom even under perfect hits. Actual hashing has many collisions.

`estimate_boolean_cache_trace.py` replays real keys and the exact hash rather
than borrowing associative-LRU hit rates. Credit any genuinely reused
prologue and removed diagnostic tail explicitly. Treat free miss insertion,
state restoration or invalidation as optimistic omissions, never as an
implementation. This concrete design is rejected; no game memory is allocated
and no native gain follows from the synthetic test VM.

## Native waiting versus reference instruction counts

Reference instruction sampling identifies executed loops. Native PC sampling measures observed wall time, including halt/DMA periods. Neither is a cycle counter. For ACVE the first cave capture observed 37.2% halted samples; the native geometry stream already submitted about 60 frames/s while completed screen publications were about 21.3/s. Prioritize the limiting stage, not the largest reference loop by itself.

## Opaque draw order and hidden pixels

Detector: long runs of opaque, constant-depth, screen-aligned rectangles, interrupted by translucent effects or other ordering dependencies. A nearest-first order can let existing depth tests reject hidden shading, but can also turn a vectorized write into a slower scalar rejection. Measure on the target CPU.

An experimental conservative predicate requires unchanged color, rectangular corners, opaque supported texture formats, ordinary depth testing, and no fog/edge-marking/clear-image effects. Sort pointers, not large raster state objects; keep ties stable and preserve unsafe barriers. Test randomized depths, polygon IDs, equal-depth operations, AA state changes and the original scene replays. A four-pixel rejection is valid only when every source pixel is strictly farther and none has a live lower AA layer.

## Resident decoded variants

A returning palette state can reuse the already decoded texture in its original allocation. Record all source ranges at decode, including wrapped texture data, auxiliary compressed data and the palette. Compare the small palette first, then every relevant source byte. On a hit, restore the complete cache entry and its identity; on eviction, return storage through the original free list. Limit memory and preserve reset/remap semantics. This avoids decoding an image merely to discover that it matches a prior image.

## Sparse callback-table traversal is not idle polling

Detector: a bounded loop with a constant record stride, a nullable loaded function pointer and an indirect call, rather than a fixed MMIO address. In ACVE runtime RAM, `0x020126f4` and `0x020128e4` traverse 0x110 records with stride 0x2a0. The second loads `[r5]`, skips nulls and calls `blx r1`; the first also checks `[r5+4]` and flags at `[r5+0xc]`. These account for the two previously unresolved >2% native PC sample sites, but samples are not cycle shares.

An active-record index could reduce empty scans only if every registration, deletion and reordering operation is captured and callback order remains identical. Treat an object-update role as an inference until symbols or write watches establish it. Do not replace this with halt or skip callbacks. It is not the current throughput priority while geometry already runs near 60 submissions/sec.

## Linear key/handler dispatch

Detector: scan fixed eight-byte records, compare the first word to a requested
key, load the second word on a match, call it indirectly, and stop at the first
match or the signed count bound. `scan_guest_patterns.py` recognizes this ARM
structure with renamed registers and exact branch targets. Two positive and
13 negative structural checks cover changed offsets, predicates, loop bounds,
register aliases and writeback. Existing detector results are unchanged on
both CPU images of the initial title. This establishes no SDK identity.

Trace entry keys, table/count identity, incoming callers and successful match
positions. Watch all table writes, including boot, and verify retained bytes
at checkpoints before deriving work from static table contents. Report misses
separately: a failed subclass table search can legitimately fall through to a
different table. Do not remove a whole call or its fallback merely because
the first lookup misses. A range prefilter, compact search, or offline index
must preserve first-match precedence, signed count behavior, handler effects,
registers/flags, memory visibility and whole-game timing. Scratch requires a
full-replay write watch; no native HLE service is implied.

FFTA2's library window observes 73,667 searches and 40,182 misses across four
tables. The five statically identified tables have no duplicate keys and no
post-boot writes in the full 30,000-frame route. Observed hit positions match
the original search exactly. The resulting 5,384,388 key comparisons are a
calculation from inputs and table order, not cycles or measured savings.
No search patch has been qualified.

A minimal compaction can combine the key load and the eight-byte pointer
increment using postindex addressing, adjusting the matched handler load to
`[table,-4]`. Preserve the indirect call's original address: moving a `BLX`
changes the link register and can change callee stack data even if its final
return value matches. `check_dispatch_patch.py` reuses the existing Unicorn
runner with ARM/Thumb handlers, one of which saves its complete entry state.
It checks duplicate-key precedence, signed/empty counts, all initial NZCV
combinations, final CPU/data state and the ordered data accesses. Earlier
visibility of the updated table-pointer register during an interrupt is a
separate whole-replay obligation; synthetic passes do not settle timing.

The first postindex candidate passes 1,520 synthetic cases, reducing a
138-entry miss from 974 to 836 instructions with the same 142 accesses.
The full library replay uses 0.713% fewer selected ARM9 instructions, but one
bottom-screen frame, audio and RAM differ. It is rejected under the bit-exact
budget. Preserving handler entry state and access order does not establish
equivalent interrupt/audio scheduling or native performance.

When reusing an unpatched control, require an explicit opt-in and verify the
original virtual-ROM digest, game identity, oracle identity, replay inputs,
golden comparison and retained output hashes. Different disabled manifests
can describe the same original stream; a patched or changed control cannot
be substituted on that basis. `summarize_guest_pair.py` retains exact byte and
same-index comparisons without aligning differences away.

## Timer, interrupt and sound service loops

Constant-size scans can update live audio channels or schedule runnable
threads. Trace or disassemble their status-register reads, interrupt-mask
changes, callbacks and publication stores before proposing idle suppression.
Repeated reads of a sound-active bit are not evidence that its value is safe
to cache; a channel can finish asynchronously. Timer reads may compensate for
pending overflow interrupts. Preserve these dependencies even when a bounded
replay rarely takes the correction branch.

Use all profile windows above the threshold, not a truncated top-N list.
One window can straddle several functions. Reference sampling every 256
instruction entries can alias periodic code; its percentages are neither
native cycle shares nor shares of combined CPU work. Match observed opcodes
to the correct CPU's main/autoload map before naming a routine. Shared WRAM
and ARM7 private WRAM may form one virtual code extent; ARM9 DTCM and ARM7
main-RAM aliases at the same address do not designate the same storage.

## Branch-heavy halfword copy

Detector: an ARM loop compares a byte offset against a signed length, then uses
separate conditional/unconditional branch pairs around a halfword load, store
and offset increment. These branches all depend on the same comparison flags.
Flag the structure, not a title-specific address or an assumption that it is a
particular SDK function. FFTA2 A6FE r0 provides the first observed example.

Candidate: compact the control flow while retaining the exact halfword access
order, overlap behavior, signed/zero/odd-length handling, final registers and
NZCV flags. Prefer an in-place replacement with no extra memory. The generic
`tools/game_optimization/check_halfword_copy_patch.py` takes addresses and bytes
from a per-game manifest and compares synthetic machine states and data accesses.
The first candidate passed 1,276 synthetic cases but failed full-game replay:
16 of 4,400 top-screen frames, audio, and non-code RAM differ. It is rejected,
despite 1.565% fewer ARM9 instructions in the selected Luso window. Synthetic
instruction savings do not establish native cycles or whole-game equivalence.

`tools/game_optimization/scan_guest_patterns.py` implements a register-renaming
structural detector with exact branch destinations and load/store roles. It
finds this scaffold in both ARM9 and ARM7 code; shared SDK identity is not yet
proven. It scans ARM main/autoload sections only. An occurrence in data or
Thumb code can be a false positive; require execution evidence before using it.

Trace actual caller ranges before promotion. MMIO, DMA/interrupt interleavings,
code-overlap destinations, instruction visibility and timing-sensitive readers
are separate obligations. Never replace halfword accesses with wider accesses
or DMA based only on equal final bytes in ordinary RAM.

The observed callers include toon-table MMIO, VRAM and palette uploads as well
as ordinary RAM. Whole-replay divergence starts before the profiled battle
window. An optimization applied globally at boot must pass initialization and
other callers too. Matching every return value and data access in an isolated
function does not prove equivalent interrupt, DMA, audio or graphics timing.

## Polling that also transfers data

A backward branch on a busy bit is not sufficient evidence of an idle loop.
Check the full loop for data-ready tests, MMIO data reads, destination stores,
byte counts and completion behavior. FFTA2's observed cartridge receive loop
polls ROMCTRL and consumes words from the cartridge data register. A halt or
NOP shortcut would remove required work unless a separately proven existing
mechanism performs the same transfer. This detector should prevent unsafe
idle-loop suggestions in other games.

## Redundant bitfield shift chains

Detector: flag-preserving ARM `LSL d,s,8; ASR d,d,16; LSL d,d,16;
LSR d,d,16; LSL d,d,16`. The final word equals
`((s >> 8) & 0xffff) << 16`, so `LSR d,s,8; LSL d,d,16` preserves that
result. `scan_guest_patterns.py` recognizes the structure with register
renaming and rejects flag-setting variants and SP/PC operands. It found six
ARM9 occurrences in the first title; this is not proof of SDK provenance.

Compacting a surrounding block requires every incoming branch, internal back
edge, literal and live register to remain correct. In the FFTA2 experiment,
the entry jump targeted the original loop-test location and had to move with
the tail. Retain all memory accesses and verify complete block state, not
only the simplified expression. `check_guest_block_patch.py` reuses the
existing Unicorn runner with a declarative private fixture.

The first patch preserved 32 accesses per four-vertex block and passed 1,536
synthetic cases, reducing 112 instructions to 103. All 4,400 replay screen
pairs and save data matched, but audio and RAM did not; the patch is rejected
under the bit-exact budget. Smaller arithmetic changes still need full-game
timing validation. Native gain is unknown.

The longer routes subsequently exposed three changed bottom-screen frames
and larger audio differences. A small observed delta in one scene is not a
whole-game bound. Register/payload traces should compare complete operations
separately from their timestamps: the first Luso trace matched 549,874 paired
blocks, while 1,477 crossed different frame boundaries. Track unfinished and
unpaired tails explicitly; never truncate them silently to declare equality.

The existing replay oracle now supports declarative completed-block tracing
and optional private SPU-register tracing. `compare_event_traces.py` compares
ordered payloads without aligning away changed or missing commands. Matching
control writes alone does not establish equality of sample-buffer contents,
interrupt scheduling, mixed audio or native output.

In the longer FFTA2 route, all 3,286,148 block payloads/end states and 539,880
SPU-register payloads match. Yet 755 sound writes cross different mix-call
boundaries, mixed audio differs, and two single-scanline image differences
remain. This is evidence for separating work equivalence from scheduling and
sample-source equivalence. The next diagnostic should observe actual channel
sample reads, not infer unchanged audio data from unchanged source addresses.

That follow-up matched all 46,439,652 FIFO words and 371,300,720 paired decoded
steps by channel/note/ordinal. It retained 37 unmatched tail steps across 15
notes rather than silently aligning them away. The dominant waveform changes
came from two notes starting one mix callback later. Matching source words can
therefore coexist with a substantial pointwise waveform delta.

The generic sample observer records values already read/decoded; extra emulated
reads could change the behavior under investigation. Its comparator keeps
channel-start generations, ordered payloads, timing and unmatched tails
separate. The output explainer checks the existing non-interpolated SPU
arithmetic against recorded samples and control writes. A write observed after
callback k must not affect k retroactively. It explained every captured
channel-output record in both runs, without approving mixed-audio differences.
Always repeat golden-output stability after changing diagnostic instrumentation.

## Active audio-buffer replacement

Detector: sound fetches retain the same channel, start generation, source
address and mix index, but the fetched word changes. Compare neighboring
words against known asset content to locate a possible transition between old
and new contents. Then trace actual CPU/DMA writes, completion, ownership and
sound-channel stop/reuse order. Matching command payloads or addresses cannot
prove that the hardware read the same data.

The FFTA2 Luso route provides a concrete lead: three words in one four-word
fetch burst differ; surrounding data matches two contiguous cartridge
sequences across an apparent overwrite frontier. Those three words alter
1,182 decoded samples. The Fire route has exact source/decoded values and
only four control-timing output differences. Do not generalize one route's
timing bounds to another or classify changed decoded values as phase alone.
Even an exact mixer-output explanation can contain different source data.
No caching, delayed write or buffer-lifetime patch is authorized by this
pattern entry; the writer/dependency evidence must come first.

The follow-up observes main-RAM bus stores and sound fetches in one ordered
trace, using values already written/read. All 17,272 store payloads match and
all 9,959 fetches per arm agree with preceding stores. Three ARM9 cartridge
stores cross the fetch boundary while the channel remains enabled at low
volume. CPU instruction context plus a zero executing-DMA mask identifies
the writer; a sound event's incidental CPU PC alone would not. This is a
concrete example of identical producer work yielding different consumer data
because of ordering. Do not apply a source-data cache or move a transfer
without preserving ownership, completion and active-consumer dependencies.

## Temporary decoder outputs are not automatically dead work

A decoder can write intermediate buffers while sound hardware reads separate
looping buffers. The observed FFTA2 routine repeatedly consumes 128 bytes and
produces 512 bytes, but its output ranges have no direct SPU fetches in the
replay. Separate PCM16 playback rings are active. Follow CPU/ARM7 copies,
mixing and ownership before removing the routine or caching its output. An
empty direct-consumer intersection is a lead to investigate, not dead-code
proof. Preserve the predictor state as an input when considering reuse.

The follow-up traced original halfword copies from those staging buffers into
alternating halves of the active PCM rings. All 15,392 observed copied values
matched preceding staging stores, and all 12,448 captured sound reads matched
preceding writes. The watch covered only the first 16 bytes of each buffer
half: it proves this dependency, not complete content recurrence or safe removal.

## Scaled nibble-decoder step arithmetic

Detector: `ASR accumulator,step,#3`, followed by unrotated immediate tests of
nibble bits 4, 2 and 1 and conditional additions of `step`, `step ASR 1` and
`step ASR 2`. The generic scanner allows register renaming and rejects shifted
or rotated tests, changed conditions, flag-setting additions and SP/PC operands.
It found one hot ARM9 occurrence in FFTA2; no SDK identity is established.

For positive step values divisible by 8, with `15*step` fitting signed 32 bits,
the sum equals `(step + 2*step*(nibble & 7)) >> 3`. Prove every table entry,
valid entry indices, overflow/rounding and flags before replacing it. The
removed tests preserve C/V only for unrotated immediates; N/Z must be overwritten
before use. Do not infer that from printed disassembly alone. Verify the entire
function's live state, all branch/literal relocations and ordered accesses.

Declare literal/table bytes as manifest `data_guards`. The existing virtual
loader checks them against the original and combined patched image. This is
not runtime enforcement: separately watch table writes and entry contracts
through each replay, with all instrumentation limits retained. The first
Luso route had no post-initialization table writes and 12,456 valid entries.

FFTA2's same-size arithmetic candidate passed 4,885 synthetic cases and reduced
the selected battle instruction count by 2.512%, with exact screens and saves.
RAM/audio still differ. It remains disabled: local arithmetic equivalence and
fewer instructions do not establish scheduling safety or native performance.

The next battle route expands the failure: 1,892 bottom-screen frames differ
and audio reaches opposite clipping limits. Most changed images match a
neighboring control frame, but 376 have no identical hash within three frames.
Retain same-frame failures and unmatched results rather than aligning them
away. A small first-route audio bound must not become a game-wide allowance;
observe actual source words, decoded samples and sound-control timing before
classifying the cause. The retained control can be reused only with pinned
trace provenance and matching semantic outputs for the current oracle.

The Fire follow-up matches all fetched source words and decoded values without
unmatched tails. Fourteen note starts move, and control timing shifts by up to
682 mixer callbacks, about 21 ms. The recorded samples/controls exactly explain
all channel outputs, including the large pointwise waveform differences.
Distinguish this measured timing effect from data corruption and from audibility;
the explanation still does not authorize a non-bit-exact patch.

The shorter route instead exposes three changed source words at an active
sound-buffer overwrite boundary. A separate trace for this candidate matches
all producer write payloads but moves three stores before the consumer read;
the unchanged data arrives earlier. This reproduces the dependency class
seen with the vertex patch, with a different timestamp delta. Confirm each
candidate's actual ordering instead of transferring another patch's bounds.
Preserve both cases: identical-source scheduling shifts and changed-source
interleaving need different evidence and must not share an assumed tolerance.

## Elapsed-time accounting is not removable debug work

Detector: a hardware-timer read with overflow accounting, storage of a previous
tick, accumulation of the delta and downstream counter updates. Follow the
consumers before labeling a changing RAM word harmless. The observed FFTA2
fields feed a 60/60/1000-limited counter. They are live accounting data, not
patch scratch. Equal images/saves do not authorize masking them or accepting
unclassified audio differences.

## Perceptual review of a retained exact-match failure

Keep the failed comparison and original candidate bytes. An explicit request
to watch an experimental patch permits recording it; it does not silently
change the release budget. Record the control and each candidate separately
with the same replay, oracle and original image identity. Require the new
recordings to reproduce their retained screen, RAM, audio and save results,
including the known failures, before interpreting the media.

`replay_video_capture.h` copies completed framebuffers at declarative frame
ranges and indexes the existing stereo output. It adds no emulated memory
access. `verify_replay_video.cpp` checks every recorded screen against the
oracle's existing pixel hashes. `render_replay_comparison.py` pairs both
screens by replay frame, plays the control and candidate audio separately,
and derives presentation timestamps from the original audio sample counts.
Its MOV output must decode to the exact concatenated PCM samples. No mixing,
normalization, time stretching or hidden frame alignment is allowed.

Label these as software replay comparisons, not native speed measurements.
The H.264 picture is compressed even when the source capture is exact; retain
lossless stills for known visual differences. `make_review_mp4.py` preserves
the encoded video but creates a lossy AAC convenience copy. Use the PCM MOV
for original-sound review. Human observation can inform a proposed budget;
it cannot retroactively make a digital mismatch exact or qualify untested
gameplay, lifecycle, combined-patch or native behavior.

## Native screening after perceptual review

Keep the host, renderer, bitstream, clocks, settings and private save seed the
same when selecting individual guest patches. Bracket each candidate with
unpatched controls; inspect actual scene state before starting a timed sample.
Title/attract-mode navigation delays are setup failures, not performance
samples. Preserve their receipts and recover before measurement. Validate the
staged cartridge's selected and unselected instruction sites without probing
hardware during the measured interval. Distinguish staged-byte admission from
live emulated RAM/cache verification.

FFTA2's first vertex trial increased publication throughput about 3.4% in
two short Luso windows, while the decoder's 1.1–1.3% change was comparable
to control variation. The larger software instruction reduction did not
produce the larger native screening gain. Require repeat candidates and
other scenes, and report publication rates without calling them unique
animation FPS or whole-game speed. An idle/movement window that includes a
settled menu cannot establish the duration of the move itself. Unavailable
cycle and frame-time distributions remain unavailable.

Equal consumed Quick Saves and clean process exits are useful bounded
checks; new save/write/reload, reset, ROM switch and relevant transitions
remain separate qualification gates. Signal-level silence/clipping checks
complement the user's perceptual review but do not establish bit-exact audio.

Retain the repeated result even when it weakens the first apparent gain.
FFTA2's second vertex session changed idle publication throughput by +1.328%
and movement/menu throughput by +0.167%, against about +3.4% in the first
session. The repeated movement value lies between its adjacent controls.
Report each session and the control spread; an average of two sessions does
not establish a consistent movement benefit. Verify loaded bytes, flags and
scene identity before attributing a weaker result to the patch being absent.
Once a bounded repeat exposes variability, change to the next representative
scene instead of repeating the easiest scene until a favorable sample appears.

A shared save and matching visible target do not make a native input route
deterministic. Screenshot-gated setup can change elapsed time before an action
and therefore RNG state. Record actual outcomes for controls as well as
candidates, alongside the hit chance and damage preview. Variable control
outcomes establish a limitation of the route; they neither prove that a patch
caused a different roll nor authorize calling that difference harmless.
Keep deterministic software failures separate from native screening.

When the default contact sheet misses a brief event, use declared extra
timestamps from the retained recording. Preserve the default contacts and
verify that adding this offline option leaves existing output unchanged.
An impact still can establish the displayed damage; it cannot by itself
establish exact spell duration or full-replay behavior.

When aggregate reporting encounters a signal failure, preserve that failure
and its original recording. Report descriptive performance with an explicit
failed qualification gate rather than silently excluding the run or weakening
the threshold. Keep provenance/capture validity and output behavior separate.
Detailed audio analysis should add a separate receipt and reproduce the
original statistics before locating quiet intervals. Exact captured zeros
with continuous timestamps establish an observation, not its source or cause.

Honor a predeclared repeat decision even when the candidate stays above the
mean of its controls. FFTA2's vertex Fire result changed from +1.621% to
+0.349%; the repeat lies between the adjacent controls and therefore does
not establish the required benefit beyond their variation. Retain both rounds
and close the unchanged version instead of adding runs until favorable.
Small menu-inclusive publication changes do not establish action-speed gains.
Likewise, a signal interruption observed in an unpatched control prevents
sole attribution to a patch, but does not prove shared causality or safety.

## Reconcile physical reads with existing partial-block caching

Before adding an asset cache, identify the actual request descriptor and
existing cached-block tag. Observe request arguments and completion using the
existing declarative RAM watcher, with CPU, mode, opcode, mapping and register
guards. Require unpatched golden equivalence before interpreting the trace.
Record caller, source, length, destination and asynchronous callback context;
an internal transfer loop's LR may be overwritten and is not a call stack.

Use `audit_rom_transfer_trace.py` to verify completed returned bytes against a
pinned immutable source, enforce pairing/ABI guards and classify nonoverlapping
source regions. Addresses and game-specific ABI definitions belong in fixtures.
Six tests cover changed payload/destination, pairing, context, mode/opcode/CPU,
source bounds, overlapping regions and failed or mismatched golden evidence.

Then reconcile physical transfers with the request path, including cache-only
requests and partial-block prefixes. Do not infer file requests from adjacent
physical blocks or confuse an archive context with a file identity. Reconcile
the original path before making any completion or IRQ equivalence claim about
a replacement. Keep frame-boundary observations explicit.

FFTA2's bounded Luso trace has 2,518 physical transfers but 1,109 requests.
The existing partial cache supplies 479,612 requested bytes across 1,065
requests, including two fully cached requests. Only 12 complete request keys
repeat, covering five asset ranges and 18,656 bytes; none of the 962 music
requests repeats. Static archive ranges can separate actual repeated assets
from block-alignment spill. Source-content reuse alone does not prove reusable
decoded state, valid storage, cheap lookup, redundant copying or native gain.
Promote this observation method, not the title's addresses or presumed SDK name.

## Reusing a detector across titles

Platinum USA revision 1 main/autoload screening finds the same branch-heavy
halfword-copy structure at ARM9 `020c4b18` and ARM7 `037fb040`. This is a
successful reuse of the generic detector, not a patch qualification. FFT's
rewrite of that structure failed whole-game screen/RAM/audio equivalence.
Require active-scene samples, actual callers/access types and timing validation
again for the new title and CPU. An ARM-only static scan says nothing about
unscanned Thumb or overlay code; Platinum has 122 ARM9 overlays. Preserve the
exact revision and overlay reload identity before considering a hook.

The repeated 6,000-frame Platinum bedroom/menu control now assigns 4.230%
of selected ARM9 samples to that halfword-copy extent, with zero samples in
the ARM7 counterpart. A nearby word loop (`020c4b90–020c4bb8`) accounts for
5.675% but advances only its source: its repeated destination writes need
actual argument/access tracing before any memcpy or redundant-upload analogy.
Screen instruction semantics, not adjacent addresses or similar loop shapes.

Likewise, classify high-cost register operations by their callers. Platinum's
DIV/SQRT register save/restore region accounts for 9.615% of ARM9 samples and
is called from the IRQ context path. This is context preservation, not proof
of an expensive software divide that can be replaced by hardware math. The
IRQ dispatch/context region itself accounts for 19.114%. Sampling is every
256th instruction entry and can alias periodic work; none of these shares
measures native cycles or establishes removable work.

Platinum's guarded entry/return census resolves the transfer roles. All
160,545 word-stream calls name the geometry FIFO, including 19,800 zero-length
calls with no transfer. Nonempty sources include main RAM and ARM9 DTCM;
the same high address byte does not make both ordinary main RAM. The halfword
helper has 442,800 OAM calls, overwhelmingly 2/6-byte attribute fields, and five
RAM calls. Its many 2-mod-4 addresses rule out a blind aligned-word substitution.

Reuse `audit_transfer_calls.py` with declarative ABI/region fixtures and the
existing guarded observer. Require a matching golden comparison, preserve
cross-frame calls and reject incomplete pairs. It audits arguments and leaf
effects, not transferred bytes or content recurrence. An estimate from
instruction paths is a candidate-selection aid, not measured savings. A
branch-only proposal must retain every ordered FIFO/OAM access and still pass
whole-game output/timing and native benefit gates.

Platinum's fixed-destination predication trial demonstrates the distinction:
1,680 synthetic cases retain registers, flags and ordered accesses, but the
6,000-frame replay changes 175,017 stereo samples and transient RAM hashes.
All screen pairs, save data and five fixed RAM checkpoint sets match. The
1.267% selected reference instruction reduction does not qualify the rejected
candidate or establish native benefit. Fixed checkpoints can miss transient
state, and pixel equality cannot replace the audio gate. Preserve both passing
checks and failures; do not mask more RAM or generalize another game's
perceptual approval to this result.

## Repeated empty-tail compaction

Detect nested forward scans over fixed-size records: an outer scan finds an
inactive record, an inner scan searches later records for an active flag,
copies the first active record into the hole and clears its former flag.
After an unsuccessful inner scan, repeating the outer loop rescans an empty
tail. An early exit can eliminate that work without changing record order.
Confirm this structure against executed bytes and capture the record count,
active flags and complete record payloads at entry with the existing observer.
Preserve stale bytes in inactive records, all externally observable state and
producer/IRQ interactions; logical queue equality alone is insufficient.

Platinum overlay 5 supplies the first lead: initial guarded entries have 64
inactive records. The original empty-case inner scans make 2,016 flag reads;
an early exit makes 63. A scratch-free Thumb trial later passes 1,338 synthetic
cases, with 900 pre-reset and 1,800 post-reset unpatched entry/return pairs and
full-route writer watches supporting the bounded immutability contract.
The shared runner permits only declared ordinary-read removal; writes, other
reads, complete memory, registers and flags remain exact. This is not an
interrupt/concurrency model. Preserve the signed capacity contract when
changing a reload or loop exit, and verify stale payload bytes as well as flags.

The candidate removes 4.679939% of selected executed reference ARM9 instructions
and preserves all 6,000 screen pairs, fixed checkpoint sets and save data.
However, 1,660 stereo samples differ, so the historical strict audio gate
rejected it. Later authorized native perceptual screening found no useful
Platinum walking/menu gain; it remains disabled for that reason. A substantial
reduction of redundant work can still affect timing.
Neither the routine's 5.816% PC sample share nor the trial's instruction
reduction is native speed.

HeartGold overlay1 has the exact same90-byte Thumb compaction block as
Platinum overlay5, at independently authenticated addresses. The shared
scanner now flags this exact variant, including branch displacements, signed
count reload, copy order and return. It also scans explicitly selected ARM9
overlays through the existing guarded reader. A byte match is a lead only;
flat PC samples still require live overlay identity before attribution. No
Nintendo SDK or broader middleware origin is inferred from these two titles.

HeartGold's terrain-only control has299 paired empty64-record calls with exact
entry/exit contents and a full-route writer watch. Capacity and records last
change at initialization; observed VBlank/VWait work uses a separate array and
lock. The same54-byte replacement passes1,338 synthetic cases on HeartGold's
owned instruction context. Its incremental replay removes3.41349% of selected
ARM9 instruction work, preserves all top frames/save/checkpoint RAM outside
the new patch, and changes one bottom frame plus3,660 stereo samples. These
results justified a native screen. The later HeartGold A/B/A plaza rates are
19.6969, 19.3983, and 19.3827 complete publications/s; the candidate is
-0.724% versus the control mean and fails the predeclared useful-gain
screen. It remains disabled. Save/scene checks pass in that bounded trial; no
whole-game correctness, inaudibility or statistically proven slowdown is claimed.
Both titles illustrate why removing guest instructions alone is insufficient
when a different stage limits native throughput.

## Default callback dispatch

Detect fixed-size callback tables invoked at a frequent event, where an unused
entry is initialized with a default function that only returns. Capture each
call target, parameter, used flag and CPU/mode; compare the target's exact live
code, not a pointer value alone. A safe candidate must preserve newly installed
callbacks and registration/removal ordering. Never disable an entire interrupt
because the current scene happens to install only dummy callbacks.

Platinum's two HBlank slots make 63,120 guarded dummy dispatches in 120 frames.
This is a bounded scene observation, not full-route invariance. Both this lead
and the compaction lead require exact overlay ID/content and reload delivery.
Reuse the existing `prepare.assemble` overlay reconstruction machinery when
qualifying generic support; its FMV-specific extension cannot be assumed safe
or necessary for another title. A whole-overlay checkpoint match identifies
code at that checkpoint, not every future load.

For Thumb callbacks, the observed target's `70 47` (`BX LR`) is a useful
empty-body signature only after mode, target identity and actual dispatch are
verified. It does not imply the surrounding call is free of state changes:
`BLX` sets LR. Count the complete proposed guard and retained register/flag
work before allocating code space. Platinum's original two-empty-slot function
takes 25 synthetic instruction entries; a naive per-slot pointer guard can add
more entries than the call/return pair it removes. Native cycle costs may differ.

Audit registration and deletion stores, not just steady-state slot flags.
Platinum writes parameter/callback before setting `used`, and clears `used`
before restoring the dummy callback. A synthetic live-callback snapshot with
`used=0` performs a write, disproving that flag alone as an empty-call predicate.
Caller IRQ exclusion remains a separate proof obligation. A fast path needs
the actual target identity and preserved real-callback path; do not infer that
alignment padding or a neighboring function is available for a trampoline.

HeartGold independently confirms the same two-slot default-callback pattern.
Its guarded dispatch-only candidate compacts an existing initializer within
the same authenticated 84-byte extent; it does not assume padding or scratch.
Both actual function pointers are compared before an early return, and the
active path reloads slot2 after slot1. 608 ABI/side-effect cases include
`used=0` with a published callback and a first callback replacing the second.
Empty calls fall 25→9 synthetic instructions; the outdoor reference falls 2.1571%.
The native clean pair is 20.0314→19.7002 publications/s, so the patch stays
disabled. A second control 19.8837 has one OBS render miss and is descriptive
only. Lower guest work does not establish useful native speed. Retain
volatile-register/flag/stack differences honestly under the approved budget;
do not label ABI equivalence as bit-exact machine-state equivalence.

For an uncompressed overlay, prefer a same-size replacement in its existing
virtual cartridge file over relocation or new scratch. The shared
`prepare.read_overlay` now serves both FMV preparation and guarded guest byte
patches. Resolve ID/table/FAT/base first and verify the complete decoded body;
never infer identity from a reused RAM address. Follow the overlay table's
compression flag: ordinary uncompressed bytes can resemble a compressed
footer, as Platinum overlay 62 demonstrated. Do not run compression
autodetection over uncompressed data. An explicitly selected same-byte patch
should reproduce the entire original cartridge and baseline replay before
optimization. Platinum passes 122 decoder comparisons, 38 tests, ten full-image
preflight cases and all 100 baseline files. This control establishes no
changed-instruction execution, cache visibility, reload safety or speed gain.

Platinum's subsequent soft-reset/Continue control matches all 166 files over
12,000 frames. The full overlay body is replaced during title/menu and restored
in the bedroom, with 1,800 guarded Thumb entries after reset. This qualifies a
bounded unpatched reload route. Candidate RAM normalization must distinguish
that overlay's complete original/replacement identity from other content at
the same address; an initial-main-code assumption is insufficient. Preserve
raw comparisons when the overlay is absent instead of masking its RAM extent.

The shared comparison now implements that rule: bind the complete original
body to the manifest, derive the combined replacement, and mask only declared
instruction bytes after a whole-body match. Partial loads, corruption and other
overlays remain raw. Both new frontend controls reproduce all 100/166 golden
files; 27 adversarial C++ checks cover context/overlap/partial-body cases.
This comparison never writes guest memory and does not qualify native cache
visibility, state-load behavior or a candidate that fails audio validation.

## Fixed-width sparse bitmask traversal

Detect a bounded loop that tests bit zero, updates a selected table entry,
shifts the mask and advances an index through every supported bit. This is
table maintenance, not an idle wait merely because the table serves IRQs.
Capture the actual masks, output callback/data values and call counts before
estimating empty iterations. A possible early-zero exit must preserve selected
writes and their order, behavior for high bits outside the supported width,
return registers and flags. Treat an initially zero mask separately: a shift's
carry flag can differ from the original loop's final compare. Authenticate
literal pools and DTCM/main-RAM mappings rather than assuming ordinary RAM.

The generic scanner now recognizes `TST mask,#1`, a forward empty-bit branch,
a body that preserves mask/index, and an increment/width-compare/right-shift/
back-edge tail. It permits register renaming and bounded forward body branches,
and rejects calls, indirect control transfers, escaping branches, changed loop
operands and malformed bounds. This is structural screening only: table meaning,
initial index, CPU support and runtime safety still require evidence.

Platinum's outdoor census finds 57,600 masks selecting bit 21 and only 240
selecting bit 6 over 1,800 frames. An early-zero exit therefore saves almost no
work in this scene. A same-size 128-byte ARM9 replacement instead isolates the
lowest set bit, uses CLZ to obtain its index, and visits selected bits in their
original order. It retains the 22-bit cap, upper-bit return, original literal
loads, selected table writes, stack and terminal flags. All 12,262 synthetic
cases pass with identical ordered data accesses and no scratch. Keep ARMv5
multiply operand restrictions in view; the tested assembly keeps the
destination distinct from the first multiply source.

The scanner independently finds a 25-bit ARM7 variant with no samples in this
window. Do not transfer an ARM9 CLZ replacement to ARM7. Neither match establishes
a shared SDK name or an interchangeable patch.

Despite 57,840 individually valid candidate call contracts and identical mask/
callback counts, the full replay fails: one screen frame, fixed RAM checkpoints
and audio differ. Its 2.178710% reduction in aggregate reference instruction
entries is not a native speedup or an accepted optimization. A correct local
algorithm can change whole-game behavior through interactions outside its
synchronous contract. Preserve the failed result; do not label those differences
harmless or reuse another game's perceptual allowance.

Under a later functional budget, Platinum's unchanged sparse scan is also
screened with its accepted terrain patch. The main graphics caller masks IRQs,
but a first-battle trace adds an IRQ-enabled single-bit call: do not promote
a scene-local exclusion observation into a universal precondition. All 82 new
contracts pass and inspected progression reaches victory. A fresh native
walking/menu pair finds no useful gain, so the patch stays disabled for cost,
not for raw timing/hash differences alone. Authenticate instruction support
against the shipped build-input archive when repository CPU copies differ.

When a write watch covers both code and literal data, the pair summarizer can
explicitly authenticate original control bytes and replacement candidate bytes.
Unknown watched addresses and conflicting guards still fail. This changes only
diagnostic accounting, not RAM comparison masks or any acceptance gate.

## Repeated sound pitch and volume arithmetic

Observe complete numerical inputs and returned values at guarded entry/exit
sites before choosing a cache or precomputation. Capture the BIOS lookup input
and result separately from the surrounding calculation: its key may be smaller,
but it does not identify the full function's output. Preserve clamping,
normalization, octave shifts, register/flag side effects and audio timing.
Stateful envelope updates are not interchangeable with pure numerical helpers.

The existing observer now supports explicit register-only rows for either CPU,
including ARM7 WRAM-resident code, without reading guest memory. The same
recurrence analyzer accepts an absent memory source and reports zero source
snapshots. It keeps incomplete/nested invocation rejection and distinguishes
captured key/output recurrence from proof that the entire function can be
replaced. The new frontend reproduces all 238 Platinum game/profile files;
only its three observer files differ. There is no game patch in this control.

In Platinum town, 57,827 pitch calls use 397 input pairs with no conflicting R0
results. A hypothetical 16-entry LRU has 55,815 hits (about 96.5%); a single
global last-value slot has only 1,233. Volume also repeats globally, but its
16-entry LRU has only 9,985 hits. High aggregate repetition alone does not
justify a small cache. These counts omit lookup, storage, invalidation and
timing costs and do not predict native speed.

Zero pitch occurs in 13,874 calls, each returning the observed base timer.
Prefer investigating a guarded arithmetic shortcut without scratch before
allocating a cache. Do not generalize the observed base range to other scenes:
the helper has clamps and wider-input behavior. A zero normalized lookup index
is not the same as zero pitch, since nonzero octave offsets can share that
index. Caller R4 addresses are context observations, not storage ownership or
proof of a stable voice lifetime. ARM7 patch delivery and BIOS/table invariants
still need separate qualification; no SDK identity is claimed.

## Predicating a carry-derived zero multiply

A multiply-accumulate into its own accumulator is an identity when either
multiplicand is zero. If existing code materializes carry as a 0/1 register
with `MOV zero,#0; ADC carry,zero,#0` and preserves C, changing a later
non-flag-setting `MLA acc,carry,x,acc` from AL to CS needs no extra guard
instruction. When C is set, retain the exact original MLA. When C is clear,
the skipped operation must preserve every destination and flag, not merely
the returned value. A different accumulator/destination breaks this argument.

The generic scanner recognizes a narrow five-instruction shape with an
intervening MLA before ADC and a SUB before the target. It verifies zero and
carry registers are not clobbered, no flags are written, every instruction is
unconditional, and no PC/SP or ARMv4 multiply destination/first-source alias
occurs. Check the encoded S bit: Capstone's ADC flag metadata can conflate a
carry read with a flag write. This is a static lead, not automatic patching.
Authenticate execution, full context and entry paths; no SDK identity follows.

Platinum supplies a one-byte example with 6,800 exact synthetic cases and
57,827 unpatched observations of C=0/R3=0. Both versions still enter nine
instructions in the tested block. Report avoided arithmetic separately from
instruction-entry counts and measured native cycles. An algebraically exact
instruction can still change asynchronous audio/IRQ behavior through latency.
ARM7 delivery and the full patched replay remain pending for this example.

A later cost screen uses the actual shipped CPU source, not generic ARM cycle
tables. Multiply latency depends on the encoded multiplier register, not on
whichever operand happens to be zero. Platinum's multiplier fits 16 bits, so
predication removes three local execution beats per observed call while still
fetching/decoding the instruction. Its weighted opportunity is only about
5.18 milliseconds over 1,800 frames. Treat that as a prioritization estimate,
not native speed; timing differences alone no longer reject this candidate.

## Guarded ARM7 autoload source delivery

Extend the existing virtual cartridge stream when the original boot code
already copies a pinned payload into RAM. Require the entire ARM7 image and
explicit settings-offset identity, validate the raw copy-table extents against
the shared decoder, then bind the selected section's index, base, bytes and
BSS. Preserve the boot prefix and metadata in the combined image. Source
identity is not proof that autoload finished or that the current RAM mapping
fetches those bytes; keep runtime execution and lifecycle gates separate.

The first supported layout is an uncompressed, contiguous ARM7 payload with
a final table and a selected section in the last shared-WRAM alias/private
WRAM range. Unknown layouts and malformed or conflicting guards fall back
atomically. Keep this restriction explicit rather than guessing compression,
aliases or unused memory. A same-byte patch must reproduce the entire original
cartridge and replay before testing a replacement. Trace copy stores using
the existing register observer, including source/destination pointers and
word values. The initial staging buffer can later become game data; address-only
comparison normalization there would hide real errors.

For comparison, bind both loaded and staging copies to the authenticated
manifest/source mapping. Use explicit physical main/shared/private RAM views,
not a single ARM9-base subtraction. Require the complete declared code context
to match original or replacement, and normalize only differing instruction
bytes in a local copy. Keep absent, partial and reused contexts raw. The
shared frontend and checkpoint summarizer implement these rules; their tests
cover bounds, overlaps, missing views and corruption outside the changed byte.
Preserve legacy ARM9/overlay behavior and qualify the rebuilt observer against
unchanged replays before interpreting any candidate differences.

Platinum's one-byte carry-predicated MLA then passes all 16,800 screen pairs
and save checks but fails audio (73,833 stereo samples) and one fixed RAM
checkpoint. Its 57,827 observed calls still satisfy C=0/R3=0 and preserve R0
for all 397 captured input pairs. Local numerical equivalence and fewer
arithmetic operations therefore do not establish full-system equivalence.
Keep the failed result; do not infer benign timing, native benefit or a
perceptual allowance from identical pictures.

## Active-scene evidence before hotspot classification

Validate the complete input file before a run. The existing oracle's formatted
reader can silently stop at a comment, leaving an apparently successful replay
that never submits later buttons. `validate_replay_inputs.py` screens syntax,
frame bounds and button masks without changing the oracle or game behavior.
Pin its receipt with the route and job. Then corroborate movement using actual
frames and read-only, internally consistent player/location state where
available. Held buttons, a scene label or a zero exit status do not establish
active gameplay; collisions, dialogue and missing input are separate cases.
Retain failed navigation probes with their exclusion reason. Only repeat and
profile a route as active once the recorded motion supports that description.

Game-generated saves can shorten later replay setup without editing progress
or inventing an emulator save-state format. Keep the original seed immutable
and write only to a disposable replay buffer. A final output file is not proof
of completed saving: inspect the game's completion message and a stable
per-frame save-hash tail, cold-boot into the expected progressed scene, and
independently repeat both routes. Preserve the producing inputs, hashes and
parent seed. Exclude partial writes instead of silently using them as baselines.

For visual scene review, authenticate the capture's channel order from the
producer, not its filename. The existing software framebuffer is BGRA8888 even
when a legacy snapshot has a `.rgba` suffix. Use the established BGRA decoder;
keep the original capture/hash and retain corrected previews as new artifacts.
An incorrectly decoded contact sheet is not evidence of a game palette or
texture-cache failure. Pixel equality and native visual accuracy remain
separate claims.

When extending a route, compare only its genuinely unchanged input prefix.
Removing a held button or a later A pulse changes that boundary even before a
new direction is pressed. Declare profiling-counter differences separately and
compare all game-state fields, audio, screen hashes and shared checkpoints
without normalization for unpatched runs. Do not label menu/dialogue tails as
continuous combat merely because the route also contains a battle.

## Repeated small lookup-table construction

A small color-dependent decoder table may be rebuilt on every text update.
Look for fixed nested loops that combine a few input values at constant bit
shifts and store a bounded sequential table, followed elsewhere by indexed
loads that expand packed data. This is a manual structural lead; the current
ARM scanner does not automatically detect the Thumb example.

Use the existing entry/exit register observer and full-route RAM-bus watch.
Check complete input recurrence, compare the existing table with an independent
model for each current input, then account for every observed table and key
writer, including initialization. A stored last-input key can avoid inventing
new scratch, but only if it reliably describes the actual table. Different
keys producing equal output, key truncation, partial updates, reentrancy,
asynchronous readers and reset/lifetime behavior remain separate obligations.

Skipping a table rebuild can leave different volatile registers, flags and
discarded stack bytes. Model those effects with the existing CPU-equivalence
runner and retain the strict full-replay comparison. Do not silently exclude
dead stack data from the RAM gate. Publish recurrence and an optimistic removed-
instruction bound separately from a real replacement's cost and native gain.
Platinum's font example has 8,833 already-correct tables in 8,900 calls, but
needs 72 bytes of stack effects and nontrivial register effects reproduced.
This establishes an opportunity, not an accepted cache or reusable SDK patch.

The concrete same-extent replacement measures both paths: 42 synthetic entries
on a coherent hit, 6,701–6,707 on a miss, against 5,247 originally. Apply those
costs to the observed key sequence before predicting a whole-scene benefit;
high hit rates alone do not establish it. Compare truncated stored fields with
complete arguments so out-of-range inputs cannot falsely hit. Include an
intentionally incoherent key/table fixture to demonstrate that the full-memory
checker rejects an invalid precondition.

`check_guest_block_patch.py` can declare mapped ordinary-memory effect ranges
where final contents must be exact but access ordering may differ, plus
read-only unchanged literal ranges. Registers, CPSR, every mapped memory byte
and ordered accesses outside those ranges still match. Invalid/unmapped/MMIO
ranges and literal writes are rejected; this is fixture-specific permission,
not a global relaxation or asynchronous-reader proof. Synthetic stack effects
remain in the comparison even when the function has already returned.

Platinum's implementation passes 8,672 synthetic cases and 1,338 observed
battle-call contracts, yet fails full replay on five upper-screen frames and
61,453 stereo samples. All fixed RAM checkpoints and saves match. Record it
as rejected; the 2.264% reduction in ARM9 reference entries is not a native
speedup. This sharpens the reusable detector/validation procedure but does not
promote the title-specific bytes into a safe SDK signature.

## Native benefit screening after an authorized perceptual experiment

A byte replacement can reduce reference instruction entries while leaving the
native limiting stage unchanged. Platinum's empty-tail, FIFO and font-table
replacements saved 1.27–4.68% of selected ARM9 reference entries, yet showed no
worthwhile gain in the screened native walking/menu/Bag scenes. This does not
establish their effect in an unmeasured battle or every game using the pattern.

Use the existing `native_rig.py`, `native_session.py` and `native_capture.py`
with configuration-owned paths, byte guards, save size/hash, fresh PID/epoch
ownership and bounded input. Keep game addresses and routes in manifests and
private fixtures. Endpoint screen publications and published source-frame IDs
are different counters; neither alone measures unique gameplay FPS, pacing,
emulated cycles or input-to-ready loading time. Pair each route prefix and
scene position, retain control repeats and exclude mismatched routes even
when their raw counter delta looks favorable. A collision anchor removes
position drift but does not make real-time input or RTC deterministic.

For native audiovisual review, select the actual game-audio stream rather
than assuming stream zero is audible. Copy encoded packets and verify their
bytes and exact rational timestamps. For reference comparisons, retain the
original PCM audio and frame timestamps; clearly label the software replay
and alternate unmodified control/candidate sound instead of mixing tracks.
Near-black transition windows are a narrow visible-duration metric and must
not be presented as complete load time. Human approval of a difference and
measured native benefit remain separate requirements.

## Repeated geometry submissions with complete dependency checks

Start with the existing normalized geometry trace, filtered through the replay
frontend, before adding a new observer. Require an exact unpatched golden run.
Count parameter packets separately from multi-parameter commands and use
observed swap boundaries rather than assuming each emulated frame submits 3D.
Exclude partial boundary intervals. Keep DMA events separate from CPU callers;
an instruction interrupted by DMA is not the DMA payload's producer.

Platinum's qualified outdoor window has 300 swap submissions across 600 replay
frames. Of 299 complete intervals, 102 adjacent pairs have identical normalized
command/parameter payloads. This does not imply identical texture/palette bytes,
readbacks or safe frame reuse. Its 5,686,767 parameter packets include 4,811,611
while DMA is active. Investigate model/display-list ownership instead of
assuming all expensive traffic comes from the sampled CPU copy helper.

Repeated viewport, texture, material or polygon values are screening leads,
not automatically redundant commands. In particular, an unchanged material
assignment can also reset current vertex color; normal/color commands and
query/stack effects must be considered. A title-specific culling helper may
already reject off-screen props while other model categories follow different
paths. Authenticate each function and category before extending culling.

Before adding visibility culling, census the title's existing query entry and
return under exact instruction guards. In Platinum, 2,400 prop tests include
1,729 rejected and 671 accepted draws; the returned true value is raw bit 1
(value 2). Shared model resources have different instance transforms and
visibility outcomes. Capture actual bounds/transforms and camera/projection
state, not just pointers. Separate terrain, props and character drawing paths:
a valid-only terrain draw is a lead for coarse culling, not proof of invisibility.


For coarse model culling, first distinguish the draw object's model resource
from its instance transform. Observe arguments at a category-specific caller:
common draw helpers can mix main-RAM and DTCM pointers across callers. Reuse an
existing game visibility helper only after authenticating its mode, raw result,
transform contract and state effects. Immutable transform constants can replace
stack copies to fit a same-extent experiment, but changed stack residue remains
a recorded RAM difference. Count skipped draws **and added queries**, then use
native A/B; a large draw-count reduction can produce a small instruction saving.
Platinum skips 610 of 1,200 terrain draws but saves only 1.640% of ARM9 entries
in its outdoor reference window. The subsequent paired native trial averages
17.0125 → 19.2518 screen-buffer publications/s (+13.162%), despite the added
queries. Instruction counts alone understate this observed rendering benefit.
Keep the native counter definition and the remaining framebuffer/RAM/audio
differences explicit; neither native throughput nor visual review proves full
behavioral equivalence.

HeartGold independently matches this terrain/prop split in compressed overlay1.
The same structural method fits a guarded 48-byte Thumb replacement, reusing
that game's existing visibility helper and immutable transforms. Its first
reference trial skips 728 of 1,158 terrain draws, adds 1,158 queries, and reduces
outdoor ARM9 instruction entries 4.356%; native benefit remains unmeasured.
Keep the control on the same decoded-overlay delivery path: removing overlay
decompression alone shifts frame/audio timing. A repeated identical-code control
matches 154 files but is not bit-exact to the original compressed load path.
Do not transfer Platinum's native gain or audiovisual approval to HeartGold.

When fixed-frame RAM differs after reducing graphics work, first classify the
writers and readers. Transfer source pointers, remaining lengths, completion
callbacks and temporary projection changes may be live at the checkpoint; they
are not automatically dead state or timing counters. Reuse the RAM-bus observer,
prove that it reproduces both earlier runs, reconstruct watched checkpoint words
from stores, and validate CPU attribution against instruction samples. Check
every transfer's start, chunk arithmetic and completion before drawing a bounded
conclusion. Count bytes requested through that path separately from total DMA
bytes or physical bandwidth. Current SP alone cannot prove that differing stack
bytes are dead, especially across IRQ mode changes. Preserve strict mismatches
until the relevant liveness and behavioral contract is established.

## Fixed-size uploads within a strided destination

Capture the manager descriptor and every callback's full arguments before
classifying a bulk-copy hotspot. A six-byte copy repeated at eight-byte offsets
can deliberately preserve a separately managed halfword. Resolve the actual
callback table and destination arithmetic from owned bytes; a nearby function
with a similar name is not evidence of the active path.

The generic `snapshot_recurrence(events, fixture)` compares a selected payload
prefix, grouped by caller-supplied registers such as callback and destination
offset. It counts exact byte recurrence and differences in the excluded suffix.
It does not observe intervening writers, destination readback or invalidation.
High recurrence alone never authorizes skipping writes.

Platinum's first-battle control records 661,368 six-byte OAM uploads across
252 callback/offset keys. 657,844 payloads repeat (99.467%), including 70 cases
where the excluded affine halfword changes. Main/sub callbacks write three
ordered halfwords to `07000000`/`07000400` plus the offset. Consider in-place
fixed-size loop specialization that retains those accesses before considering
dirty checks. Preserve callback selection, register/flag liveness, address
wrapping and the separate affine path. A code-derived instruction-share model
is a prioritization aid, not native cycles or measured speedup.

Compare the complete surrounding function when a same-extent inline loop uses
registers differently. Registers dead at loop exit may be overwritten on both
continuation paths or restored by the epilogue; that must be demonstrated, not
assumed from calling conventions. An explicit code-context base lets the shared
synthetic runner execute earlier callbacks and later branches unchanged. Retain
SP/LR/PC, flags, mapped data and ordered device accesses in the comparison.
Only authenticated immutable literal reads may be excluded. Full-function
synthetic equality still says nothing about interrupt/DMA timing or native gain.

Platinum's 56-byte in-place specialization passes 92 full-function fixtures,
including both affine paths, and its battle reference completes coherently.
The first native walking/menu pair nevertheless yields only +0.387%/−0.245%
publication throughput. Keep it disabled without a worthwhile native benefit.
A large guest instruction reduction can leave a renderer-bound scene unchanged;
use an active target-scene measurement before generalizing the win.

Before labeling a native interval as an attack or other action, inspect the
visual state at both ends and in the recording. A bounded button sequence can
open a submenu without executing the selected command. Preserve that receipt
as menu coverage and start the action measurement from a verified selection.
Near-60 screen-buffer publication counts can include repeated game states;
they do not establish guest FPS or animation cadence. Compare reviewed semantic
boundaries in the videos, and do not compare entire turns when RNG changes the
opponent's move, critical-hit dialogue or other work.

Platinum's subsequent native battle pair is also flat: −0.061% menu and +0.008%
turn-window publications. The candidate returns to its menu earlier because the
opponent uses Scratch instead of Leer; that is not an optimization result.
Keep the fixed-size upload specialization disabled without positive native
benefit, despite its large synthetic instruction reduction and coherent play.


## Cache-key coherence and native text timing

When reusing an existing small lookup table, trace from initialization through
the full route. Check the complete key against each call's arguments, validate
the whole table on every hit, and reconcile all key/table writers with their
ordered outputs. Recheck this contract when adding an old candidate to a newly
accepted baseline. A high hit rate or synthetic equivalence alone cannot prove
that another writer has not invalidated cached data.

Platinum's font reuse on accepted terrain records 8,756 hits among 8,830 calls,
with every matching-key table correct and 18,944 regeneration halfwords matching
the model. It removes 2.369% of battle ARM9 instruction entries but does not
improve native menu publication throughput or the sampled text duration.
Record cache effectiveness separately from benefit at the limiting stage.

For text-heavy scenes, compare the same message's first and final glyph using
media timestamps. Configure small pixel regions, require a monotonic transition,
and inspect the absent/present boundary images. Bound each transition by its
adjacent captured frames; those bounds are sampling uncertainty, not statistical
confidence or proof of semantic identity. Avoid input/remote clock subtraction
for the duration itself. Use fresh interleaved repeats before qualifying an
apparent gain. A flat initial screen can use a preserved authenticated control
and be parked without claiming zero possible benefit everywhere.

Compare a shared message before divergent action outcomes. A missed attack or
a different opponent move changes subsequent work and invalidates whole-turn
timing. Do not call buffer publications unique guest frames, or interpret a
single longer message as a proven performance regression.


## Visibility-result reuse: camera dependencies and finite capacity

Capture the actual graphics submission after the game's setters, as well as
bounds and scale. Source model/transform recurrence can hide camera changes.
Use a deliberately incomplete key as a negative control: Platinum has 519
conflicting result observations when camera state is omitted; the full captured
submission plus box/scale has none in 3,600 queries. One differing view-matrix
word is enough to reverse the result. Preserve raw output conventions.

Verify observation itself against the accepted baseline, rather than treating
an accepted non-bit-exact optimization as a new golden failure. Platinum's
observer reproduces all 183 prior terrain output files; the original rejection
against unpatched output remains intact.

Use the existing generic recurrence analyzer to report both all-history reuse
and bounded-capacity hits, partitioned by target activity. Platinum's 78.33%
all-history recurrence becomes 57.0% with 16 entries and 15.97% during held-button
intervals. Input intervals are not proof of physical movement. Include full
key/result storage and lookup costs before selecting a cache design.

A matching captured key/result is evidence for investigation, not a removable
function. Flushes, matrix-stack operations, material/current-color effects,
primitive state, GPU result registers and command completion may outlive the
call. Prove these effects and cache storage/lifetime independently; do not add
a trampoline or overwrite zero-filled memory based on recurrence alone.


## Repeated cartridge reads and existing asset-residency modes

Observe transfer request and completion boundaries, not every poll iteration.
Reconcile descriptor source/destination/remaining counts, direct versus staging
paths and delivered words. Distinguish CPU-driven transfers from DMA and other
commands. Inspect existing partial-block buffering before counting prospective
cache hits. Platinum already has one buffered block; the observed worker has
no adjacent repeat benefit for another one-entry cache.

Capture prior-route history and report finite-capacity reuse separately from
all-history repetition. Source offsets in an immutable virtual image are a
prioritization key; they do not prove actual returned bytes, safe destination
reuse or removable completion effects. Keep profile-window differences explicit
when extending an existing reference trace back to boot.

Map repeated blocks through the owned FAT/FNT and overlay tables before
building a generic cache. In Platinum, fonts account for 24.78% of observed
battle CPU-driven requests. Owned code contains an existing allocate/read-once/
RAM-decompress/free mode, selected by a constructor enum. Such a guarded mode
switch may avoid new cache machinery. Authenticate it against the revision's
instructions and live objects, then prove heap headroom, allocation success,
lifetime and output behavior. Text timers may hide the gain in typewriter
pacing; measure representative load and instant-text work as well.


## Resident assets can exhaust later child heaps

Successful initial cache allocation is insufficient. A parent heap can retain
resident assets yet later fail a large child-heap creation. Capture transitions
before the profiled target, authenticate null handles and inspect CPU exception
state. A low instruction count from a stalled game is never a speedup.

If an observer cannot dereference an invalid pointer, preserve the failure and
use a separate register-only diagnostic to identify it. Keep the same opcode
and revision guards, and continue to reject invalid pointers. Prefer a smaller
existing residency policy only as a new independently tested candidate; static
checkpoint headroom is not a full-route allocation guarantee.


A reduced cache can pass the target route yet leave little parent-heap margin.
Report free bytes and fragmentation per checkpoint, and choose the highest-use
asset subset before native screening when it recovers substantial space. Keep
child-heap creation and full-route allocation limits distinct from snapshots.
When RNG or turn timing changes, report instruction/read counts as observed
workload; they do not establish equal-work speedup even when the game progresses.


Select residency by measured asset use, not just available enum values. A
same-size wrapper can preserve its exact stack layout while selecting a subset;
validate call arguments, literal addressing and return behavior independently
of the intentional mode difference. Guard any table that maps the selector.

Keep observed traffic savings separate from timing claims. A changed RNG/turn
trajectory may reach expensive outdoor rendering sooner, increasing aggregate
instruction counts even after removing font reads. Compare the same semantic
phase on hardware, and retain all framebuffer/audio/RAM mismatch evidence.


For paced text, measure an identical semantic substring using first/last glyph
appearance in media PTS, and visually confirm each boundary. Keep the measured
line free of held advance input. An already populated previous line can make a
simple dark-pixel detector ambiguous; a newly empty line provides a cleaner
boundary. Validate absent/present and monotonic detector conditions rather than
silently accepting a misplaced ROI. Keep instant-panel animation, fixed waits,
input-emission timestamps and buffer publication counts separate from text
latency. A reduction in cartridge requests may yield only a tiny paced-text
saving; compare that benefit with resident memory and lifecycle cost before
qualifying a patch. Within-session repeats are not independent cold runs.


When an interpreter fetches two Thumb instructions in one word, its raw current
instruction field may retain the next halfword. Observe CPU mode, compare only
the executing Thumb halfword, and keep ARM comparisons at full width. Include
raw value, decoded value, PC, CPU and frame in failed-guard diagnostics. Preserve
atomic output, unchanged registers/RAM and full replay equivalence. This is an
observer fix, not permission to ignore changed instruction bytes or mode.

For archive precomputation, inventory header sizes, member lengths, padding and
payload offsets from the exact owned revision. Uniform lengths do not imply
contiguous records. Trace existing open/read/close routines before allocating a
new cache; repeated first-block requests are not all removable metadata reads.
Exclude nested wrapper double-counting and the block hits already served by the
SDK cache. Local PC sample share excludes descendant filesystem/IRQ costs.


## Dead positioning work in size-only archive queries

Detect wrappers that return a member's end-minus-start from an archive table
but also read later chunk sizes or seek to payload without consuming payload.
Use dataflow and owned callee disassembly to distinguish the returned table
fields from dead local file-position work. Prefer in-function branches that
retain bounds/empty-member checks and original calling convention. Preserve
existing allocation-failure and close behavior unless independently changed.

Execute the owned seek body when feasible; label any modeled filesystem
callees explicitly. Compare return values against the owned archive for every
observed call and edge/random members, while retaining caller-save/dead-stack
and global cache/IRQ limitations. Count physical requests with completion
pairing, since skipped reads may already hit a cache. A changed battle or input
trajectory invalidates aggregate equal-work speed claims even when the game
progresses. Measure identical semantic loading transitions on hardware.


Do not infer a native win from eliminating metadata reads. Pair a representative
semantic transition and preserve neutral results: opening and closing changes
can cancel within capture quantization. Report near-black intervals separately
from total loading and native routine work, and do not call publication counts
unique FPS. Static header/chunk constants may support a broader revision-guarded
optimization, but must not become general NARC-format assumptions.


## Revision-guarded archive metadata constants

Inventory immutable header/chunk values across every owned archive before
replacing their reads with constants. Require the full ROM identity, not just
the game header or executable, because resources can change independently.
Retain member checks, destination, explicit offset/count and final file position.

Recover stack arguments as well as register arguments. An explicit-length
archive API may intentionally read across multiple contiguous members; do not
add a member-size clamp or infer whole-member semantics from a zero offset.
Use the existing observer to capture argument and local-file state, qualify
unchanged control output, and include those real tuples in payload fixtures.
Label modeled SDK callees and separately verify owned callees where feasible.
Matching file positions establish selected ranges, not independent live output
bytes. Compare a common ordered call prefix before interpreting transfer counts
when later RNG/timing changes the scene. Native semantic loading measurements
remain necessary.

The shared `scan_guest_patterns.py --include-thumb` scanner now detects the
20-byte stack-local seek/read argument shape as `stack-file-header-halfword-read`.
It recovers the two call targets and stack slots, allowing relocation and
different stack layouts. This is a review lead, not proof of NARC semantics,
constant values or patch safety. The 15-test pattern suite passes, including
positive and negative cases for this detector. The owned Platinum scan finds three leads at `020068ee`,
`020069ce` and `02006b7e`, with expected original bytes and the same seek/read
targets. That scan has no PC profile attached: its zero sample fields mean
unprovided measurements, not unexecuted code. See the private
`ARCHIVE_METADATA_PATTERN_SCAN_V1.json` for the complete scan receipt.


For native loading tests, use visible semantic checkpoints after navigation.
A moving NPC or one extra dialogue advance can invalidate a timed route without
being a game defect. Authenticate the final prompt before capture. Distinguish
panel removal, loading, animation, first menu label and later attack outcome;
keep input-emission timestamps and fixed idle waits out of visual latency.
Fix detector regions from control, review adjacent boundary frames, and apply
the same conditions to the candidate. Preserve small/neutral native results
rather than extrapolating eliminated metadata reads into a gameplay speedup.

## Unsigned sum used only as an empty-queue predicate

Look for nested byte-load/add loops followed by comparison of the accumulator
with zero and a Boolean return. Prove the element type and maximum sum first:
negative elements or overflow invalidate replacing a sum with an any-nonzero
test. Inspect the whole function, not just the hot loop: an empty result may
also clear a timeout or update another field. Inspect all callers for live
caller-clobbered registers before discarding the actual sum.

Platinum's battle queue is a 4×4×16 unsigned-byte array. Its maximum sum is
65,280; only its zero/nonzero result is consumed. The empty case resets a
link timeout. A same-function ordered byte scan can return on the first
nonzero entry, retaining that reset and the original return blocks. It needs
no cache, scratch memory or new service. This remains a semantic review
pattern rather than an automatic safe-patching signature.

Use the existing bounded memory observer to capture the complete array,
counter, entry/exit registers and code identity. Wider object displacements
and guarded pipeline-PC snapshots now use the same mapped read path. Qualify
observer changes against unchanged control output before using their traces.
For overlay routines, authenticate the complete decoded overlay and individual
executions; an address match alone is insufficient. Test empty arrays, every
possible first nonzero position, maximum sums and original timeout effects.
Native measurements must distinguish cheaper polling from faster game progress.
In this instance, a 2.22% reduction in reference battle instructions did not
produce useful native first-turn text or publication-throughput improvement.
The byte patch remains disabled; the detector/proof pattern remains reusable.

## Native controls for decoded overlay delivery

HeartGold extends coarse offscreen terrain culling to a compressed overlay
through the existing virtual loader. Test three arms: original compressed
image, identical-code decoded overlay delivery, and decoded delivery plus
the patch. The45-second matched plaza screen yields18.6837/18.6071/19.2577
complete screen publications/s:3.072% over original and3.497% over delivery
control. Its4.356% reference ARM9-entry reduction is a different measurement.
The same48-byte Thumb replacement uses existing guarded constants and helper
calls, with no scratch or native service. Indoor throughput stays near59.64.

Use a verified private save at the target position when input timing drifts.
HeartGold's identical timed walking scripts diverge spatially even without
changed game code, so those output rates cannot establish an equal-work gain.
Keep loading transformation effects, render publication rate, source frame IDs
and actual animation/game-clock claims separate. Native cold reload of a
candidate-written save in the original image is useful compatibility evidence.
Timing/RAM/audio differences remain explicit under a functional budget; levels
and checkpoint stills do not establish human audiovisual equivalence.

## Preserve prior games when packaging a new optimization

A cumulative guest beta must retain explicit selections for earlier games.
Use the existing loader's pinned embedded catalog: original game/revision/header
identity routes one manifest, then full-ROM, CPU, overlay and byte guards admit
it. Duplicate identities/IDs and malformed selections fail atomically. Keep
ordinary FMV/NSMB fallback and legacy single-manifest semantics unchanged.

Before installation, compare complete outputs from the actual packaged worker
with previously qualified game images, including unselected movie/NSMB paths.
Then cold-load both the new and retained game using the packaged launcher and
separate saves; verify staged bytes and functional scene entry. HeartGold Beta1
retains exact HeartGold/Platinum/Portrait/Ni no Kuni/NSMB images this way. The
catalog adds no gameplay service or per-call HPS work and is not itself a speed
optimization. Keep gameplay performance attribution with the original patch.


## Interleaved sprite attributes and affine uploads

A sequence of six-byte copies at an eight-byte stride, plus two-byte copies
into the gaps, can be a sprite-manager upload rather than inefficient ordinary
memory copying. Authenticate the callers and destination region. Capture the
complete source allocation before upload and around reset; compare fields by
instance, address, width and stride, not by source pointer alone. The generic
`audit_staged_buffers.py` reads existing guarded snapshots and reports both
recurrence and phase changes from a fixture. Source equality does not establish
hardware destination liveness, intervening writers or safe update suppression.

HeartGold's field route supplies 300 groups per engine, with all observed owned
payloads identical to their previous upload. Nevertheless, reset changes 19
sub-engine records and allocation cursors each frame. The two managers have
different ownership: main sprite slots 4–127 overlap affine matrix 31 outside
its affine allocation 1–30. A bulk replacement must preserve interleaved fields
owned by other users. The sub allocation 0–123 covers precisely affine 0–30,
so its existing bulk path merits separate reset/cache/DMA and native checks.
No optimization or native speed is established by this source-only census.


## Enabling an existing bulk mode through an overlay initializer

A hot SDK routine in compressed main code may already expose a cheaper mode
selected by its instance. Investigate the existing initializer in a supported
overlay before adding a main-code patch or HPS service. Prove the exact flag,
allocation ownership, producer/reset contract, cache/DMA behavior and caller
ABI. Interleaved fields owned by other users remain a hard boundary.

HeartGold's sub-only OAM trial reuses the existing 992-byte path through a
guarded initializer and sole-call redirection. Full-route fetch/write traces
qualify the two padding bytes only in the authenticated overlay; an earlier
overlay executes that address. Bind context observers to verified overlay
epochs instead of treating a shared address as a global opcode identity. Use
the existing synthetic harness with actual owned callees and explicitly
modeled allocator contracts. Declare every permitted register/dead-stack/flag
difference; do not hide a whole stack or heap region.

This trial reduces reference ARM9 instruction entries by 2.21% but produces
no useful native plaza gain in a matched A/B/A screen. Existing bulk reset
also fills more bytes and performs cache/DMA operations; lower instruction
counts alone do not prove lower elapsed time. Keep the disabled manifest and
proof reusable, with raw audiovisual/RAM differences and coverage limits.

## Check display throughput before prioritizing instruction hotspots

Measure the target scene on the native core even when its reference instruction
profile looks light. Record complete screen-pair publications, frame-identifier
advance and renderer/host load separately; none alone establishes unique
animation FPS. HeartGold's starter screen has prominent copy and interrupt-mask
samples but publishes only 14.08 pairs/s while frame identifiers advance 59.84/s
and the renderer uses 161.96% of one core. Treat graphics submission as a lead,
then reuse the geometry observer and prove its unchanged-replay behavior before
classifying redundant packets or hidden geometry. Repeated commands alone do
not prove dispensable rendering or stable external dependencies.

Re-authenticate overlay identity at each new scene. Starter overlay 61 and field
overlay1 reuse the same base address; allocator ownership and code placement
proofs from the field do not automatically transfer to the starter screen.

The qualified starter trace has 25 identical adjacent command streams in 28
comparisons while each flush reports 1,014 polygons. This supports investigating
an application-specific unchanged-frame gate, not unconditional frame skipping.
Prove texture/palette dependencies, first draw, animation-key boundaries,
input/transition invalidation and native previous-frame retention. Keep UI and
animation updates outside the skipped drawing work. Existing object fields may
have unrelated meanings: the starter's `frame` byte is a window-style option,
not a spare frame counter. Record the proposal until a guarded implementation
and native benefit exist.


### Qualified unchanged-state gate without a new cache

Extend the existing geometry census through a complete animation cycle and
correlate each stream with the actual game animation object. Pin the source
asset, integral frame count and wrap behavior; a short repeated run can miss a
boundary. HeartGold's 104 phases include a distinct wrap at zero. Retaining
phases 0/7 modulo8 preserves all framebuffer changes while avoiding 78 duplicate
idle draws. Keep first rendering, inputs, active animation and transition
invalidation outside the gate. Do not treat an unrelated field named `frame`
as scratch. Use the existing same-size patch loader and instruction harness.

The resulting 88-byte overlay patch needs no allocation or per-call HPS work.
Its guarded idle/lifecycle replays match every screen image; native A/B/A gives
14.18/43.17/14.25 screen-pair publications per second and 32.19% less renderer
CPU versus the control mean. The light cycle remains about 3.47 seconds.
This exploits the existing renderer's retained-state reuse; it does not imply
that omitting game draw calls always eliminates native raster work. Measure
native throughput/load and animation cadence separately. Carry the detector
and proof structure to related engines; never copy an address into another
revision or overlay without new identity/asset/state evidence.

## Reclassify workloads after a scene change

Reuse a routine's classification only after matching owned code in the new
scene. Recollect caller, payload, destination and input recurrence evidence:
the same copy loop can serve different data. HeartGold's battle idle profile
again contains the halfword copy, but its field-only tiny-OAM census is not
proof of battle transfer sizes. A menu already publishing near 60 pairs/s does
not establish an active-animation bottleneck or a useful copy optimization.

For Thumb profiles, a 32-bit sampled opcode can be a paired Thumb BL rather
than an ARM instruction. Establish mode from execution/source context and
decode sampled instructions independently across literal pools. Check actual
instruction bytes against the owned image before assigning semantic labels.

Transformed-cell bounds tests are a reusable investigation pattern: signed
fixed-point matrix products, repeated64-bit multiply helpers, extrema ordering
and comparisons against surface dimensions. Investigate stable input tuples
and overlay callers before considering caching or bypass. The structural
pattern alone proves neither redundancy nor safe removal; no generic patch
or cross-title signature has been qualified by the HeartGold battle screen.

## Reuse an existing resident-data reader before adding a cache

Start with repeated cartridge block requests, map them through the owned FAT
and archive members, and trace callers of the allocation/read/free accessor.
Look for an existing game-owned resident array and accessor with the same data
semantics. HeartGold's experience task calls `GetItemAttr` on each update even
though battle `GetItemVar` reads the already loaded item array. The active route
finds 97 slow calls at two task sites and 888 resident reads. Exact code and
source attribution identify the context, item and attribute ABI; an unrelated
effort-value helper lacks that context and cannot use the same blind rewrite.

Prove mapping, stride, allocation bounds, initialization and lifetime. File
record size is not necessarily memory stride: HeartGold has 34-byte item NARC
members, a 36-byte array stride and only 513 of 514 members resident. Check
legal input domains and final/sentinel records, not just item zero. Pin the
overlay and surrounding instructions, keep caller normalization and return
semantics, and preserve fallback behavior outside the verified domain. Any
shared SDK/middleware promotion requires a new title's identity and contract;
this is a detector/proposal, not a qualified cross-title byte signature.

## Recognize repeated lookup-table generation by content

Trace the generator's arguments and existing destination before it writes.
Recompute the expected bytes independently and compare them to the current
table, rather than equating unchanged pointers with unchanged data. HeartGold's
font generator expands four colors into 256 halfwords: 1,141 of 1,171 active
battle calls already hold the exact result. Existing metadata is useful only
after checking every writer, first initialization, changed-color cases and
ABI/side effects. Main-code delivery limits still apply. Recurrence alone is
not native benefit; measure the resulting interaction or transition latency.

Near-60 screen publication windows can contain idle time and repeated frames.
For archive/caching candidates, measure matched action/load completion as well
as publications and CPU use. Keep input mistakes classified by observed game
behavior: a capture called "attack" that opens the Bag is menu coverage, not
an attack timing result.


The HeartGold resident-reader candidate now supplies a bounded example, not a
cross-title byte signature. Two same-size Thumb call-site rewrites reuse the
owned reader without extra resident storage. The 2,148-case contract covers
mapping, 16-bit normalization, 147 effect values, preserved registers and the
normal nested stack. Constructor/task/destructor code plus a full-route store
watch establish lifetime; special final archive members still need a legal-input
check. Do not generalize the patch to callers lacking the same context.

Measure event latency when a task performs work every update. HeartGold removes
36.14% of reference ARM9 instructions in its award window, but native A/B/A
message duration stays 6.70 seconds in all three recordings. Text printing and
gauge/wait progression can consume the saved budget without becoming faster.
Keep CPU relief distinct from measured gameplay benefit. Record first glyph,
message disappearance and transition boundaries; preserve capture quantization
and exclude attack/critical-hit messages or different XP/level-up sequences.
Do not impose a 30-second idle window on an automatically advancing screen.


### Precomputed overlay decoding and early visual anchors (HeartGold V13)

Detector: correlate repeated loader/switch entries with overlay IDs and table
metadata, then authenticate both stored and decoded bodies using the existing
`read_overlay` parser and full hashes. Group overlapping RAM ranges: alternating
bodies cannot be kept resident by address alone. A hot decompressor signature
or repeated footer pointer is attribution, not permission to skip loading.
Use existing `append-decoded-overlays-v1` delivery with unchanged instruction
bytes and original normal lifecycle; account for larger cartridge payloads.
No new runtime service, guessed scratch or game-specific shared-tool branch.

HeartGold overlay7 removes four observed backward decompressions while leaving
three overlay10 calls. Native loading-pause samples improve 50 ms, but total-turn
benefit remains unqualified and the candidate is parked. The same technique
is useful only when measured load cost matters to progression.

For short transitions, identify a visual cue before the optimized work and
verify its ordering with reference watches. A menu may disappear after loading
and hide the saving. Keep input emission, guest recognition, video origin and
visible action separate. Clock synchronization alone does not calibrate the
capture pipeline. Retain conflicting input/video timing results and quantify
capture boundaries; do not retrospectively declare a different primary gate
passed. Measure complete-action context alongside isolated pauses.


## Geometry query followed by duplicate draw setup (HeartGold V15)

Detector: authenticate query/draw entry and exit sites, capture model identity,
caller, transform inputs and the full global FIFO setup block, then pair only
successful queries with their immediate same-model draws. Address alone is
insufficient when model resources reload. Use existing guarded memory-watch
events and geometry census, with an unchanged replay qualification.

Identical bytes do not imply identical graphics state: bounding-box queries
may push/scale/pop position/vector matrices, alter polygon attributes and drain
the FIFO. Audit all intervening routines and restore query side effects before
removing setup. Keep no-query callers on their original path. Reuse authenticated
function space and normal stack frames; do not infer a scratch area from zeros.

HeartGold 600 prop pairs omit duplicate projection/view/base matrix, light,
material, viewport and texture-default writes after explicit polygon-attribute
restoration. All 9600 top frames and geometry frame counts match; command packets
fall 2.6970% and profiled ARM9 instructions 1.0710%. Native plaza benefit fails,
so the patch stays disabled. Track packet reduction separately from submitted
vertices/polygons and native renderer cost. This is an NNS SDK structural lead,
not a qualified cross-title address/byte signature or a general flush-skip rule.

## Spatially bounded model shapes (read-only detector)

Use `inspect_model_shapes.py` on a content-pinned raw NNS model. Decode the
actual packed vertex commands, including signed partial coordinates and
wrapping 10-bit deltas; do not infer geometry from resource-header totals.
Track primitive boundaries, inherited coordinates and matrix changes. Shape
names/material IDs alone do not establish spatial independence: one display
list may span much of a map.

Before culling, authenticate SBC/node/base/camera transforms and every material
side effect, then bind the resource hash and shape to observed runtime draws.
`model_visibility_math.py` can flag a bounding box wholly beyond one XY clip
plane; its conservative arithmetic is only a lead until runtime state and
lifecycle are proven. Do not substitute snapshot texture/material state for
all later frames. Skipping a display list must preserve any required outgoing
state, ordering and visible animation.

HeartGold's parked V16 investigation decodes 37 shapes across two terrain
resources. Owned SDK execution in synthetic capture shows model-scale changes
and texture-matrix loads, with no additional node position transform for these
two snapshots. Preliminary projection leads remain unqualified. The user
advanced to SoulSilver before a patch, replay or native test; no gain is claimed.

For related-game transfers, compare complete stored/decoded overlays, CPU
sections and every patch-dependent caller/helper/constant. SoulSilver IPGE0
matches HeartGold IPKE0 in 114/129 decoded overlays, including complete overlay 61;
overlay1 differs by nine bytes outside the tested patch/dependency spans.
This supports a guarded transfer candidate, not inherited validation or native
speed claims. Always retain the destination game's own identity and replay/save.

SoulSilver's independent terrain replay now confirms the transferred caller and
constant contract for 1158 calls: the existing box query returns zero for 729,
leaving 429 terrain draws. All 9600 top-screen hashes match the unchanged decoded
delivery control. Native benefit was unmeasured at that reference milestone;
the later native result appears below. For cross-title ports,
repeat the original independently, distinguish decoded delivery timing from the
byte patch, and derive the first full overlay identity from the current trace
(frame 938 here); never copy another title's load-frame boundary. Preserve
leading/trailing partial call records when a bounded observer window cuts a call.

### Control guest calendar and distinguish cold starts from soft resets

SoulSilver's exploratory native terrain comparison crossed 18:00. The image colors
changed with the guest clock and a warm reset changed throughput. A fixed camera,
save and CPU frequency do not alone establish matched workload. Use the existing
host `NDS_rtc.cfg` calendar feature in an isolated kit to seed the same date,
weekday and time before each cold start; verify the actual seed in the host log.
Let guest time advance normally and restore the private fixture afterward. Never
change the machine clock or ship a test clock setting with the patch. Keep
warm-reset measurements separate from cold-session comparisons and disclose
within-session windows versus independent restarts. No new service is needed.

At the matched noon seed, the SoulSilver 48-byte terrain transfer improves fixed
plaza publications 6.4663% over original and 6.8766% over unchanged decoded delivery;
matched indoor throughput stays at the same ceiling. This independently supports
the earlier guarded related-title transfer. Preserve raw timing/RAM/audio drift
and exact identity/expected-byte guards; it is not a universal address signature.

### Reuse contracts only after matching resources as well as instructions

A related-title transfer can reuse a bounded synthetic calling contract when
the complete target code, replacement, helpers and relevant assets match.
Preserve the original contract receipt and label it as reused rather than a new
runtime test. SoulSilver's entire starter archive and 104-frame animation match
HeartGold, as does overlay61. Its own normally written native save, cold reload,
3600-frame idle repeat and 8400-frame selection-route repeat establish independent
scene inputs. The idle candidate preserves all screen hashes and cuts sampled
ARM9 instructions 50.5866%; this does not inherit HeartGold's native gain.
The candidate also preserves all 8400 selection-route screen pairs; a separate
house route matches all 65 output files with the gate enabled or disabled.

Keep retained patches and unchanged decoded-overlay delivery as separate
controls. An earlier terrain patch changes SoulSilver's boot/scene timing even
when no terrain is visible in the final picker. Compare the new gate against
the same cumulative control, preserve raw differences, and measure native
benefit before promoting a port or reverse backport.

SoulSilver independently confirms the native benefit: retained-terrain idle
publications rise from 14.2310 to 43.9443/s while the lamp period stays approximately
104/30 seconds and renderer CPU falls 32.24%. Classify a duplicate-draw gate by
both command/state invariance and unchanged visible animation cadence; throughput
alone can conceal a frozen or accelerated animation. Keep the animation update
running, limit the gate to proven idle states and separately exercise all active
selection states. Native normal Save, soft reset, fresh-process Continue/party
and overlay transitions qualify the related-title lifecycle without importing
its sibling's save or native measurements. Preserve same-index audio/RAM drift
and distinguish signal presence from audibility. A byte-identical port still
needs its own runtime evidence; a new reverse backport follows the same rule.

### Relocate a contract without broadening identity admission

Regional HGSS starter code supplies six relocated address layouts with the same
88 target bytes and all eighteen matching starter assets. Re-run the bounded
CPU contract at each distinct layout, including internal call destinations,
incoming branches, literal pools and ARM/Thumb alignment. A modeled callee can
share the tested code page only outside the tested byte extent; never remap that
page to install a fixture. The regional audit passed 28,080 synthetic cases.

Matching patch bytes and assets identify candidates, not supported releases.
Retain separate full-ROM/header/stored-overlay/decoded-overlay guards, inspect
changed external calls and global-data literals, and require independent scene,
save/lifecycle and native benefit evidence. German SoulSilver now qualifies the
starter gate in bounded reference/native checks. A compatible imported checkpoint
can avoid redundant regional introductions when its provenance and coverage limits
are explicit. Reuse relocated contracts once per distinct layout; still measure
each admitted identity and check its translated active states, normal save and
cold reload. One native pair can establish a large effect; repeat for ambiguity,
not mechanically. Compare visible cadence separately from publications. Source
manifests remain default-disabled. See `REGIONAL_PORTS_REPORT.md`.

French SoulSilver independently confirms this gate: 50.59% fewer sampled ARM9
instructions and 3.00× native publications, with the light period within one
captured frame of control. Reuse the shared static/CPU proof, while retaining
the region's own original/delivery/candidate replay, native measurements and
localized active-state/save/cold-load evidence. A post-save cold lab/party input
replay provides unrelated-scene coverage without repeating a full introduction.

Italian SoulSilver repeats the same qualification with 50.59% fewer sampled ARM9
instructions and 3.14× native publications. Its measured light cycle is identical
to control at capture resolution. All three regions preserve every idle screen
pair and pass localized choices, normal save, soft reset and cold party checks.
Keep these measurements attached to each exact identity; do not replace regional
admission or active-state evidence with a family-wide performance claim.

### Locate reached code across embedded literal pools

A bounded disassembly extent can contain several helpers, literal words and
unrelated code. A linear Thumb decoder stopped at a literal at relative `0x134`
in the HGSS bounding-box query extent, leaving later call encodings unclassified.
Follow direct branches and same-mode calls from the known entry; retain explicit
ARM/Thumb transitions, returns, literal references and unresolved transfers.
Here, calls at `0x40` and `0x84` reach helpers at `0x114` and `0x138`.

The private read-only flow probe matches 118 reached instruction layouts and
both internal call edges across all six SoulSilver regions. Its locator excludes
unreached bytes explicitly and masks direct-call encodings; it does not declare
excluded code/data or external callees equivalent. Record candidate call targets
and literal values for the next dependency audit. Never broaden patch admission
from this signature alone. Evidence: `SOULSILVER_BBOX_FLOW_LAYOUT_V1.json` and
`SOULSILVER_TERRAIN_FLOW_MASKED_CANDIDATES_V3.json` in the regional report's
private evidence directory. This probe has not qualified a terrain port.

### Verify imported checkpoint compatibility before patch testing

An unchanged imported checkpoint can silently enter new-game flow on another
region. Require the expected scene/overlay before continuing A/B measurements.
Korean HGSS uses save-footer magic `0x20070903`; Japanese/international HGSS uses
`0x20060623`. The owned Korean ARM9 contains the former value. The public
[PKHeX SAV4 implementation](https://github.com/kwsch/PKHeX/blob/master/PKHeX.Core/Saves/SAV4.cs)
and [HGSS block layout](https://github.com/kwsch/PKHeX/blob/master/PKHeX.Core/Saves/SAV4HGSS.cs)
describe the marker and checksum boundaries.

For the retained pre-starter fixture only, validate both general/storage block
footers and their payload CRCs, confirm extra blocks are erased, and convert the
four footer markers in a new disposable copy. This changes 12 bytes outside the
checked payloads; never replace arbitrary matching words throughout a save.
Keep source/converted hashes and exact differences. An unpatched cold reference
must load the intended overlay before the converted fixture is admitted.
This is test-fixture preparation, not a runtime patch, user-save migration or
proof of independent regional progression. Private evidence:
`IPGK_IMPORTED_SAVE_CONVERSION_V1.json`; the failed original V1 run is retained.

The same bounded recipe is independently verified for Korean HeartGold IPKK,
using its own verified HeartGold checkpoint. Unpatched
reference and native cold loads reach the intended scene. After normal native
Save, all four footer markers and payload CRCs validate, and the saved party
survives soft reset and a fresh process. Evidence:
`IPKK_IMPORTED_SAVE_CONVERSION_V1.json` and `IPKK_NATIVE_SAVE_FOOTERS_V1.json`.
Reuse the layout and checksum method; keep each title's seed and admission proof
separate.

Carry the checkpoint's game index, seed hash, reference input route and native
opener in the run plan. Shared engine code does not imply identical saved player
position. The retained HeartGold fixture needs one northward approach; the
SoulSilver fixture starts adjacent to the machine. The HeartGold route is pinned
by `HG_DRAW_A2_OPEN.json` and its own `starter-open-v1.tsv`. Regional reference
and native helpers now accept the base job and bounded opener batches as data.
Use that same identity-matched opener for the installed-archive smoke. Verify
the expected overlay and visible scene before recording any performance result.

Treat Save confirmations as input-route data too. The German HeartGold run
remained at its overwrite prompt after the inherited two-confirmation sequence.
The unchanged-save guard prevented a premature reset; one observed confirmation
then completed Save. Preserve the stopped attempt, check the written file, and
continue the remaining reset/cold-load tests. Never infer successful persistence
from elapsed time or a fixed button count alone.

The French HeartGold run confirms the plan-driven confirmation route: three
spaced confirmations completed normal Save on the first attempt, with the
changed-file guard still enforced before reset and successful cold party reload.

### Close regional direct-call dependencies before relocating an inline gate

A matching prefix or masked body identifies a candidate but does not authenticate
its callees or state pointers. `audit_regional_direct_flow.py` walks paired ARM
and Thumb instructions from explicit reference/regional entries, follows direct
branches and calls (including interworking), and checks every reached non-branch
instruction byte. Conditional returns retain their fallthrough; terminal returns
do not decode the following literal pool. Conflicting address mappings, changed
instructions, indirect transfers and instruction limits remain explicit failures.

Resolve each PC-relative literal independently. A pointer with the same offset
inside authenticated static-BSS bounds identifies the corresponding state field;
it does not establish equal runtime state or initialization. Other changed values
remain unresolved. Keep immutable object bytes and pointer-table guards separate
from this code audit. Unknown functions and indirect callbacks are not inferred.

The HGSS query audit closes 281 instructions and 51 direct edges across six owned
SoulSilver regions, including the geometry buffer/flush and box-result helpers.
All changed literals retain BSS-relative offsets; MMIO and scalar constants match.
Five synthetic regressions cover conditional-return/literal separation, changed
state fields, non-branch instructions, direct callees and indirect transfers.
Three additional owned-image mutation checks reject wrong instructions, global
pointers and callees. Evidence: `SOULSILVER_BBOX_DEPENDENCY_AUDIT_V1.json` and
`SOULSILVER_BBOX_AUDITOR_CHECKS_V1.json`. German runtime qualification then
independently records 4.3513% fewer reference ARM9 entries and 6.2662% higher
fixed-plaza native publication throughput. Static matches alone enable no port.

French SoulSilver IPGF independently confirms the same pattern: 4.3510% fewer
reference ARM9 entries and 5.5788% higher fixed-plaza native publication
throughput. Reuse the unchanged six-region code/dependency audit, while keeping
each region's replay, original/candidate scene admission and save lifecycle
separate. The French two-patch release stream exactly matches its native trial
after removal of the trial-only no-op entry. Evidence:
`IPGF_TERRAIN_QUALIFICATION_V1.json`. No additional signature is necessary.

### Diagnose timing drift without hiding unmatched output

When an optimization changes same-index framebuffer hashes, compare each screen
pair against nearby control frames before assuming missing geometry. Preserve
raw counts and report the offset distribution and unmatched frames separately.
For audio, bounded cross-correlation can locate a sample offset; measure the
residual on both channels afterward. Alignment is a diagnostic, not a modified
golden reference or an inaudibility verdict.

`diagnose_replay_timing.py` operates on retained replay output. Its window bounds,
search radii and thumbnail frames come from a separate specification. Italian
SoulSilver shows a one-frame advance during the early town transition, while
1,394 target screen pairs remain unmatched within eight control frames. Its
roughly 750-sample audio offset also leaves residual differences. This prevents
overstating a partial timing explanation. Native scene, progression, save and
gain checks remain separate requirements under the user's chosen budget.

Evidence: `IPGI_TERRAIN_TIMING_DIAGNOSTIC_V1.json`,
`REFERENCE_TIMING_DIAGNOSTIC_CHECKS_V1.json` and
`IPGI_TERRAIN_QUALIFICATION_V1.json`. The generic extraction reproduced the
diagnostic values and thumbnail bytes without another game replay.

Spanish SoulSilver IPGS reuses the same terrain gate and dependency proof with
4.3543% fewer reference ARM9 entries and 5.5358% higher native fixed-plaza
publication throughput. All target screen pairs and the save match cumulative
decoded delivery; one earlier menu frame and raw RAM/audio timing differences
remain recorded. Its own normal-save, reset and cold-load checks pass. No new
signature or repeated starter audit is needed. Evidence:
`IPGS_TERRAIN_QUALIFICATION_V1.json`.

Japanese SoulSilver IPGJ reuses the guarded terrain gate and the same direct-flow
proof, reducing reference ARM9 entries by 4.3798% and increasing native fixed-plaza
publication throughput by 4.2378%. All target screen pairs and the save match;
three earlier transition/menu pairs remain unmatched within eight control
frames. The existing timing diagnostic records these sparse differences without
masking them. Native home/Bag/save/reset/cold checks pass under the functional
budget. No new signature or repeated starter audit is required. Evidence:
`IPGJ_TERRAIN_QUALIFICATION_V1.json` and `IPGJ_TERRAIN_TIMING_DIAGNOSTIC_V2.json`.

Korean SoulSilver IPGK completes the six-region transfer of the same guarded
terrain gate: 4.3658% fewer reference ARM9 entries and 4.6829% higher native
fixed-plaza publication throughput. Target screen pairs and save bytes match;
one earlier menu frame and raw RAM/audio differences remain. The shared
281-instruction/51-edge dependency proof and existing loader are reused.
Unpatched admission of copied Korean-format test fixtures precedes native
qualification; normal game-written saves retain valid Korean markers/CRCs.
No new signature or repeated starter audit is needed. Evidence:
`IPGK_TERRAIN_QUALIFICATION_V1.json`.

German HeartGold IPKD transfers the same guarded terrain visibility gate with
4.3529% fewer reference ARM9 entries and 6.3372% higher native fixed-plaza
publication throughput. Its own six-region audit covers the full 168-byte caller
and 281 reached instructions/51 direct edges of the visibility-query closure.
Do not copy paired SoulSilver addresses: Spanish HeartGold's caller differs,
and every title/region keeps its own overlay hash, expected bytes and guards.
Static BSS-relative correspondence is not proof of runtime object values.
Target screen pairs/save match; raw timing/audio differences remain. Native
home/Bag/save/reset/cold checks pass. Reuse the existing detector and loader;
no new signature or repeated starter audit is needed. Evidence:
`IPKD_TERRAIN_QUALIFICATION_V1.json`, `HEARTGOLD_BBOX_DEPENDENCY_AUDIT_V1.json`.

French HeartGold IPKF independently confirms the same guarded terrain transfer:
4.3544% fewer reference ARM9 entries and 3.9483% higher native fixed-plaza
publication throughput. Reuse the six-region dependency proof and detector;
retain identity-specific bytes/hashes and the raw timing/audio differences.
Its own home/Bag/save/reset/cold checks pass. No new signature or repeated
starter audit is needed. Evidence: `IPKF_TERRAIN_QUALIFICATION_V1.json`.

Italian HeartGold IPKI confirms the same terrain gate under the functional
budget: 4.3574% fewer reference ARM9 entries and 4.2959% higher native fixed-plaza
publication throughput. Reuse the six-region direct-flow proof and generic
timing diagnostic. Preserve 1,060 target pairs unmatched within eight frames
and the residual audio differences; sampled views and save/reload do not prove
perceptual equivalence. Native home/Bag/save/reset/cold checks pass. Evidence:
`IPKI_TERRAIN_QUALIFICATION_V1.json`, `IPKI_TERRAIN_TIMING_DIAGNOSTIC_V2.json`.

Spanish HeartGold IPKS reuses the same guard/detector and timing diagnostic:
4.3687% fewer reference ARM9 entries and 4.8054% higher native plaza publications.
Target pairs/save match; retain two earlier screen differences and raw audio/RAM.
Native save/lifecycle checks pass. Evidence: `IPKS_TERRAIN_QUALIFICATION_V1.json`.

Japanese HeartGold IPKJ reuses the same guarded terrain detector with relocated
query watches from the shared direct-flow proof: 4.3815% fewer reference ARM9
entries and 3.6537% higher pooled native plaza publications. Preserve the first
borderline 2.9496% result; one extra pair was predeclared and all windows pooled,
not selected by best gain. The generic repeat summary checks matching scene
seeds, clock, capture settings/sequence, saved bytes and packet-preserving media.
Keep the two earlier frame differences and raw RAM/audio evidence. Receipts:
`IPKJ_TERRAIN_REPEAT_PLAN_V1.json`, `IPKJ_TERRAIN_NATIVE_IDLE_MEASUREMENTS_V2.json`,
`IPKJ_TERRAIN_QUALIFICATION_V1.json`. No new game signature or runtime service.

Korean HeartGold IPKK completes the six-region guarded terrain transfer:
4.3731% fewer reference ARM9 entries and 4.9934% higher native plaza publications.
Reuse the 281-instruction/51-edge dependency proof, relocated watches and loader.
The generic timing diagnostic preserves 2,462 target pairs unmatched within eight
frames and residual audio changes after alignment; sampled scenery and native
save/reload do not prove perceptual equivalence. Private Korean fixture footer
conversion is validated before unpatched admission and is never distributed.
Receipts: `IPKK_TERRAIN_QUALIFICATION_V1.json`,
`IPKK_TERRAIN_TIMING_DIAGNOSTIC_V2.json`. No new signature or runtime service.

Platinum CPUE revision 0 reuses the accepted 48-byte terrain gate with separate
ROM/header identity despite identical ARM9/overlay 5 bytes to USA revision 1.
Seven prepared Platinum identities share the 281-instruction/51-edge reached
query proof; each still requires runtime qualification. The uncompressed
unchanged-delivery control is byte-identical to the original, so its admitted
replay is explicitly reused without a redundant execution. Revision 0 measures
7.8328% fewer reference ARM9 entries and 18.8634% higher native fixed-Twinleaf
publications. Preserve nine earlier image differences and raw RAM/audio changes.
Its own house/Bag/Save/reset/cold route passes. Save validators declare footer
layout and bank-selection constraints: Platinum uses 20-byte footers and permits
an unchanged erased storage bank, unlike the HGSS fixture. Generic negative
checks reject payload corruption. No new game signature or runtime service.
Receipts: `CPUE_R0_TERRAIN2_QUALIFICATION_V1.json`,
`PLATINUM_BBOX_DEPENDENCY_AUDIT_V1.json`, `PLATINUM_SAVE_VALIDATOR_CHECK_V1.json`.

German Platinum CPUD revision 0 reuses the shared terrain-query closure and
identity-specific 48-byte gate: 7.8316% fewer reference ARM9 entries, 16.7762%
higher native fixed-town publications. Target screen pairs/save match; preserve
nine earlier banner-frame differences and raw RAM/audio changes. The identical
uncompressed delivery control reuses the admitted original replay explicitly.
Plan-driven input capture reuses the same native rig for house/Bag/Save/reset/cold
checks; declared Platinum save geometry validates the normal German save without
forcing four valid HGSS footers. No new signature or runtime service. Receipts:
`CPUD_R0_TERRAIN_QUALIFICATION_V1.json`, `CPUD_R0_TERRAIN_REFERENCE_REVIEW_V1.json`.

French Platinum CPUF revision 0 reuses the guarded terrain transfer and shared
query proof: 7.8459% fewer reference ARM9 entries, 16.8094% higher native fixed-town
publications. Target pairs/save match, but preserve nine earlier image differences,
intermediate RAM checkpoints and raw audio changes. Equal audio length does not
imply equal per-frame allocation: eight counts differ by one or two samples, with
the opposite shift on the next frame. The diagnostic records those values without
masking waveforms or declaring inaudibility. Native Save/reset/cold and declared
Platinum save validation pass. No new signature or runtime service. Receipts:
`CPUF_R0_TERRAIN_QUALIFICATION_V1.json`,
`CPUF_R0_TERRAIN_AUDIO_FRAME_COUNT_DIAGNOSTIC_V1.json`.
