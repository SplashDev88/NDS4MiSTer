# FFTA2 guest-code optimization — 27 October 2026

Status: the copy patch is rejected. The vertex patch failed the current
bit-exact budget and is under **user-authorized timing investigation**.
A third, decoder-arithmetic candidate reduces selected Luso ARM9 instructions
by 2.512%; all 4,400 screen pairs and save hashes match, but RAM/audio differ.
All three remain disabled. No new guest patch is installed or release-qualified;
accepted FFTA2 Beta2 remains unchanged. Platinum is queued, not active.

## Scope and existing mechanisms

The target is USA A6FE revision 0, header CRC32 `8c766dbb` over 352 bytes;
complete identity and original/replacement instructions are in
[`ffta2-a6fe-r0.json`](ffta2-a6fe-r0.json). Exact published rc12 is the historical
control; accepted Beta2 source `70e35668b43a8da4f544324fbe13a42d2fee0ceb` is the
cumulative build. Its earlier gains are renderer changes, not guest patches.

Reuse `tools/standalone_host/fmv/prepare.py:VirtualRom` and `hook_guard.py`.
NSMB and FMV work already demonstrate guarded virtual cartridge loading without
changing the source ROM. The guest ARM9/ARM7 execute in FPGA; ordered graphics
records and readback fences cross shared DDR to the existing HPS renderer.
There is no assumed arbitrary guest-PC HLE trap. No RTL or new HPS service is
authorized by this investigation.

The existing replay oracle supplies both CPU instruction samples, framebuffers,
RAM, audio and saves. Its old FFTA2 correctness runs intentionally disabled
sampling. New diagnostic runs enable it without changing the game code. All
43,400 replay frames retain their screen, audio, save and per-frame RAM hashes;
only diagnostic instruction-counter columns differ. The underlying evidence
is `GUEST_PATCH_PROFILE_UNIT.json` in the private FFTA2 evidence directory.

## Initial hotspot classification

These are shares of software instruction samples within the listed address
ranges, **not native cycle shares or speedups**. Luso covers frames 2600–4399,
Fire 6500–8999, and library 23300–29999. The last includes the settled forest
dialogue after the transition. Ranges may cover part of a larger function.

| ARM9 work | Luso | Fire | Library |
|---|---:|---:|---:|
| Per-vertex setup/emission, `0208ccf4–0208cdb7` | 16.24% | 13.72% | 22.61% |
| ADPCM-like nibble decoder, `02020080–02020147` | 18.67% | 18.67% | 0% |
| Halfword copy, `020093e0–02009413` | 4.17% | 4.18% | 0.24% |
| Cartridge receive loop, `0201016c–02010193` | 4.06% | 5.06% | 1.42% |

The decoder uses nibble processing, predictor updates and clamped table
indices. Follow-up traces below establish copies into active PCM playback
buffers; no shared SDK or middleware identity is established. The cartridge
loop consumes data at `04100010` while polling `040001a4`;
it is not an idle loop that can simply be replaced with halt. ARM7 profiles are
also retained, with function/caller classification still open. Full disassembly,
hashes and the ten-pattern screening ledger are in
`GUEST_PATCH_HOTSPOT_REVIEW.json` in private evidence.

## First candidate: compact halfword-copy branches

`copy16-compact-branches` replaces a 52-byte ARM main-code function in place.
It retains the same halfword reads/writes and order, signed length checks and
return state. It uses no scratch memory, trampoline, overlay hook, DMA or HLE.
It must be admitted only for the pinned ROM/ARM9 identity and exact original
bytes. A diagnostic loader now reuses `prepare.VirtualRom` and `hook_guard`;
18 negative identity/target/byte guards fall back to the original image.
The existing replay oracle accepts that virtual image over stdin, retains the
original identity, and writes a separate RAM comparison with only the exact
52 instruction bytes normalized. It checks original/replacement bytes every
frame; unexpected code aborts the run. No patched ROM file is created. The
native host is not wired to this diagnostic candidate.

The generic `check_halfword_copy_patch.py` diagnostic passes 1,276 synthetic
cases comparing R0–R12, SP/LR/PC, CPSR, data memory and ordered data accesses.
Cases include zero/negative/odd/even lengths, overlap, identical pointers,
unaligned inputs in Unicorn and ARM/Thumb return. This does not model native
interrupt/DMA interleavings, MMIO, instruction-cache behavior or code overlap.

| Measurement | Original | Candidate | Interpretation |
|---|---:|---:|---|
| 16-byte copy, synthetic executed instructions | 74 | 44 | 40.5% fewer instructions in this function |
| 64-byte copy, synthetic executed instructions | 266 | 164 | 38.3% fewer instructions in this function |
| 128-byte copy, synthetic executed instructions | 522 | 324 | 37.9% fewer instructions in this function |
| ARM9 instructions, Luso frames 2600–4399 | 391,329,973 | 385,205,747 | 1.565% fewer; rejected output, not a speed result |
| Top-screen frames differing from golden | 0 / 4,400 | 16 / 4,400 | First difference at frame 1513 |
| Bottom-screen frames differing from golden | 0 / 4,400 | 0 / 4,400 | Exact |
| Main-RAM frames differing after code normalization | 0 / 4,400 | 4,268 / 4,400 | First difference at frame 94 |
| Audio stream | Golden | Different | First differing stereo sample at about 12.551 s |
| Final game save | Golden | Equal | Does not override other failures |
| Native game progress, p50/p95/max pacing, HPS load | Existing scene evidence | Not run | Software gate failed; no new speedup claimed |
| Native CPU cycle/DMA/cart-byte counters | Unavailable | Unavailable | Do not substitute instruction counts |

The unpatched virtual-stream control reproduces all 4,400 reference frames,
RAM, audio and save data exactly. The patch changes 20,480 bytes outside its
instruction region in the retained frame-2600 main-RAM dump. DTCM differs in
2,660 frames and ARM7 WRAM in 372. ITCM and shared WRAM remain equal. These
differences are not declared benign or masked. Further Fire/library patched
replays and native qualification are unnecessary for this rejected version.

Unpatched caller traces pass all original output checks across Luso, Fire and
library routes. Their profiled windows contain 7,015, 12,338 and 6,697 copy
calls, respectively. Besides RAM, VRAM and palette writes, the routine copies
64 bytes to `04000380` each frame: the toon-table range, confirmed in the
existing `GPU3D.cpp` write handlers. No odd alignment/length, overlap or writes
over this function were observed in these windows; this is not full-game proof.

Exact input manifests/checksums are preserved beside
`GUEST_COPY16_SYNTHETIC_V1.json` and `GUEST_COPY16_REJECTION_ANALYSIS.json` in
private evidence. The current manifest records rejection with `enabled: false`.

The new generic `scan_guest_patterns.py` structural detector finds the same
branch scaffold in ARM9 and ARM7 autoload code, with no hardcoded game address.
Six positive/negative scanner checks pass. The ARM7 occurrence has no samples
in the Luso window; shared SDK provenance is not established. Its coverage is
explicitly limited to ARM main/autoload sections, not overlays or Thumb.

## Second candidate: vertex bitfield packing

`vertex-pack-redundant-shifts` compacts five ARM shifts into two. Both compute
`((ip >> 8) & 0xffff) << 16` without changing flags. The 116-byte in-place
region starts at `0208cd44`; its entry jump and loop tail are relocated, while
the back edge retains its original target. Three padding NOPs execute only on
loop exit. Every load, texture-coordinate write and vertex write is retained.
No index multiply, geometry command, scratch memory or HPS service is removed.

The Luso reference trace observes 1,799 function entries from one caller and
328,653 packing-loop entries. In that window, `r5` is always `04000488` and
`r4` is `0400048c`, with stack arrays at `sp+4c` and `sp+6c`. All observed inputs
are aligned. Static ARM branch screening finds only the two internal loop
branches entering the patch region. This does not prove other routes or
indirect-entry safety.

The existing Unicorn runner, extended for a bounded block endpoint and extra
data pages, passes 1,536 cases: all initial NZCV combinations, boundary texture
words, randomized inputs and all mapped data. It preserves 32 ordered data
accesses and reduces each four-vertex block from 112 to 103 instructions.
Its MMIO pages are ordinary-memory models, not hardware-side-effect proof.
The prior 1,276 copy cases still pass after the runner extension.

| Luso comparison | Original | Vertex candidate | Decision |
|---|---:|---:|---|
| ARM9 instructions, frames 2600–4399 | 391,329,973 | 388,375,792 | 0.755% fewer; not native speed |
| Top and bottom frames differing | 0 / 4,400 | 0 / 4,400 | Both screens exact |
| Final save | Reference | Identical | Exact |
| Frame-2600 RAM differing outside patch code | 0 words | 2 words | Fails current budget |
| Audio differing stereo samples | 0 / 3,530,229 | 1,194 / 3,530,229 | Maximum signed-16 delta 77; fails budget |
| Native pacing, HPS load, gameplay gain | Existing evidence | Not run | No qualification or new beta |

The changed checkpoint words at `02132e8c` and `02132e94` belong to live
elapsed-time accounting. Disassembly shows reads from the timer at `04000100`,
storage of the previous tick, accumulation of the delta, and updates to a
60/60/1000-limited counter. These are not patch scratch or proven dead/debug
fields. DTCM differs in 2,599 frames, ARM7 WRAM in 54, and main RAM in 2,959;
the causes of those transient differences and the audio delta are not fully
classified. No additional RAM masks or benign-audio assumption are allowed.

`GUEST_VERTEX_REJECTION_ANALYSIS_V1.json`, `GUEST_VERTEX_TIMING_REVIEW_V1.json`
and `GUEST_VERTEX_BEFORE_AFTER_V1.csv` retain the detailed comparisons in private
evidence. `GUEST_VERTEX_INPUT_MANIFEST_V1.json` pins the exact tested input.
The user authorized investigation of bounded timing differences. This is not
release approval: the patch stays disabled until a complete validation result
meets an explicitly approved budget. The Fire replay adds one bottom-screen
mismatch in 9,000 frames: 51 pixels at y=10, x=106–156 differ only in blue by
4/255. Full-resolution frames 7639, 7641 and 8999 match exactly. This is a
measured visual difference, not an approved tolerance.

The broader library route exposes larger audio differences. The initial
Luso/Fire bounds cannot serve as a global allowance. Every top-screen frame
and every save hash matches across all three routes. These are the selected
profiling-window instruction counts; audio and screen comparisons cover each
whole replay:

| Route | ARM9 instructions before → after | Reduction | Bottom frames different | Different stereo samples | Maximum signed-16 delta |
|---|---:|---:|---:|---:|---:|
| Luso, 4,400 frames | 391,329,973 → 388,375,792 | 0.755% | 0 | 1,194 / 3,530,229 | 77 |
| Fire, 9,000 frames | 543,588,049 → 540,131,288 | 0.636% | 1 | 257 / 7,220,926 | 53 |
| Library, 30,000 frames | 750,160,463 → 742,351,141 | 1.041% | 2 | 233,754 / 24,069,760 | 3,203 |

Library audio differs between approximately 168.504 and 392.574 seconds, with
overall RMS delta 13.771 in signed-16 units. The largest delta occurs near
201.707 seconds. A local whole-mix sample-shift comparison does not explain it
completely. This is neither an audibility assessment nor proof of benign
timing. Full-resolution captures show 231 changed pixels on bottom row 5 at
frame 23878, and 135 on row 1 at frame 23885. Maximum channel deltas are 9/255,
with unchanged alpha. Their immediately adjacent captured frames and frame
29999 match exactly. Inspection places both differences during the bright
library transition. This is a measured scanline difference, not proof of its
cause or an accepted visual tolerance. Native
cycles, frame pacing, HPS load and gameplay speed remain unmeasured for this
candidate. The private table is `GUEST_VERTEX_ALL_SCENES_BEFORE_AFTER_V2.csv`.

Named checkpoint captures show why raw frame snapshots need interpretation:
at frame 1453, ARM9 is executing different rendering functions in the two
runs; at frame 2600, it is at different points in the same vertex loop while
DTCM is identical. At 1462, current ARM7 registers match but ten WRAM words
differ in the saved-context layout at `038074d4`. Save/restore routines
`037fc604`/`037fc638` establish that these are resumable CPU state. The DTCM
word at `027e105c` belongs to an existing 2 KiB thread stack whose descriptor
is `02125f10`. These are live memory roles; neither classification authorizes
masking or proves that every observed difference is harmless.

The declarative completed-block observer uses the existing instruction
callback. Across 549,874 paired Luso blocks, every ordered graphics-write
hash/count and every final register/CPSR matches. There are 1,477 blocks whose
start or finish falls in a different video frame. The replay cutoff leaves
one unfinished control block and one extra completed candidate block. This
supports equivalent work within the paired block, with different scheduling;
it does not establish complete game-state or audio equivalence. The trace
starts at boot, so its instruction totals must not be substituted for the
later profiling-window measurements above.

The complete library trace pairs all 3,286,148 completed blocks, with no
unpaired tail, restart or unscoped write. All ordered write hashes/counts,
end registers and CPSR match. Some boundaries move one video frame earlier
(410 starts, 381 ends). This strengthens the block-equivalence finding across
the longer route; writes outside this block are not covered by it.

The private SPU observer records all 539,880 sound-register writes in the
library route. Their width, address, value and order match exactly. Timestamps
differ for 54,907 writes, bounded in this replay by ±1,323 raw ARM7 clock
ticks. Of these, 755 writes cross a different mix-callback boundary, by up to
two callbacks in either direction. One write moves to the previous video
frame. Thus the traced sound-command payload is unchanged, while scheduling
differs. The observer does not trace source sample-buffer contents or output
of individual channels, so it cannot establish that timing accounts for every
mixed-audio difference. Do not turn these observed bounds into global limits.

The diagnostic control reproduces all 30,000 original frames, RAM hashes,
audio and saves. The diagnostic candidate reproduces the earlier candidate
outputs exactly. This checks that the added observers did not create the
reported differences. Evidence is retained in
`GUEST_VERTEX_DIAGNOSTIC_STABILITY_V4.json`,
`GUEST_VERTEX_BLOCK_COMPARISON_LIBRARY_V4.json`,
`GUEST_VERTEX_SPU_COMPARISON_LIBRARY_V4.json` and
`GUEST_VERTEX_LIBRARY_PIXEL_REVIEW_V4.json`. Four lossless audio review clips
are recorded by `GUEST_VERTEX_LIBRARY_AUDIO_CLIPS_V1.json`; no listening-based
audibility judgment has been made.

### Actual audio-source and channel-output follow-up

The V5 private observer records values after the existing FIFO read and decoder
step; it introduces no extra emulated memory reads. Its unpatched library run
again matches every original output, including the earlier profiling counters.
The candidate reproduces its V1 output exactly, and both V5 sound-register
traces are byte-identical to V4. Generic trace/source guards pass 11 checks;
four further checks cover output arithmetic, callback ordering, partial writes
and rejection of unsupported interpolation.

| Library observation | Control | Candidate | Comparison |
|---|---:|---:|---|
| Channel starts | 5,309 | 5,309 | All start parameters match |
| Actual FIFO words | 46,439,652 | 46,439,652 | Every address/value matches by channel, start generation and ordinal |
| Decoded sample steps | 371,300,735 | 371,300,742 | 371,300,720 paired positions/formats/values match; 15 control and 22 candidate tail steps remain |
| Captured channel-output records | 8,752,960 | 8,752,960 | Two bounded windows; 47,810 value/pan differences, plus two generation-only boundary differences |
| Captured mixed-output records before resampling | 547,060 | 547,060 | 45,491 differ; maximum signed-16 delta 3,682 |

All 16 channels use ADPCM in this reference route. Paired FIFO/decoder steps
occur at the same mix callback or one callback earlier/later. The 37 unpaired
decoder steps are tails of 15 notes, each with a one-callback start or disable
boundary shift. The largest count difference is four steps in a note. No tail
is removed from the comparison or declared acceptable automatically.

Output capture covers frames 11900–12399 and 22700–23199, around the largest
and densest mixed-audio differences. Two notes dominate: channel 2 generation
143 and channel 12 generation 303 both start one callback later. This is about
31 microseconds in the reference's 512-cycle, 16,756,991 Hz mixing clock.
Applying that observed start shift as an explanatory comparison reduces their
output differences substantially, but it is not used to pass validation.

An exact arithmetic check uses each observed decoded sample and the recorded
volume/shift/pan/enable updates. It reproduces all 8,752,960 captured channel
outputs in **each** run, with zero unexplained records. At equal mix indices,
47,766 differences involve the currently selected sample only, 43 involve
control state only, and one involves both. Thus these windowed output
differences are accounted for by sample selection and control timing, without
changed source audio words. This resolves the source-data concern for this
library replay; it is not a listening judgment, native timing measurement or
all-scene qualification.

Evidence: `GUEST_VERTEX_SAMPLE_COMPARISON_LIBRARY_V5.json`,
`GUEST_VERTEX_SAMPLE_COMPARISON_UNIT_V5.json`,
`GUEST_VERTEX_NOTE_TAIL_REVIEW_V5.json`,
`GUEST_VERTEX_OUTPUT_PHASE_REVIEW_V5.json` and
`GUEST_VERTEX_CHANNEL_OUTPUT_EXPLANATION_V5.json`. The user reports no visible
difference in the displayed screenshot pairs. This is recorded as positive
visual feedback, with the acceptance budget unchanged.

### Battle audio coverage and a live-buffer lead

The same pinned V5 observer now covers all 4,400 Luso and 9,000 Fire frames,
including per-channel output throughout each replay. Both unpatched controls
reproduce their goldens and earlier profile state exactly. Both candidates
reproduce their V1 screen/audio/save/RAM/state outputs. No patch bytes or
acceptance masks changed.

| Full-route audio observation | Luso | Fire |
|---|---:|---:|
| Channel starts, identical parameters in both runs | 311 | 364 |
| Paired actual FIFO words | 2,291,193 | 4,826,361 |
| Different FIFO word payloads | **3** | 0 |
| Paired decoded sample steps | 8,760,071 | 13,939,336 |
| Different decoded sample payloads | **1,182** | 0 |
| Unpaired FIFO or decoded steps | 0 | 0 |
| Identical ordered sound-register writes | 20,403 | 21,251 |
| Register writes crossing a mix boundary | 3 | 4 |
| Channel-output records per run | 38,457,840 | 78,721,488 |
| Different channel-output payloads | 467 | 4 |
| Outputs not reproduced by observed samples/control arithmetic | 0 | 0 |
| Different mixed records before resampling | 280 | 4 |

Fire's four channel-output differences are control-timing differences; all
source words and decoded steps match. Luso instead reads three different
words at `02172f90–02172f9b`, channel 6, start generation 23, at the **same**
mix callback 1,450,863. These change 1,182 subsequent decoded values. Zero
unexplained output arithmetic does not make those source changes harmless.

Each differing 12-byte sequence occurs once in the cartridge, at a different
location within `master/pc.bin`. Neighboring FIFO reads match a contiguous
sequence from the first location before the mismatch and from the second
location afterward. In the intervening four-word burst, both runs read the
new sequence's first word; the control reads three old words and the candidate
reads three new words. This supports a live-buffer overwrite-frontier
hypothesis. It does not identify the writer, prove buffer release/ownership,
or authorize an audio tolerance. Trace the actual writes and their ordering
relative to the sound fetch before deciding how to treat this difference.

Private evidence includes `GUEST_VERTEX_SAMPLE_COMPARISON_UNIT_LUSO_V5.json`,
`GUEST_VERTEX_SAMPLE_COMPARISON_UNIT_FIRE_V5.json`, the corresponding sample,
register and channel-output reports, and
`GUEST_VERTEX_LUSO_SOURCE_FRONTIER_V5.json`. The output explainer now processes
one channel pair at a time to keep full-route analysis within available RAM.
Its result fields match the prior library analysis exactly; only relative
versus absolute input-path spelling differs. No additional library replay was
needed. User screenshot feedback remains positive; no audio listening result
or acceptance approval is inferred.

### Cartridge-write ordering confirmed

The V6 diagnostic adds observations after the six existing NDS main-RAM bus
stores and interleaves them with actual sound reads and control writes. The
unpatched replay remains exact, and both arms reproduce their V5 outputs,
FIFO words, decoder steps and sound-control traces exactly. Six exact store
sites, four negative source guards, five malformed-range cases, and six
RAM-auditor cases were checked. No native code or game bytes changed.

All 17,272 captured RAM writes have identical ordered CPU/width/address/value
and DMA-context payloads across the two runs. Every one of the 9,959 captured
sound reads in each run matches the preceding observed stores: no unknown
bytes or inconsistent reads. The three differing words are written by ARM9
instruction `02010180`, `STRLO r0,[r5,ip,LSL #2]`, in the already identified
cartridge receive loop. Its preceding read uses `04100010`. No DMA channel
is executing at these writes; the instruction callback confirms the CPU PC.

| Three-word overwrite | Unpatched control | Vertex candidate |
|---|---|---|
| Store order relative to sound fetch | After | Before |
| Store mix callback | 1,450,863 | 1,450,862 |
| Sound-fetch mix callback | 1,450,863 | 1,450,863 |
| New data written | Same three cartridge words | Same three cartridge words |
| Data fetched | Old words | New words |
| Channel control at fetch | `d0400303`, enabled, volume 3/128 | Identical |
| Channel-disable mix callback | 1,451,343 | 1,451,343 |

Each candidate store occurs 1,740 raw ARM9 timestamp ticks earlier. Both
reference runs overwrite a buffer while channel 6 still consumes it; the
patch changes which side of the store boundary the fetch observes. The
channel stops 480 callbacks later, approximately 14.7 ms in this reference.
This explains the three changed source words and their downstream decoded
values. It is a software ordering result, not native verification, proof of
the high-level buffer ownership policy, or approval to accept the audio.
Evidence is `GUEST_VERTEX_RAM_WRITER_FINDINGS_LUSO_V6.json` and the two
`GUEST_VERTEX_RAM_*_AUDIT_LUSO_V6.json` receipts.

The generic scanner now detects the five-shift structure with register
renaming. It finds six ARM9 occurrences, including the profiled hot loop.
No shared SDK provenance or automatic safety is inferred. Eleven positive and
negative scanner checks pass.

## Unpatched decoder caller follow-up

The existing instruction-watch mechanism now records the higher-share nibble
routine without any guest patch. All 4,400 reference outputs remain exact.
Within frames 2600–4399, 962 wrapper calls produce 7,696 paired routine calls.
Each starts with count 256, advances the source by 128 bytes and destination
by 512 bytes, ends with count zero, and retains its predictor-state pointer.
There are two direct callers, `0202018c` and `020201a4`; their wrapper is
called at `02020254`. The observed wrapper input is `021c1380`, with separate
state blocks at `02127778` and `02127780`.

The output blocks fill `021c3800–021c47ff`. No actual SPU FIFO fetch in the
matching replay reads this range directly. Two PCM16 channels instead loop
over `021c1800–021c27ff` and `021c2800–021c37ff`.

The completed consumer trace observes the first 16 bytes of each staging
buffer and each playback-ring half. Decoder stores at `02020134` are followed
by the original copy routine's stores at `020093fc`, called from `02020664`
and `02020674`. Each call copies `0x800` bytes: staging `021c4000` to alternating
`021c3000`/`021c2800`, and staging `021c3800` to `021c2000`/`021c1800`.
All 15,392 observed copy halfwords in the selected window match the preceding
staging values; no DMA is executing. All 12,448 observed sound fetches across
the full replay agree with preceding captured stores. Unpatched golden outputs
and existing V5 source traces remain exact. This establishes a bounded live
audio dependency, not full-content recurrence or permission to remove decoding.
See `GUEST_NIBBLE_CONSUMER_FINDINGS_LUSO_V1.json` and
`GUEST_NIBBLE_STAGING_AUDIT_LUSO_V1.json` in private evidence.

Private receipts are `GUEST_NIBBLE_CALLER_FINDINGS_LUSO_V2.json`,
`GUEST_NIBBLE_RETURN_SHAPE_LUSO_V1.json`, and
`GUEST_NIBBLE_STAGING_INPUT_V1.json`. V2 corrects the V1 scope sentence to say
that the direct-SPU intersection was empty; its numeric findings are unchanged.

## Third candidate: exact decoder arithmetic

`nibble-decode-exact-arithmetic` replaces the 200-byte ARM9 main-code function
at `02020080` in place. The replacement body is 180 bytes with five unreachable
padding NOPs. It uses XOR for the nibble-parity toggle and replaces seven
weighted-step instructions with four arithmetic instructions. Literal-pool
locations, all memory accesses, predictor clamps and persistent state remain.
Branches and PC-relative literal loads are relocated within the same extent.
There is no scratch allocation, overlay patch, HLE or new HPS service.

For the exact 89-entry step table, each step is positive and divisible by 256.
Thus the original weighted sum equals `(step + 2 * step * (nibble & 7)) >> 3`;
even `15 * step` fits a signed 32-bit word. All 1,424 table/nibble combinations
pass. The removed unrotated TST instructions preserve C/V; the following
unchanged `TST nibble,#8` overwrites N/Z before use. Local intermediate flags
are not identical, so the proof requires that flag liveness condition.

The existing Unicorn runner passes 4,885 synthetic cases comparing every
register, CPSR, data/stack/table memory and ordered data accesses. Coverage
includes all initial table indices, NZCV combinations, predictor boundaries,
zero/negative/odd/even counts, overlap and modeled unaligned data. A 256-output
call executes 9,487 → 8,207 instructions, 13.492% fewer, preserving 1,180 data
accesses. This is not interrupt, cache, MMIO or native-cycle qualification.

The loader now accepts declarative `data_guards` for the original literal pool
and index/step tables. It verifies both the original data and the combined
virtual image, rejecting another selected patch that changes an invariant.
Six negative admission cases reject atomically; the existing vertex virtual
image remains unchanged. These are loading-time guards, not runtime protection.
The full Luso write watch records the same 108 initialization writes in both
arms and no writes after frame 0. A separate unpatched full-route entry watch
observes 12,456 calls, all count 256, with initial indices 0–72 inside the
required 0–88 range. Its frame-0 profile totals must not be compared with the
selected-window instruction counts below.

| Luso measurement | Original | Decoder candidate | Interpretation |
|---|---:|---:|---|
| ARM9 instructions, frames 2600–4399 | 391,329,973 | 381,498,749 | 2.512% fewer; not native speed |
| Top / bottom frames differing | 0 / 0 of 4,400 | 0 / 0 of 4,400 | Both screens exact |
| Every-frame and final save hashes | Reference | Identical | Exact |
| Frame-2600 main-RAM words outside patch differing | 0 | 0 | DTCM and ARM7 WRAM still differ |
| Different stereo samples | 0 / 3,530,229 | 7,694 / 3,530,229 | Maximum signed-16 delta 427 |
| Main-RAM / DTCM / ARM7-WRAM frames differing | 0 / 0 / 0 | 1,579 / 2,356 / 264 | Fails current budget |
| Native cycles, pacing p50/p95/max, HPS load, load time | No paired measurement | Not measured | No native gain claimed |

ITCM and shared WRAM remain exact. Audio RMS delta is 0.797 in signed-16 units;
this is not an audibility judgment. The unpatched control reproduces the
goldens exactly. The patched replay fails the strict RAM/audio gate and the
manifest remains disabled. Fire, library and native qualification are pending;
the vertex candidate's causal explanation or measured bounds must not be
transferred to this different patch.

Private evidence includes `GUEST_NIBBLE_STATIC_CANDIDATE_V1.json`,
`GUEST_NIBBLE_SYNTHETIC_V1.json`, `GUEST_NIBBLE_STREAM_ADMISSION_V1.json`,
`GUEST_NIBBLE_FIRST_REPLAY_REVIEW_V1.json` and
`GUEST_NIBBLE_ENTRY_CONTRACT_LUSO_V1.json`. The immutable tested input is
`GUEST_NIBBLE_INPUT_MANIFEST_V1.json`; the repository manifest adds outcomes.
The generic structural scanner finds the weighted-step sequence at `020200e4`
without game addresses. Ten initial scanner checks and a follow-up carry-flag
encoding check pass. Detection establishes neither middleware identity nor
safe replacement; the table, index, flag and runtime-write proofs are separate.

## Next validation and limits

The bounded Luso source-write ordering is now established. Do not repeat
unchanged broad audio replays or the resolved writer trace. High-level buffer
ownership, display-effect write causality around the three changed scanlines,
and complete RAM semantics remain open before any acceptance proposal.
Preserve the user's positive visual review. The decoder's live PCM dependency
is now established, and its first arithmetic candidate has a measured software
result. Broader software-only Fire/library characterization and classification
of its RAM/audio differences are next; keep both timing candidates disabled.
Keep the current acceptance budget unchanged. A proposal
to accept timing differences requires a complete, explicitly reviewed result;
this milestone does not approve such a proposal. The 0.636–1.041% instruction
reduction warrants a high bar for accepting risk or adding complexity.

Establish decoder input-content recurrence and classify remaining ARM7
hotspots. More vertex arithmetic remains a lead,
but do not repeat rejected versions or reinterpret the budget silently.
For any later candidate, complete replay comparison precedes cold boot,
in-game save/reload, reset, overlay transitions, an unrelated scene and paired
native measurement. Ask before accepting non-bit-exactness.

The retained rc12 runtime's observed diagnostic header words 24/25 were zero,
not the required ARM9 sampler tag. Native guest-PC sampling is therefore not
available through that retained interface. Do not silently rebuild RTL.
Persistent core save states are unsupported; ordinary game saves do not prove
save-state round trips. No original ROM or save was changed by this work.

## Three further ideas, not yet tested

1. Establish decoder source-content recurrence, including predictor state,
   before proposing reuse; broaden qualification of the arithmetic candidate.
2. Classify ARM7's remaining sampled audio/service loops and their cross-CPU
   dependencies; a CPU address window alone is not a function identity.
3. Trace repeated cartridge sectors and filesystem lookups before proposing
   reuse; preserve data-ready, completion, destination and invalidation behavior.
