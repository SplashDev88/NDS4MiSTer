# Runtime optimization patterns

Reuse `tools/standalone_host/fmv/hook_guard.py`, `prepare.VirtualRom`, the existing native ARM9 PC sampler and graphics-replay tests. These entries are evidence and admission rules, not permission to patch another title automatically.

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
However, 1,660 stereo samples differ, so it remains rejected under the audio
gate. A substantial reduction of redundant work can still affect timing.
Neither the routine's 5.816% PC sample share nor the trial's instruction
reduction is native speed. No reusable byte signature or SDK identity is
established yet.

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
