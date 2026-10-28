# Pokémon Platinum guest-code optimization — 27 October 2026

Platinum became the sole active target when the user explicitly advanced from
FFT due diminishing returns. Use exact rc12 with cumulative accepted changes;
preserve the earlier player-character and furniture fixes. Historical PBOX
binaries, timings and room screenshots are context, not the current baseline.
The word-stream candidate is rejected and disabled. Two overlay leads now have
guarded runtime evidence; no new speed gain is claimed.

The owned local ROM is USA CPUE revision 1, 128 MiB, SHA-256
`fbce4c4def0c7797f8dd238a3d7a5e48b4a7e3abd86890ac65f6321cef781bdb`.
The guarded patch manifest is `platinum-cpue-r1.json`. Original ROM and saves
remain untouched. The earlier hardware-created room save loads successfully.
The original backup is entirely `ff` and contains no saved checkpoint; it is
preserved. A fresh read-only CIFS header inventory finds files reporting CPUJ
revision 0 and CPUE revisions 0, 1 and 10. The filename labelled Europe reports
CPUE revision 10, so its filename cannot establish its identity. Only the fully
hashed local CPUE revision 1 image is admitted to this investigation.

Initial targets are active walking, menus and room transitions, followed by a
battle and intro route as reachable from the seed. Establish a deterministic,
visually verified unpatched replay and fixed RTC behavior before selecting
hotspots or patches. Native expected cadence, gameplay timing, pacing and
audio require current measurements; instruction samples and buffer publication
counts cannot substitute for those measurements. Intro visuals are not assumed
to be FMV assets without inspection.

Reuse `tools/game_optimization/replay_oracle.cpp`, the existing generic
profilers/scanners and `prepare.VirtualRom`/`hook_guard.py`. There are 122
ARM9 overlays and no ARM7 overlays in this image. A patch in an overlay needs
its ID, exact content identity and a verified reload mechanism; a reused RAM
address is insufficient. Persistent core save states remain unsupported.

The existing ARM structural scanner completed read-only main/autoload
screening. It flags the known branch-heavy halfword-copy shape at ARM9
`020c4b18` and ARM7 `037fb040`. The new selected-window profile samples the
ARM9 extent 41,067 times (4.230% of ARM9 samples), and the ARM7 extent zero
times. These are not safe patch sites merely because a detector matches. The
analogous FFT rewrite failed whole-game exactness; do not transplant it on
signature similarity alone. This scan excludes Thumb code and overlays and
establishes no shared SDK identity.

## Bounded reference baseline

`ROOM_ROUTE_V4` and its independent repeat each run 6,000 frames from the
same private seed, fixed RTC, input file and pinned existing reference oracle.
The existing comparator passes both screens, RAM hashes, audio, save and RAM
dumps. A supplemental audit matches all 100 output files, including both PC
profiles, actual periodic screen captures and five full memory/CPU checkpoints
at frames 4200, 4440, 5000, 5300 and 5900. No patch is active. The save remains
identical to its private seed; this is not a save-write/reload test.

Visual review identifies boot, Continue, the opening rival dialogue, menu
opening/dismissal and bedroom movement. The first attempted movement route
became blocked in dialogue and is not a gameplay performance control. Later
stair approaches remain in the bedroom: no room transition is qualified.
The profile covers frames 4200–5999, after dialogue, and includes menu,
movement and stationary room time. It is not a pure walking benchmark or a
native renderer/accuracy qualification.

There are 248,802,085 ARM9 and 45,859,032 ARM7 instruction entries in that
selected window. The 970,952 ARM9 and 178,229 ARM7 samples reconcile exactly
with the observer's every-256th-entry, per-frame sampling rule. They are not
native cycle shares; fixed-stride sampling can alias periodic service work.
`INITIAL_PROFILE_SCREEN_V1.json` retains every 256-byte bin at or above 2%
for both CPUs, including unresolved ARM7 and live-overlay regions.

| ARM9 extent, end exclusive | Sample share | Evidence and interpretation |
|---|---:|---|
| `01ff8000–01ff81e4` | 19.114% | IRQ acknowledgment, dispatch and context switching, including CPSR/SPSR and register preservation; not established idle work |
| `020c99fc–020c9a78` | 9.615% | Register context save/restore around DIV/SQRT MMIO, called by the context path; not evidence of an expensive software divide |
| `020c4b90–020c4bb8` | 5.675% | Reads successive words and writes repeatedly to one destination; the guarded census below identifies geometry FIFO |
| `020c4b18–020c4b4c` | 4.230% | Known halfword-copy pattern; the guarded census below identifies mostly tiny OAM fields |

The listed code bytes match the unpacked ROM at all five live checkpoints.
Static disassembly and existing emulator register definitions support these
bounded interpretations. The transfer census below adds runtime mode guards
and actual arguments; other hotspots still require them. A fixed-destination
word stream must not be treated as ordinary memcpy, nor a large interrupt
sample share as removable dead work.

## Guarded transfer census

The existing observer captures 1,206,700 entry/return events with exact ARM9,
ARM-mode, opcode, pipeline-PC and mapped DTCM-stack guards. Both the preliminary
register census and guarded capture preserve all six required golden outputs.
`audit_transfer_calls.py` pairs all 603,350 calls, checks declared leaf-register
effects, final equal-compare flags and unchanged stack bytes, and binds its
input to that passing comparison. Seven adversarial tests pass. The measured
window remains frames 4200–5999; no new gameplay coverage is implied.

| Routine | Calls | Requested bytes | Actual role in this window |
|---|---:|---:|---|
| Fixed-destination word stream | 160,545 | 8,138,460 | Destination argument is always geometry FIFO `04000400`; 19,800 calls have length zero and perform no transfer |
| Halfword copy | 442,805 | 1,778,456 | 442,800 calls / 1,778,400 bytes target OAM; five calls / 56 bytes target main RAM |

The word stream's 140,745 nonempty calls comprise 36,525 main-RAM sources and
104,220 ARM9 DTCM sources. All observed sources/destinations are word-aligned;
two return sites are `020b2834` and `020b0fd8`. One complete call crosses an
emulator frame boundary and remains in the audit. No call is nested in this
capture. Fixed source addresses or identical lengths do not establish repeated
command payloads.

The halfword routine mostly copies tiny fields: 223,200 six-byte calls and
219,600 two-byte calls. Five other calls use lengths 8, 10, 12 or 16. Many
sources/destinations are 2 mod 4, so replacing these with ordinary aligned word
accesses is not justified. OAM callers return to `020a7ee8`, `020a7f9c`,
`020a7fac`, `020a7fbc` and `020a7fcc`; the five RAM calls return to Thumb
address `0200aeb5`. The routines themselves were observed in ARM mode.

Evidence: `TRANSFER_CALL_FINDINGS_V2.json`,
`TRANSFER_CALL_AUDIT_FIXTURE_V2.json` and
`TRANSFER_GUARDED_V1_COMPARISON.json`. V1 findings retained DTCM sources as
unclassified; V2 labels them using the mapped ARM9 DTCM range without rerunning
or changing the replay. No beta patch or scratch allocation is installed.

## Word-stream branch trial — rejected

`fifo-word-stream-predication` replaces 40 bytes of initial ARM9 ARM code at
`020c4b90`. Predicated LDM/STR instructions retain the ordered source reads and
fixed-destination writes while removing branch scaffolding. It uses no scratch,
overlay hook, new service or RTL. The existing guarded VirtualRom loader admits
the exact CPUE revision 1 header/ROM/raw-ARM9 identity and original bytes;
only 26 byte values change within the declared 40-byte extent. Four negative
admission cases preserve the complete original stream. No ROM file is written.

The existing synthetic runner passes 1,680 cases with identical registers,
CPSR, mapped memory and ordered data accesses, including zero/null calls,
odd lengths, alignment, overlap, signed-address boundaries, wraparound and
ARM/Thumb returns. Synthetic MMIO remains ordinary memory and does not prove
interrupt or native hardware equivalence. The unpatched virtual adapter
reproduces the golden replay before the candidate is run.

| Measurement | Unpatched control | Candidate |
|---|---:|---:|
| Screen pairs | 6,000 | All 6,000 bit-exact |
| Declared full RAM checkpoint sets | 5 | All 5 exact outside 40 patch bytes |
| Additional per-frame main RAM / DTCM / ARM7 WRAM hash differences | 0 / 0 / 0 | 247 / 348 / 107 |
| Stereo samples | 4,813,950 | 175,017 differ; maximum signed-16 delta 2,146 |
| Save data | Original private seed | Bit-exact throughout and at end |
| ARM9 reference entries, frames 4200–5999 | 248,802,085 | 245,648,794 (−1.267%) |
| Native cycles, frame time, pacing and HPS load | Unavailable in this trial | Not run |
| Transition, battle, save-write/reload and reset coverage | Pending | Not run |

Audio mismatch rejects this version under the strict budget, despite identical
screens, saves and fixed RAM checkpoints. The additional transient RAM changes
are unexplained; do not classify the differences as harmless timing or infer
audibility from their maximum alone. The earlier fixed-workload estimate was
4,390,320 fewer entries (1.765%), from `6 * words + 8 * calls` versus
`4 * words + 6 * calls`. The empirical reduction is smaller; neither value is
native speed. Do not repeat this unchanged version, trial it natively or
include it in a beta. FFT's earlier perceptual review does not qualify a new
Platinum soundtrack.

Private trial evidence: `FIFO_WORD_STREAM_SYNTHETIC_V1.json`,
`FIFO_WORD_STREAM_PREFLIGHT_V1.json`, `FIFO_WORD_STREAM_COMPARISON_V1.json`,
`FIFO_WORD_STREAM_BEFORE_AFTER_V1.csv` and `FIFO_WORD_STREAM_DECISION_V1.json`.

Private evidence: `platinum-optimization-20261027/INPUTS_V1.json`,
`STATIC_PATTERN_SCREEN_V1.json`, `ROOM_ROUTE_V4_COMPLETE_REPEAT_AUDIT.json`,
`REPLAY_SCENE_REVIEW_V1.json`, `INITIAL_PROFILE_SCREEN_V1.json`,
`STATIC_ARM9_HOTSPOT_LEADS_V1.txt` and `WORKFLOW.json`. The last verified
cumulative beta remains FFTA2 Beta2 until a Platinum change qualifies.

## Overlay and ARM7 classification

All 30 retained bins now have a structural classification. All 1,021 sampled
instruction sites match the exact ROM main/autoload bytes, checkpoint-matched
overlay bytes or the reference oracle's embedded FreeBIOS. This screens the
executed instructions; it does not establish every function's runtime semantics
or native cost. The ARM7 bins predominantly cover sound-channel arithmetic,
parameter propagation, modulation and status collection, plus timed callbacks,
IRQ/CPSR helpers and SWI dispatch/completion. The pitch and volume helpers call
Thumb SWIs `1b` and `1c`; their actual argument recurrence remains unmeasured.
The channel update already compares values and sets dirty flags on changes.

The owned ROM's full SHA-1 `0862ec35b24de5c7e2dcb88c9eea0873110d755c`
matches the decompilation project's USA revision 1 identity. External source is
pinned to commit `579d2d5c65e736a1a4268fb7acbfd70712177c6c`; no external build
or downloaded ROM was used. Both large overlay bins belong to overlay 5 at
`021d0d80`: its entire 201,632-byte decoded body matches all five checkpoints.
Decoded SHA-256 is
`6e2095b04c6db198d2c16f81964732d5b2119fa66edb907bec3b3774f41d43f9`.
Source names support the matching disassembly, rather than admitting a patch
by address or symbol alone.

The existing observer captured frames 4200–4319 with exact CPU, Thumb mode,
opcode, pipeline-PC and memory mapping guards. All 100 baseline output files
still match across the full 6,000-frame run. The observations are:

| Lead | Unpatched evidence | Patched result |
|---|---|---|
| Resource queue compaction, `021ee030` | All 60 entries have 64 empty records; nested searches read 2,016 later-slot flags per empty invocation | Not implemented; an early exit after the first exhausted search would require 63 such reads in this case |
| HBlank dispatch, `021ef47c` | All 63,120 dispatches, 526 per frame, target the empty `BX LR` routine at `021ef498`; both task slots are unused | Not implemented; real callbacks in other scenes must still execute |
| Both screens, RAM, audio and save | All six golden comparisons and all 100 retained baseline files match | No new patch trial |
| Native speed, pacing and HPS load | Not measured in this investigation | No gain claimed |

The queue routine accounts for 5.816% of ARM9 samples, including 5.447% in
compaction and 5.109% in its inner search. HBlank dispatch and its dummy return
together account for 4.350%. These are overlapping subextents within the queue
routine, not additive savings, and no percentage is a native speed estimate.
The source's [nested compaction loop](https://github.com/pret/pokeplatinum/blob/579d2d5c65e736a1a4268fb7acbfd70712177c6c/src/overlay005/ov5_021ECE40.c#L1552)
and [HBlank system](https://github.com/pret/pokeplatinum/blob/579d2d5c65e736a1a4268fb7acbfd70712177c6c/src/overlay005/hblank_system.c)
correspond to these instruction and data observations.

The initial generic byte-patch path rejected overlays. Investigation of the
existing FMV preparation code found that overlay 5 is already uncompressed:
its 201,632 stored bytes equal its decoded body. It therefore needs no FAT,
compression, file-layout, converter or ITCM-extension change. The implementation
below reuses the existing reader and virtual stream. No new hardware hook,
HPS service or scratch allocation has been introduced.

Evidence: `THRESHOLD_CLASSIFICATION_V1.json`,
`THRESHOLD_PROFILE_OPCODE_AUDIT_V1.json`, `THRESHOLD_SOURCE_PROVENANCE_V1.json`,
`ARM7_CLASSIFICATION_SUPPORT_V1.txt`, `OVERLAY5_GUARDED_FINDINGS_V1.json`,
`OVERLAY5_SAMPLE_EXTENTS_V1.json` and `OVERLAY5_PATCH_DELIVERY_PROPOSAL_V1.json`.

## Unchanged overlay delivery qualification

`prepare.read_overlay` now supplies the shared ID/table/FAT decoder to both
FMV preparation and the existing `guest_byte_patch` loader. Generic overlay
diagnostics require the exact full ROM/header/ARM9 identities, overlay ID,
file ID, RAM base, entire decoded SHA-256 and expected instruction bytes.
They admit only uncompressed, unflagged ARM9 overlays in canonical main RAM.
The original header, FAT and overlay table remain byte-exact. Mismatches fall
back atomically to the original virtual image; each selection remains explicit.

The all-overlay check exposed a limitation in the old unconditional compression
autodetection: uncompressed overlay 62 contains bytes that resemble a compressed
footer. The shared reader now follows the table's compression flag, as the
normal overlay decoder does. All 122 owned overlays match the independent
`ndspy` overlay decoder. A regression test covers the misleading-footer case;
compressed FMV-reader support is also exercised. The selected byte-patch path
continues to reject compressed or flagged overlays.

All 38 loader/preparation/guard tests pass, including the actual disposable
stream-worker protocol, IDs sharing one RAM address, mixed main/overlay atomic
fallback, wrong content/metadata/bytes, protected data, source mutation and
unchanged repeated file reads. The owned-ROM preflight passes one selected
unchanged-overlay case and nine rejection cases, each producing the original
complete 128 MiB SHA-256. The selected `expect == replace` diagnostic then
passes the full 6,000-frame replay: all 100 baseline output files are identical,
with no RAM normalization. No instruction is optimized in this control.

| Measurement | Original baseline | Selected unchanged-overlay control |
|---|---:|---:|
| Complete virtual cartridge | Original SHA-256 | Identical |
| Both-screen pairs | 6,000 | All exact |
| Retained baseline output files | 100 | All exact |
| ARM9 selected reference entries | 248,802,085 | 248,802,085 |
| ARM7 selected reference entries | 45,859,032 | 45,859,032 |
| Instruction byte changes / enabled optimizations | 0 / 0 | 0 / 0 |
| Native speed and changed-code fetch after reload | Not measured here | Not qualified |

An additional 12,000-frame route performs the game's L+R+Start+Select soft
reset at frame 6000, returns through the copyright/intro/Continue screens and
loads the saved bedroom again. Overlay 5's body is still present at checkpoint
6100, differs at 6400 and 7200, then matches all 201,632 bytes at 8400, 10000
and 11500. The selected unchanged-overlay repeat matches all 166 baseline
files. The existing observer records 1,800 post-reset Thumb compaction entries
in frames 8400–11999 with exact opcode/pipeline guards; all have 64 empty
records. Both runs preserve the original 6,000-frame prefix and private save.
This is soft reset and Continue, not a save-write test or core save state.

This qualifies adapter neutrality and a bounded unpatched software reload
route, not the two optimization ideas. Changed-code execution/cache visibility
and native lifecycle/benefit still require candidate-specific evidence.
This stage identified the need for full-overlay RAM comparison and Thumb
synthetic support. Both are qualified below. Existing accepted binaries and
beta packages remain untouched.

Evidence: `OVERLAY_DELIVERY_PREFLIGHT_V2.json`,
`OVERLAY_DELIVERY_TOOL_TESTS_V2.log`, `OVERLAY_DELIVERY_CONTROL_MANIFEST_V1.json`
and `OVERLAY_DELIVERY_CONTROL_V1_STATUS.json`. The failed initial reader check
is retained as `OVERLAY_DELIVERY_PREFLIGHT_V1_FAILED.json`; no replay started
on that failure. The later staircase approach in `ROOM_ROUTE_V5` still remains
upstairs; it does not expand room-transition coverage. Reset evidence is in
`OVERLAY_RESET_SCENE_REVIEW_V1.json`, `OVERLAY_DELIVERY_RESET_FINDINGS_V1.json`
and `OVERLAY_DELIVERY_BEFORE_AFTER_V1.csv`.

## Empty-tail exit trial

The disabled `overlay5-empty-tail-exit` candidate changes six byte values across
five Thumb instructions in a 54-byte extent beginning at `0x021ee0a0`. After
an unsuccessful inner search it advances the outer index to its limit; active
records and successful moves bypass that adjustment. The final reload is
unsigned only after the signed entry test admits a count greater than one.
The capacity must remain immutable during the call. There is no scratch,
trampoline, new service or RTL change.

The existing synthetic runner now supports Thumb and explicitly declared
ordinary-memory read elimination. All 1,338 cases preserve registers, flags,
complete mapped memory, writes and required reads, including exhaustive small
occupancies and larger/random/stale-payload cases. The prior 1,680 ARM cases
still pass. Five Python unit tests and 27 C++ comparison checks pass.
The comparison accepts only a complete original/replacement overlay body before
normalizing declared instruction bytes. Partial, absent or different bodies
remain raw. The new unpatched 6,000/12,000-frame controls match all 100/166
golden files, including profiles. The first control attempt rejected a
byte-reversed return-opcode guard; the corrected specification passes without
relaxing the observer.

There are 900 paired queue entries/returns before reset and 1,800 after reset.
Every observed queue has 64 empty records with identical complete bytes at
return. Full-replay bus watches show the original capacity and records are
initialized at frame 1307, with no subsequent writes through frame 5999.
After reset the queue moves by `0x60`; its last initialization writes occur at
7307, before the observed 8400–11999 window. Live-window writes touch only
the processed-count field and a separate upload flag. Owned-byte disassembly
corroborates the VBlank functions using the other array at header `+0x10`,
instead of the compaction queue at `+0x0c`. This is bounded CPU/DMA evidence,
not proof for arbitrary scenes, native execution or asynchronous host writes.

| Measurement, 6,000-frame trial | Control | Candidate |
|---|---:|---:|
| ARM9 executed reference instructions, frames 4200–5999 | 248,802,085 | 237,158,299 (−4.679939%) |
| ARM7 executed reference instructions, same window | 45,859,032 | 45,859,032 |
| Both-screen pairs matching golden | 6,000 | 6,000 |
| Fixed full RAM checkpoint sets matching golden | 5 | 5, excluding qualified patch bytes |
| Same-length stereo sample count | 4,813,950 | 4,813,950 |
| Stereo samples differing from golden | 0 | 1,660 |
| Maximum signed-16 audio delta | 0 | 312 |
| Save data | Exact | Exact |
| Native cycles / frame time / FPS | Unmeasured | Unmeasured |

Audio RMS delta is 0.148479 across all signed-16 channels, without alignment or
masking. No audibility judgment is established. Audio alone fails the requested
bit-exact budget, so the candidate is rejected and disabled; no optimized reset
or native trial follows. All fixed checkpoints pass, while 246 main-RAM, 250
DTCM and 19 ARM7-WRAM frame hashes differ. Those transient differences remain
diagnostic and are not silently classified as harmless. Reference instruction
reduction is not a MiSTer speedup. ROM and private save inputs remain unchanged.

Evidence: `EMPTY_TAIL_SYNTHETIC_V1.json`, `EMPTY_TAIL_TOOL_TESTS_V1.json`,
`EMPTY_TAIL_WRITER_CONTRACT_V1.json`, `EMPTY_TAIL_RESET_WRITER_CONTRACT_V1.json`,
`EMPTY_TAIL_LIFECYCLE_DISASSEMBLY_V1.json`, `EMPTY_TAIL_COMPARISON_V1.json`,
`EMPTY_TAIL_DECISION_V1.json` and `EMPTY_TAIL_BEFORE_AFTER_V1.csv`.

## HBlank candidate screening

The owned 28-byte dispatcher plus its two-byte dummy return and two-byte
alignment region does not yet have a demonstrated layout for a whole-empty
fast path with a preserved real-callback path. The existing synthetic runner
confirms 25 executed instructions for the two-empty-slot function. A simple
per-slot target load/compare/branch guard adds work around the two-instruction
`BLX`/`BX LR` pair it would skip; sharing a constant changes the calculation
but still needs a layout and machine-state proof. These are instruction counts,
not native cycle estimates, and do not rule out every HBlank optimization.

Checking `used == FALSE` is insufficient. Registration writes parameter,
callback and then `used`; deletion clears `used` before replacing callback
and parameter. The owned sequences contain no IRQ masking, and caller-side
exclusion has not been proved. A synthetic registration snapshot with `used=0`
and a live callback still performs that callback's write. Skipping it changes
behavior. No actual race is claimed to have occurred in the captured scene.
Even the dummy call sets LR to `0x021ef48d`, so deleting it without reproducing
the caller-visible state does not satisfy the current equivalence contract.

No HBlank patch is implemented or enabled. Retain a whole-empty fast path as
a proposal requiring safe code space and complete callback/lifecycle proof;
do not overwrite the neighboring function, assume scratch or disable the whole
interrupt. Evidence: `HBLANK_COST_SCREEN_V1.json`,
`HBLANK_SYNTHETIC_SCREEN_V1.json` and `HBLANK_BEFORE_AFTER_V1.csv`.

## Downstairs and Twinleaf Town reference

`ROOM_ROUTE_V9` now covers the bedroom/menu prefix, the stairs downstairs,
both conversations and the exit to Twinleaf Town. Earlier V5/V6 attempts
stopped at grid positions 9,6 and 8,5; continuing north from 8,5 reaches the
stair warp at 8,4. Read-only RAM analysis uses consistent manager/avatar/object
backlinks and matching integer, fixed-point and location coordinates. The map
IDs and screenshots agree: downstairs is 414, then town is 411. These values
help navigate the recorded replay; no game state or original save is edited.

The independent 16,800-frame cold-boot repeat matches every screen pair, the
entire audio/save, all per-frame game RAM hashes and 235 complete output files,
including the retained raw checkpoints. The repeat profiles only stable town
frames 15000–16799, so three measurement files differ intentionally: the two
instruction-counter columns are zero before 15000 and match the baseline
afterward, and the two PC profiles contain that window only. Every other state
column is exact. The raw comparator's state-file mismatch is retained and
fully explained in `ROOM_ROUTE_V9_REPEAT_COMPARISON.json`; no game-state
difference is masked.

The outdoor window has 292,331,250 ARM9 and 45,944,604 ARM7 executed reference
instructions. All 30 bins above 2% are screened and every sampled opcode in
them matches owned code or the pinned reference BIOS. Twenty-eight bins reuse
the prior static interpretation; two new bins contain IRQ-handler table mask
traversal and sound-envelope state updates. The former is a new candidate
lead: a 22-position loop continues through empty high positions after the
remaining mask is zero. Capture actual masks and callback values before
estimating savings. Preserve the high-bit cap, all selected table writes,
literal addresses and complete machine state; do not skip an IRQ or handler.
Its SDK identity is not yet established.

The town observer also records 60 empty 64-record queue entries and 63,120
dummy HBlank calls over frames 16400–16519. This broadens the unpatched scene
evidence, not the rejected optimizations' qualification. Outdoor walking beyond
the exit step, battle, save-write/reload, optimized transitions and all native
accuracy/cadence/performance work remain pending. No new beta is produced.

Evidence: `ROOM_ROUTE_V9_REVIEW.png`, `ROUTE_COORDINATE_FINDINGS_V1.json`,
`TOWN_REFERENCE_BEFORE_AFTER_V1.csv`, `TOWN_PROFILE_SCREEN_V1.json`,
`TOWN_NEW_THRESHOLD_DISASSEMBLY_V1.txt`, `TOWN_GUARDED_FINDINGS_V1.json`,
`IRQ_MASK_SCAN_PROPOSAL_V1.json` and `REPLAY_SCENE_REVIEW_V3.json`.

## IRQ-handler mask traversal

The guarded town census observes 57,840 complete entry/setup/exit triples.
Of these, 57,600 select bit 21 and 240 select bit 6. All preserve the expected
stack, literal-derived DTCM/main-table pointers, selected table effects and
return operands. An empty-tail cutoff passes 12,262 synthetic cases but has
only a 0.007389% weighted instruction-count opportunity in this scene, so it
does not merit a full-game trial. That estimate is not native timing.

The tested replacement instead visits only set bits, in ascending order, with
ARM9 CLZ. It occupies the same 128-byte initial ARM9 function, changes 97 byte
values, retains the original eight-byte literal pool and uses no scratch,
trampoline or HPS service. A separate semantic argument covers zero/high-only
masks, the 22-bit cap and upper-bit return. All 12,262 synthetic cases preserve
registers, CPSR, mapped memory and every ordered read/write. V1 assembly was
never executed; V2 reverses multiplication operands to avoid an ARMv5
destination/first-source alias.

The unpatched virtual-stream control reproduces all 241 census output files.
Both code/literal write watches contain exactly the 34 initial-load words and
no later observed stores. The candidate's 57,840 guarded calls each satisfy the
same selected-table and saved-stack contract, with the same mask/callback
histograms. Those checks do not establish whole-game equivalence:

| Metric | Control | Candidate |
|---|---:|---:|
| ARM9 reference entries, frames 15000–16799 | 292,331,250 | 285,962,200 |
| ARM7 reference entries, same window | 45,944,604 | 45,943,922 |
| Top-screen frame mismatches | 0 | 1, at frame 14359 |
| Bottom-screen frame mismatches | 0 | 0 |
| Different stereo samples of 13,479,065 | 0 | 6,591,626 |
| Maximum signed-16 audio delta | 0 | 6,731 |
| Failed main-RAM/DTCM/ARM7-WRAM checkpoint sets | 0 | All 11 |
| Per-frame/final save mismatches | 0 | 0 |

Audio RMS delta is 186.388139 without alignment or masking. Main RAM diverges
from frame 9, and DTCM/ARM7 WRAM from frame 8. The retained frame-2600 main-RAM
dump differs by 138,355 words outside the declared code. No timing-only,
audibility or benign-allocation explanation has been proved. In particular,
nearly identical screens and an unchanged save do not justify masking the RAM
or audio differences.

**Rejected and disabled.** The measured 2.178710% reduction is software
instruction entries, not native cycles, frame time or gameplay speed. Native
p50/p95/max frame time, dropped frames, HPS load and load-time changes remain
unmeasured. No optimized reset, native trial, unchanged rerun or beta follows a
failed replay gate. The accepted FFTA2 Beta2 package remains unchanged.

The generic pattern detector also finds a 25-bit ARM7 loop with no samples in
this window. It is a separate lead: ARM7 cannot execute the ARM9 CLZ replacement.
Six detector tests cover renamed registers and unsafe near matches; four
comparison tests cover explicit combined code/data write watches and existing
overlay normalization. No game addresses were added to the shared tools.

Evidence: `IRQ_MASK_CENSUS_EFFECT_AUDIT_V1.json`, `IRQ_MASK_COST_SCREEN_V1.json`,
`IRQ_SPARSE_SEMANTIC_ARGUMENT_V2.json`, `IRQ_SPARSE_SYNTHETIC_V2.json`,
`IRQ_SPARSE_CONTROL_V2_STATUS.json`, `IRQ_SPARSE_CANDIDATE_EFFECT_AUDIT_V2.json`,
`IRQ_SPARSE_COMPARISON_V2.json`, `IRQ_SPARSE_DECISION_V2.json`,
`IRQ_SPARSE_BEFORE_AFTER_V2.csv` and `IRQ_SPARSE_PATTERN_SCAN_V1.json`.

Next three investigations:

1. Capture ARM7 pitch/volume operands and caller recurrence before considering
   arithmetic reuse. Preserve stateful envelope updates and audio cadence.
2. Extend active outdoor movement, battle and isolated save-write/reload
   coverage, then profile those scenes before optimizing more town-idle work.
3. Revisit the whole-empty HBlank proposal only with a proved layout and
   callback/IRQ contract. A startup- or caller-scoped IRQ optimization would
   require a new proof and supported delivery, not an unchanged rerun of this
   rejected patch. Any perceptual budget needs separate user approval.

No RTL, new HPS service, save-state-format change or non-bit-exact acceptance
is authorized here. No speed improvement or new beta is claimed.
