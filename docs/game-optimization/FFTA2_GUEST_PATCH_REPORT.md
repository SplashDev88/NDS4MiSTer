# FFTA2 guest-code optimization — 27 October 2026

Status: the user reviewed the separate vertex and decoder comparison videos
and reported, "No difference in either one." This is positive perceptual
evidence for the shown scenes. Both candidates proceed to individual native
experiments; full-game acceptance and native speed remain unqualified.
Four guest-patch versions fail the original bit-exact budget and remain
disabled in the release manifest. The dispatch candidate passes 1,520 synthetic
cases and reduces selected library ARM9 instructions by 0.713%, but the full
30,000-frame replay changes one bottom-screen frame, audio and RAM. Saves
match. No native gain is measured. The earlier copy, vertex and decoder
results remain below; user-authorized timing investigation did not authorize
non-bit-exact acceptance. Accepted FFTA2 Beta2 remains unchanged. Platinum is
queued, not active. The native diagnostic loader now reuses the existing
reset-held ROM transaction with explicit manifest/hash/patch selection. Its
control, vertex and decoder output hashes match the retained replay images;
no candidate instruction bytes or original ROM files changed. The unchanged
Beta2 renderer and rc12 bitstream remain the proposed native comparison base.

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
also retained; their hot windows are classified in the later section below.
Full disassembly,
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
original investigation used only the replay loader; the later opt-in native
loader does not by itself qualify this rejected copy candidate.

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

ITCM and shared WRAM remain exact. Luso audio RMS delta is 0.797 in signed-16 units;
this is not an audibility judgment. The unpatched control reproduces the
goldens exactly. The patched replay fails the strict RAM/audio gate and the
manifest remains disabled. Native qualification is pending;
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

### Broader decoder replay coverage

The Fire control reproduces the golden replay exactly. The candidate reduces
selected ARM9 instructions from 543,588,049 to 530,006,396, or 2.4985%, but
1,892 of 9,000 bottom-screen hashes differ. All top-screen and save hashes
match. Main RAM, DTCM and ARM7 WRAM differ in 6,826, 7,005 and 5,281 frames;
ITCM/shared WRAM remain exact. The retained main-RAM checkpoint differs only
at the previously classified live elapsed-time words `02132e8c`/`02132e94`.
These words remain unmasked and this does not classify the transient RAM.

Of the 1,892 changed bottom frames, 1,514 match the control one frame earlier.
Another 376 have no identical control hash within three frames in either
direction. These counts retain the same-frame failure; nearby-frame matching
is a diagnostic, not acceptance or a complete timing explanation. Captured
frame 7080 differs in 385 character pixels; frame 7680 differs in 43,316
bottom-screen pixels with maximum color-channel delta 9 during the spell
effect. The first changed bottom frame is 2678, the last 8991.

Fire audio differs in 132,737 of 7,220,926 stereo samples, with RMS delta
777.362 in signed-16 units and maximum delta 65,535. Four output samples have
that maximum, at frames 7623–7624: a stereo output channel goes from positive to
negative clipping limits between arms. This is not the small Luso bound and
is not declared benign. The full audio length is unchanged; six frames
distribute a different number of output samples. The watched table/literal
bytes again have 108 identical initialization stores and no later writes.

Private receipts are `GUEST_NIBBLE_PAIR_FIRE_V1.json`,
`GUEST_NIBBLE_FIRE_CAPTURE_DIFFERENCES_V1.json`,
`GUEST_NIBBLE_FIRE_NEIGHBOR_HASH_V1.json` and
`GUEST_NIBBLE_FIRE_AUDIO_WINDOWS_V1.json`. Three-second original/candidate WAV
excerpts preserve the same absolute sample interval without gain adjustment
or alignment; `GUEST_NIBBLE_FIRE_AUDIO_CLIPS_V1.json` records them. Listening
has not been assessed. The completed source/decoded/control trace is recorded
under `GUEST_NIBBLE_FIRE_AUDIO_PLAN_V1.json` and detailed below.

The library/forest candidate passes all 30,000 frames on both screens,
24,069,760 stereo audio samples, all save hashes and all checked RAM after
normalizing only the declared 200 instruction bytes. Its control is also exact.
Selected ARM9 instruction totals remain 750,160,463 in both arms: this is
outside-target regression coverage, not a speed gain. Table/literal writes
are unchanged, with no writes after initialization. The route includes the
library transition and forest dialogue; it is not a pure FMV replay.

| Route | Selected ARM9 instructions before → after | Reduction | Different top / bottom frames | Different stereo samples | Strict result |
|---|---:|---:|---:|---:|---|
| Luso, 4,400 frames | 391,329,973 → 381,498,749 | 2.5123% | 0 / 0 | 7,694 / 3,530,229 | RAM/audio fail |
| Fire, 9,000 frames | 543,588,049 → 530,006,396 | 2.4985% | 0 / 1,892 | 132,737 / 7,220,926 | Screens/RAM/audio fail |
| Library/forest, 30,000 frames | 750,160,463 → 750,160,463 | 0% | 0 / 0 | 0 / 24,069,760 | Pass within replay scope |

These are software instruction counts, not native cycles, pacing or FPS.
Every save hash matches in all three routes. No native candidate measurement
or full-game qualification is claimed. `GUEST_NIBBLE_PAIR_LIBRARY_V1.json`
retains the outside-target result; earlier Luso evidence remains immutable.

The Fire sound trace reproduces the candidate's earlier outputs and selected
instruction totals exactly. Its retained V5 control has identical semantic
outputs to the new unpatched V6 control, and both builds use the same
instrumented SPU object. All 4,826,361 fetched source words, 13,939,336 decoded
steps, 364 note-start parameter sets and 21,251 sound-register payloads match.
There are no unmatched source/decoder tails. This candidate has no observed
Fire sample-data corruption in that comparison.

Fourteen note starts move: one by −2 callbacks, one by +682, five by −171,
five by +511 and two by +512. In total 363 control writes cross a different
mix-callback boundary, with bounds ±682 callbacks (approximately 20.84 ms in
this reference). PCM stream channels 0/1 retain identical source words,
decoded values and sample-fetch mix indices; their changed outputs come from
control timing. Other active channels also select identical sample sequences
at different times. The existing arithmetic explainer accounts exactly for
all 78,721,488 captured channel-output records per arm, with zero unexplained.
This explains the sound-side output difference; upstream game-event/visual
scheduling, native behavior and listening remain unqualified. It is neither
the vertex patch's mechanism nor a proposed global tolerance. Evidence is
`GUEST_NIBBLE_FIRE_AUDIO_FINDINGS_V1.json` and
`GUEST_NIBBLE_AUDIO_FIRE_V1_{SAMPLES,EVENTS,EXPLANATION}.json`.

Luso is different. Its own traced candidate reproduces the earlier replay,
and all 20,403 sound-register payloads and 311 note-start parameters match,
with no changed note-start times. However, three of 2,291,193 source words
differ at channel 6, generation 23, callback 1,450,863. They change 1,182 of
8,760,071 decoded values. No unmatched tails remain. All 38,457,840 captured
channel outputs per arm are explained from the observed samples and controls,
which does not make the changed source data equivalent.

A new writer trace for this decoder candidate, rather than reuse of the
vertex candidate's conclusion, identifies the same ARM9 cartridge store at
`02010180`, with DMA inactive. All 17,272 ordered write payloads match, and
each of 9,959 sound reads per arm agrees with preceding observed stores.
The three writes at `02172f90/94/98` occur 15,605 raw ARM9 timestamp ticks
earlier, moving from after to before the corresponding sound fetches. Channel
6 is still enabled at volume 3/128 and stops 480 callbacks later. This
establishes the bounded software overwrite ordering; high-level buffer
ownership and native interleaving remain unqualified. See
`GUEST_NIBBLE_RAM_WRITER_FINDINGS_LUSO_V1.json`,
`GUEST_NIBBLE_RAM_CANDIDATE_AUDIT_LUSO_V1.json` and
`GUEST_NIBBLE_AUDIO_LUSO_V1_{SAMPLES,EVENTS,EXPLANATION}.json`.

This version is rejected under the current budget and stays disabled. Its
arithmetic proof and measured instruction reduction remain useful evidence,
but neither overrides whole-replay differences. Do not repeat the completed
three-route or source/writer traces without a new question.

## Remaining hotspot classification and dispatch evidence

The next pass verifies the six retained profile hashes against
`GUEST_PATCH_HOTSPOT_REVIEW.json` and the original ROM identity. Every sampled
opcode within the mapped main/autoload sections matches the image bytes.
Unmapped BIOS/overlay addresses remain explicitly unresolved. All sampled
instructions in the reviewed hot windows are full ARM opcodes; the observer's
Thumb path fetches 16-bit instructions. No Thumb or overlay patch is inferred.

ARM7 starts with 488 bytes at `02380000`, then autoloads 62,340 bytes at
`037f8000` and 96,340 bytes at `027e0000`. The first extent crosses from shared
WRAM into private ARM7 WRAM at `03800000`; `027e0000` is a main-RAM alias for
ARM7, not ARM9 DTCM. Retained checkpoint bytes confirm the shared-WRAM image
and sampled private-WRAM instructions. Seven initialized private-WRAM data
words have changed, so the whole initialized section is not immutable.
See `GUEST_REMAINING_HOTSPOT_MAP_V1.json` and the completed classification
receipt `GUEST_REMAINING_HOTSPOT_FINDINGS_V1.json`.

All 20 ARM7 address windows exceeding 2% in at least one retained route now
have a structural classification. These describe observed code, not official
SDK symbols or safe patches:

| ARM7 window(s) | Observed role and evidence |
| --- | --- |
| `037fb400`, `037fb500` | Interrupt dispatch and scheduler/context return: IE/IF/IME access, handler pointer table, CPSR/SPSR and register saves. |
| `037fb900` | Interrupt enable/disable/acknowledgement helpers accessing `04000208/210/214`; no hot initialization polling loop. |
| `037fbe00`, `037fc300` | Runnable-thread list traversal and scheduling using record state at `+48` and links at `+4c`. |
| `037fd100`, `037fd200` | Extended timer read and alarm programming; timer-0 read, pending-overflow correction, timer-1 control writes. |
| `037fd300`, `037fd600` | Periodic deadline arithmetic, timer alarm queue and callback dispatch. |
| `037fdc00` | CPSR interrupt-disable and restore helpers, not dead work. |
| `037feb00`, `03801c00` | Sound-channel active-bit reads and publication of a 16-channel status mask plus capture status. |
| `037ff100`, `037ff300` | Two 16-channel dirty-state scans and channel parameter update; writes include sound start bits. |
| `037fff00`, `03800000`, `03800a00` | Nested sound sequence/track record scans and indexed track lookup. Semantic names are inferred from their audio consumers. |
| `03800b00`, `03800c00` | Audio parameter arithmetic, linked channel updates and the next track-processing loop. |
| `03806c00` | Unrolled software division steps; operand distribution and an appropriate replacement remain unproven. |

The older top-15 listing omitted `037fb900`, which exceeds 2% in all three
routes. The new review computes the threshold from the full profiles. No
service call is removed, and no ARM7 patch is added. The diagnostic patch
loader currently admits only initially loaded ARM9 main code; ARM7 autoload
patching would need explicit generic lifecycle support and qualification.

ARM9 window `0208b000` contains several functions. The bounded signed-16
rectangle/viewport predicate at `0208b0bc..0208b123` uses 256-by-192 bounds and
has three static call sites, including the known vertex-submission path.
Its input recurrence and safe reuse are not established. Another function,
`0203c094..0203c0d7`, searches key/handler tables and invokes the first match.

| ARM9 function | Luso instruction sample share | Fire | Library |
| --- | ---: | ---: | ---: |
| Rectangle predicate | 2.690% | 2.693% | 4.837% |
| Key/handler dispatcher | 0.180% | 0.003% | 5.025% |

These are software instruction-entry samples, including predicated entries,
not native cycle or frame-time shares. Native gain remains unmeasured.

The unpatched dispatch trace watches function entry and successful match sites
in library frames 23,300–29,999, and all writes to five statically identified
tables across all 30,000 frames. It reproduces every golden screen, RAM state,
audio sample and save; both PC profile files also remain identical. There are
73,667 entries, 33,485 successes and 40,182 misses. All observed successful
positions agree with the original tables. Eleven table/key pairs repeat
6,697 times each. Keys `0x10` and `0x3` miss three tables before reaching the
base table; keys `0x16f`, `0x194` and `0x124` match the 138-entry table.
This is fallback dispatch, not a loop whose calls can simply be dropped.

All 660 table-word stores occur at boot with the original values; there are
no later writes. Both added RAM checkpoints retain the exact five tables.
The observed inputs imply 5,384,388 original key comparisons, without claiming
any reduction yet. `GUEST_DISPATCH_FINDINGS_LIBRARY_V1.json` records the trace,
and `GUEST_DISPATCH_PATTERN_CHECKS_V1.json` records detector admission checks.
This classification led to the guarded compaction candidate below. A larger
range-rejection or indexed search remains unimplemented; it needs additional
space/state proof and cannot inherit this candidate's equivalence result.

## Fourth candidate: postindexed dispatch search

`dispatch-postindex-search` replaces the same 68-byte ARM9 main-code extent
at `0203c094`. The key load advances the table pointer by eight bytes; on a
match the handler pointer is loaded at offset minus four. This removes the
separate pointer increment on a miss. The `BLX` stays at `0203c0b4`, preserving
the link value visible to handlers and their stack saves. Loop-test and exit
branches are retargeted inside the same extent. There is no scratch, overlay,
new HPS service or RTL change. Exact instruction bytes, identity and five
table guards are in the manifest; the patch is individually disabled.

The generic `check_dispatch_patch.py` passes 1,520 cases covering signed and
empty counts, first/middle/last hits, misses, unsorted and duplicate keys,
all initial NZCV combinations, ARM/Thumb handlers and caller returns. An ARM
handler saves its complete entry state, changes flags/registers and writes
data. Final registers, CPSR, data/stack bytes and ordered reads/writes match.
A 138-entry miss falls from 974 to 836 instructions with the same 142 data
accesses. Thirteen loading/admission checks pass, including all five table
mismatch guards. Synthetic execution does not model interrupts or native
cycle timing.

The unchanged V6 oracle and preceding exact unpatched library trace are
reused. `summarize_guest_pair.py` now permits such reuse only explicitly and
after checking original-stream identity, game identity, oracle, replay job,
golden outputs and retained output hashes. Eight negative reuse checks reject
changed evidence before producing a result; the promoted tool also reproduces
the earlier decoder comparison's semantic results.

| Library measure | Unpatched | Candidate |
| --- | ---: | ---: |
| ARM9 instruction entries, frames 23300–29999 | 750,160,463 | 744,808,170 (−0.713486%) |
| Changed top-screen frames | 0 | 0 / 30,000 |
| Changed bottom-screen frames | 0 | 1 / 30,000, at frame 23878 |
| Changed stereo samples | 0 | 405,899 / 24,069,760 |
| Maximum signed-16 audio delta | 0 | 4,025 |
| Main-RAM differing frames, excluding only the patch bytes | 0 | 21,738 |
| DTCM / ARM7-WRAM differing frames | 0 / 0 | 1,704 / 875 |
| Save data | Exact | Exact, every frame and final |
| Native frame time, pacing, HPS load and speed gain | Unavailable | Unavailable |

All 660 watched table-word stores are identical boot stores in both arms;
none occurs later. The ordinary frame-2600 main-RAM checkpoint is exact after
only 68 code bytes are normalized. Added checkpoints at 23300 and 29999 have
two changed words at the previously identified elapsed-time locations
`02132e8c/94` (minus six and minus seven raw values respectively); their other
tracked RAM regions match. This does not explain or erase the intervening
RAM differences. Audio-source identity and audibility were not qualified for
this candidate, so its audio differences are not classified as harmless phase.

See `GUEST_DISPATCH_PAIR_LIBRARY_V1.json`,
`GUEST_DISPATCH_CHECKPOINTS_LIBRARY_V1.json` and
`GUEST_DISPATCH_BEFORE_AFTER_LIBRARY_V1.csv`. This version is rejected under
the current budget. No further battle, lifecycle or native trials are run for
the failed version, and no beta is produced. Continue with input-recurrence
evidence for the remaining guest-code leads, rather than repeating these
unchanged timing comparisons.

## Decoder content recurrence: no reuse in the Luso route

A read-only extension of the existing replay instruction observer captures
128 compressed bytes and the complete eight-byte predictor/index state at
ARM9 ARM `0x02020080`, with an exact opcode/mode guard and R2=256 guard.
At `0x02020144`, before the final POP, it captures all 512 output bytes and
the updated eight-byte state. Pairing verifies input/output pointer advances,
the 40-byte stack frame and the unchanged state pointer. LR is still the
negative clamp constant at this site; the POP subsequently restores it.

The fresh unpatched V7 observer passes every golden screen, RAM, audio and
save comparison over 4,400 frames. Its selected-window ARM9/ARM7 instruction
totals remain exactly 391,329,973 / 21,412,319. The new observer copies host
backing RAM only after checking the canonical mapping and excluding TCM;
it makes no emulated reads, guest writes, HPS service calls or RTL changes.

| Capture scope | Calls | Unique 128-byte inputs | Unique full keys | Reuse hits |
| --- | ---: | ---: | ---: | ---: |
| Full Luso route | 12,456 | 12,456 | 12,456 | 0 |
| Frames 2600–4399 | 7,696 | 7,696 | 7,696 | 0 |

Only eight source addresses are used, but every compressed block is different.
Keys compare actual bytes plus predictor/index and sample count. Even an
unbounded cache has no hits in this trace. Storing all observed keys and
outputs would require 8,220,960 payload bytes before metadata and alignment,
with no saved decode work. Do not implement a whole-block cache for this
workload. This does not rule out other scenes, assets or smaller operations.

Evidence: private `GUEST_NIBBLE_CONTENT_RECURRENCE_LUSO_V1.json`,
`GUEST_NIBBLE_RECURRENCE_LUSO_V1_STATUS.json` and
`GUEST_MEMORY_WATCH_BUILD_V7.json`. The generic observer passes 39 guard/mapping
checks; the analyzer additionally tests predictor-state identity, output
conflicts and six invalid call pairings. No guest patch was added or enabled,
and no native performance improvement is claimed.

## Rectangle predicate recurrence: a bounded reuse lead

The predicate at ARM9 ARM `0x0208b0bc..0x0208b120` compares two four-element
signed-halfword inputs. The first supplies translation through elements 0–2
and 1–3; the second supplies rectangle bounds. It returns true when the
rectangle overlaps the translated 256×192 viewport. Its three identified
callers use that result to decide whether to submit graphics work. It is not
dead work. The function writes only its eight-byte stack frame, but it also
changes temporary registers, flags and execution timing.

The existing observer now supports explicitly mapped ARM9 DTCM, needed for
the second input on the caller's stack. It does not reinterpret DTCM as main
RAM. The V8 trace captures both complete eight-byte inputs at entry and the
saved entry registers at all four return sites. Conditional POP observations
are paired only when their CPSR condition passes. Every return matches the
disassembled visibility formula and its saved R3/LR and stack-pointer guards.

The fresh unpatched 30,000-frame library replay remains exact for both
screens, all recorded RAM regions, audio and saves. Selected ARM9/ARM7
instruction totals remain 750,160,463 / 99,771,446. Input capture is deliberately
limited to frames 23300–23419; it does not establish full-route recurrence.

| Bounded capture result | Value |
| --- | ---: |
| Predicate calls | 21,600; 180 per frame |
| Unique complete 16-byte inputs | 171 |
| Repeated keys with the same boolean output | 21,429; 99.208% |
| Repeated keys with different outputs | 0 |
| Immediately repeated keys | 0 |
| Hypothetical LRU hits, 128 entries | 1,199 |
| Hypothetical LRU hits, 256 entries | 21,429 |
| Visible / rejected calls | 17,160 / 4,440 |

All calls in this window return to `0x0208ccc8`. The first input is constant;
the second has 171 distinct contents. There is only one pointer pair, and it
produces both return values: a pointer-only cache would be wrong. Reuse is
mostly on the next frame: 20,349 hits cross frames, 1,080 occur within a frame,
and the median reuse distance is 180 calls. The 171 unique key/result payloads
alone need 3,420 bytes; 256 entries need 5,120 before metadata or any additional
state required for exact replacement. No unused storage has been established.

The observed paths imply 524,760 instruction entries and 166,320 halfword
input reads in this 120-frame capture. Those are derived work counts, not
cycles, saved work or native speed. A cache must still pay for lookup and
maintain complete dependencies, clobbers, stack visibility and timing.

Evidence: `GUEST_RECTANGLE_CONTENT_RECURRENCE_LIBRARY_V1.json`,
`GUEST_RECTANGLE_SEMANTIC_FINDINGS_LIBRARY_V1.json`,
`GUEST_RECTANGLE_STATIC_CONTRACT_V1.json` and the V8 build/replay receipts.
The observer passes 50 mapping/guard checks. Four analyzer tests cover the
prior recurrence cases, all 240 supported ARM-condition/flag combinations,
conditional returns, saved-register guards and bounded capture. Prior decoder
analysis is unchanged. No guest patch or native service was added.

## Moving-scene rectangle coverage and lookup budget

Reference captures were visually reviewed before selecting Luso frames
3000–3359 (destination selection, unit movement and map-view shift) and Fire
frames 7440–7799 (target confirmation, camera reframing and spell hit).
The same pinned V8 observer passes the complete unpatched 4,400-frame Luso
and 9,000-frame Fire golden comparisons: both screens, all RAM hashes, audio
and saves. Their selected ARM9/ARM7 instruction totals are unchanged at
391,329,973 / 21,412,319 and 543,588,049 / 29,444,346 respectively.

| Bounded capture | Calls | Unique complete inputs | Unlimited reuse | LRU 256 hits | LRU 512 hits |
| --- | ---: | ---: | ---: | ---: | ---: |
| Library, 120 frames | 21,600 | 171 | 99.208% | 21,429 | 21,429 |
| Luso movement, 360 frames | 88,710 | 4,497 | 94.931% | 56,583 | 84,213 |
| Fire action, 360 frames | 83,102 | 12,228 | 85.286% | 68,534 | 68,768 |

Every return matches the signed-halfword visibility formula, with no
conflicting result for an identical complete key. Luso covers 19 viewport
translations; Fire covers 51 translations from 52 distinct first-input
records. Both observe callers `0x0208ccc4` and `0x0208e2a0`; `0x0208cfc0`
remains unobserved in these bounded traces. A single pointer pair still
produces changing inputs and both boolean values, so pointers cannot be keys.

The second caller supplies its rectangle at an address congruent to 2 mod 4:
3,915 Luso and 80 Fire calls. A proposed fast path must preserve ARM9 unaligned
load semantics or use a guarded fallback. Do not replace halfword loads with
aligned word loads indiscriminately. Nine Luso and fourteen Fire calls cross
an emulator frame boundary; complete entry/exit and saved-register pairing
remain valid. The private semantic analyzer now records that fact rather
than imposing the earlier library-only same-frame assumption. All prior
library measurements remain unchanged.

An optimistic instruction-entry budget retains only the original PUSH/POP
on a cache hit and treats all other original predicate entries as removable.
With hypothetical 512-entry LRU hit counts, the average budget for **all**
extra lookup, preservation, insertion and invalidation work is 22.119 entries
per call in Library, 21.663 in Luso and 18.841 in Fire just to break even.
At 256 entries, Luso's budget drops to 14.469. This model charges no LRU
maintenance or memory-cycle cost yet; it is a preflight ceiling, not a speed
measurement or proof that a real lookup can achieve those hits.

A 512-entry key/boolean payload alone takes 10,240 bytes, before indexing,
validity or additional state. No guest storage has been allocated or proven
unused. The next step is an isolated lookup-cost/semantics prototype using
these actual traces. Only a useful result would justify storage/write-watch
work and a guarded patch; native timing and lifecycle qualification remain
mandatory. No new guest patch or beta is produced.

Evidence: `GUEST_RECTANGLE_SEMANTIC_FINDINGS_{LUSO,FIRE}_V1.json`,
`GUEST_RECTANGLE_CONTENT_RECURRENCE_{LUSO,FIRE}_V1.json`,
`GUEST_RECTANGLE_INPUT_ALIGNMENT_V1.json`,
`GUEST_RECTANGLE_LOOKUP_COST_BUDGET_V1.json`, and
`GUEST_RECTANGLE_DYNAMIC_SCENE_SELECTION_V1.json`.

## Concrete rectangle-cache lookup: rejected at cost preflight

An isolated ARMv5 complete-key lookup was assembled for the existing Unicorn
runner. It uses a 512-slot direct-mapped table, exact comparison of all four
key words, a validity word, boolean payload and alignment fallback. The
32-byte slot occupies 16,384 synthetic test bytes for the whole table. These
addresses exist only in the test VM; no game storage was allocated or patched.
The component uses the original-shaped eight-byte PUSH/POP frame and preserves
R3–R11/SP, but does not implement miss insertion or full volatile/flag/return
integration. It is not a complete or equivalent game patch.

The 608 component cases cover each word's deliberate hash collision, zero and
random keys, cold/invalid entries, both boolean values, all NZCV states,
ARM/Thumb returns and unsupported alignment without input/table reads.
Separately, 640 cases measure the original predicate's five return outcomes
and both halfword alignments. The lookup hit takes **26 instruction entries
and 60 data-access bytes**. The original takes **11–26 entries and 26–32
data-access bytes**. Cold lookup costs 17 entries, collision misses 26 and
alignment rejection 6, before integration with the original calculation.

Replaying the actual keys through this hash gives much fewer hits than the
hypothetical associative LRU. The deliberately optimistic integration model
credits the original PUSH and removes the lookup's miss-return tail, while
charging nothing for restoring inputs, insertion/eviction, invalidation or
additional state preservation:

| Capture | Actual direct-mapped hits | Original entries | Optimistic integrated entries | Increase |
| --- | ---: | ---: | ---: | ---: |
| Library | 4,285 / 21,600 | 524,760 | 929,881 | 77.201% |
| Luso movement | 11,283 / 88,710 | 2,202,432 | 3,926,167 | 78.265% |
| Fire action | 9,624 / 83,102 | 2,059,250 | 3,765,380 | 82.852% |

Even an artificial perfect-hit assumption for all aligned inputs leaves this
lookup with no per-call instruction-entry improvement: its hit path equals
the original's longest path and exceeds the shorter paths. Every alignment
fallback adds overhead. Changing the hash alone cannot create instruction
headroom for this implementation. These are component measurements and
derived counts, not native timing or a measured whole-game slowdown.

Reject this lookup design before scratch investigation or an in-game patch.
It does not establish that every possible cache or higher-level hoist is
impossible, but repeated input content alone is insufficient justification.
The next active lead is cartridge/filesystem recurrence and redundant work,
reusing existing tracing. No new native test or beta is warranted here.

Evidence: `GUEST_BOOLEAN_CACHE_LOOKUP_BUILD_V1.json`,
`GUEST_BOOLEAN_CACHE_LOOKUP_SYNTHETIC_V1.json`,
`GUEST_RECTANGLE_REFERENCE_COST_SYNTHETIC_V1.json`, and
`GUEST_RECTANGLE_CACHE_COST_{LIBRARY,LUSO,FIRE}_V2.json`.
Four accounting tests cover eviction/collision/hit ordering, alignment
fallback without insertion, conflicting results and capture-window bounds.
The V2 model retains every prior measured field and adds a perfect-hit bound.

## User-requested individual video previews

The user explicitly requested trying the retained vertex-packing and decoder
arithmetic candidates and recording each for visual/audio review. The patches
were selected individually through the existing guarded VirtualRom loader;
no combined patch, native installation or release acceptance is implied.
Both remain disabled in the release manifest and accepted Beta2 is unchanged.

The diagnostic V9 frontend copies completed full-resolution framebuffers and
indexes the existing stereo output for declared windows. The original ROM
and seed files remain untouched. Eight fresh full replays cover 100,200 frames:
control, vertex and decoder in Luso and Fire, plus control and vertex through
the longer story/library route. Every recording reproduces its retained
screen, RAM, audio, save and immutable image results, including the previously
measured candidate failures. This validates the recorder's lack of observed
perturbation; it does not convert those failures into passes.

The comparisons show both DS screens side by side and repeat each scene with
control audio followed by candidate audio. Presentation timestamps follow the
original 48 kHz sample counts. The finished vertex sequence is 84.244125 seconds
and the decoder sequence 76.220958 seconds. Coverage includes the quiet Luso
sound-buffer boundary, the Fire spell and largest measured decoder audio
difference, the story route's largest vertex audio difference, and both tiny
library transition scanlines. Lossless stills reproduce the known vertex
bounds: 51 pixels with a maximum channel delta of 4 at Fire frame 7640, and
231/135 pixels with maximum delta 9 at library frames 23878/23885.

The MOV master retains original signed-16 stereo PCM without gain changes,
filtering, mixing or resampling. The encoder verifies the decoded PCM hash,
every video presentation timestamp and the decoded frame count. The picture
uses H.264 after exact 2x nearest-neighbor scaling; original raw captures and
lossless PNG stills remain available. MP4 convenience copies retain the same
encoded video and use AAC audio. These are software replay recordings, not
MiSTer capture-card footage or measured native speed improvements.

Evidence: `GUEST_VIDEO_BUILD_V9.json`, `GUEST_VIDEO_REVIEW_BATCH_V1.json`,
`GUEST_VIDEO_MEDIA_CHECKS_V1.json`, `GUEST_VIDEO_REVIEW_BEFORE_AFTER_V1.csv`,
and the video render receipts. The generic capture has 17 unit checks; the
pixel verifier rejects an intentionally changed source bit. The private review
files are under `reviews/FFTA2_Guest_Patches_20261027` in the main workspace.
Human review remains separate from an explicit acceptance-budget decision.

Deferred from this recording request: native integration/performance and full
lifecycle qualification; interactions between the two patches; and the paused
cartridge/filesystem content-reuse audit. No hardware ownership was requested
or changed for these local recordings.

## Next validation and limits

The bounded Luso source-write ordering is now established. Do not repeat
unchanged broad audio replays or the resolved writer trace. High-level buffer
ownership, display-effect write causality around the three changed scanlines,
and complete RAM semantics remain open before any acceptance proposal.
Preserve the user's positive visual review. The decoder's live PCM dependency
is now established, and its first arithmetic candidate has a measured software
result. Three-route software characterization, Fire's sound-side timing and
Luso's source-write ordering are complete. Keep both timing candidates disabled.
Further work on their visual/RAM semantics is deferred while content-reuse
opportunities are investigated. ARM7's hot windows now have structural roles.
Keep the current acceptance budget unchanged. A proposal
to accept timing differences requires a complete, explicitly reviewed result;
this milestone does not approve such a proposal. The 0.636–1.041% instruction
reduction warrants a high bar for accepting risk or adding complexity.

Decoder whole-block recurrence has now been measured and has zero hits in
Luso. Rectangle recurrence covers bounded library, movement and spell scenes,
but the concrete complete-key cache lookup fails the instruction-entry cost
preflight. Do not allocate storage or repeat this design unchanged. A third
caller and broader lifecycle states remain unqualified for any future design.
ARM7's hot windows have structural
classifications, but dynamic caller/operand and dependency evidence is still
needed before any service optimization. More vertex arithmetic remains a lead,
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

1. Measure cartridge/filesystem recurrence, metadata work and buffer ownership;
   repeated buffer addresses or source offsets alone do not authorize skipping I/O.
2. Consider higher-level reuse of viewport calculations only if it removes
   lookup costs and has a proven mutation boundary; do not revive this cache.
3. A larger dispatch index or ARM7 division specialization needs its own
   operand/cost and storage/timing proof. Both remain unqualified leads.
