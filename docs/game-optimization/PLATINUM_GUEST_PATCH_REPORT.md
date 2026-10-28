# Pokémon Platinum guest-code optimization — 27–28 October 2026

Platinum became the sole active target when the user explicitly advanced from
FFT due diminishing returns. Use exact rc12 with cumulative accepted changes;
preserve the earlier player-character and furniture fixes. Historical PBOX
binaries, timings and room screenshots are context, not the current baseline.
Six candidates remain disabled, including a new terrain-visibility experiment. At the user's request, three were subsequently
screened as isolated perceptual experiments on native hardware: empty-tail
cleanup, FIFO predication and font-table reuse. No worthwhile native gain is
demonstrated in the measured walking/menu/Bag scenes. Battle benefit remains
unmeasured. Review videos preserve their known reference differences, and
no non-bit-exact acceptance or new beta follows. Later native-screening
sections supersede historical no-retry restrictions only for these authorized
experiments. Exact rc12 and accepted Beta2 archives remain the baseline assets.

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

Priorities after the IRQ trial (the sound census is completed below):

1. Capture ARM7 pitch/volume operands and caller recurrence before considering
   arithmetic reuse. Preserve stateful envelope updates and audio cadence.
2. Extend active outdoor movement, battle and isolated save-write/reload
   coverage, then profile those scenes before optimizing more town-idle work.
3. Revisit the whole-empty HBlank proposal only with a proved layout and
   callback/IRQ contract. A startup- or caller-scoped IRQ optimization would
   require a new proof and supported delivery, not an unchanged rerun of this
   rejected patch. Any perceptual budget needs separate user approval.

## ARM7 sound arithmetic census

The existing observer now captures registers without dereferencing memory, with
the same CPU/mode/opcode/pipeline-PC guards. This avoids incorrectly treating
ARM7 WRAM as main RAM. All 68 observer checks and six recurrence tests pass.
Only the diagnostic frontend is rebuilt; its linked CPU, audio and renderer
objects are unchanged. The 16,800-frame unpatched replay reproduces all 238
game/profile files, including every screen, RAM checkpoint, audio sample, save
and instruction count. Only the three observer trace files differ intentionally.

The 462,616 guarded events contain 57,827 complete calls each to pitch and
volume helpers, plus their lookup input/output sites. No incomplete boundary
call is discarded. Pitch's only observed caller returns to `037fc770`, and
volume's to `037fc760`. Four-stage audits validate normalization/clamping,
stack-pointer deltas and BL links. They do not claim saved-stack byte or full
register/flag equivalence for a replacement.

| Numerical operation | Calls | Distinct captured inputs | Conflicting R0 results | Hypothetical 16-entry LRU hits |
|---|---:|---:|---:|---:|
| Pitch, base timer + signed offset | 57,827 | 397 | 0 | 55,815 |
| Pitch BIOS lookup | 57,827 | 252 | 0 | 56,226 |
| Volume, signed level | 57,827 | 1,039 | 0 | 9,985 |
| Volume BIOS lookup | 57,827 | 722 | 0 | 10,385 |

Pitch base timers range from 379 to 1,047 and signed offsets from -960 to
1,088 in this window. The caller obtains the base with a halfword load; that
does not prove this narrower observed range for every scene. Zero pitch occurs
13,874 times, always returning the observed base, whereas normalized lookup
index zero occurs 16,888 times. Those conditions are not interchangeable.
Volume levels range from -1,416 to -2 and exercise the lower clamp at -723.
The existing caller already skips sound-state writes when derived output has
not changed; that alone does not avoid computing the output.

Pitch reuse is worth further investigation, but no cache is implemented.
Its 16-entry LRU covers about 96.5% of calls before lookup/storage costs;
a single global last-result entry covers only 1,233 calls. Volume's weaker
local reuse makes a small generic cache less attractive. Same-address R4
contexts do not prove a voice's lifetime or make any fields safe scratch.
No HPS offload or ARM7 CLZ path is available by assumption. The current byte
loader supports ARM9 main/uncompressed overlays, so ARM7 delivery needs its
own guarded mapping and unchanged-stream qualification before a candidate.

The next bounded step is a no-scratch zero-pitch arithmetic proof: retain
out-of-range/clamped behavior, BIOS/table invariants and all observable CPU
effects, then screen its actual instruction cost. Do not simply skip the call
because the captured base values exceed the minimum clamp. No new patch, native
performance result or beta follows from this census.

Evidence: `REGISTER_WATCH_BUILD_V10.json`, `REGISTER_WATCH_TESTS_V10.json`,
`ARM7_SOUND_CENSUS_QUALIFICATION_V1.json`, `ARM7_SOUND_WATCH_IDENTITY_V1.json`,
`ARM7_SOUND_RECURRENCE_V1.json`, `ARM7_SOUND_CALL_CONTRACT_V1.json` and
`ARM7_SOUND_CENSUS_BEFORE_AFTER_V1.csv`.

Next three investigations after this census:

1. Prove and cost a guarded zero-pitch path without scratch; qualify ARM7
   in-memory delivery only if a worthwhile exact candidate emerges.
2. Extend active outdoor movement, battle and isolated save-write/reload
   coverage, then profile representative scenes.
3. Evaluate a small pitch cache only after a safe storage/lifetime contract;
   keep whole-empty HBlank as a separate unresolved layout/callback proposal.

No RTL, new HPS service, save-state-format change or non-bit-exact acceptance
is authorized here. No speed improvement or new beta is claimed.

## Carry-derived zero multiply in the pitch helper — 28 October UTC

The investigation found a smaller change than bypassing the zero-pitch helper.
Keep the BIOS call, normalization, shifts and clamps. In the ARM7 autoload-2
routine, `MOV ip,#0; ADC r3,ip,#0` produces `r3=C`. The intervening instructions
preserve C. At `037fbe00`, `MLA r1,r3,r5,r1` therefore leaves R1 unchanged when
C is clear. Changing its condition to CS preserves the original operation when
C is set and skips an identity operation when it is clear. No scratch, new
service or BIOS-table assumption is needed. Only one byte changes, inside a
36-byte authenticated context: `e0211593` becomes `20211593`.

The algebra covers arbitrary 32-bit block inputs. All 6,800 synthetic cases,
including carry boundaries, negative bases and all NZCV combinations, preserve
R0–R12, SP/LR/PC, CPSR, mapped memory and ordered accesses. Both versions still
have nine instruction entries and zero data accesses. Failed ARM predicates
are still fetched and counted; any benefit would come from avoiding multiply
latency, not fewer instruction entries. Native timing is unmeasured.

The extra unpatched observation site reproduces all 238 game/profile files
over 16,800 frames. All 462,616 events from the original eight sites also match
after removing only the event ordinal. The 57,827 additional events reconstruct
the target's entire register/CPSR pre-state from the lookup-return snapshot.
Every observed call has C=0 and R3=0. This supports a projected 57,827 avoided
MLA executions in the observed window; it is not a patched replay or speedup.

| Check | Original | Candidate |
|---|---:|---:|
| Synthetic block instruction entries | 9 | 9 |
| Synthetic block data accesses | 0 | 0 |
| Exact synchronous cases | Reference | 6,800 passed |
| Target MLA executions, observed window | 57,827 measured | 0 projected |
| Full-game patched replay | Unpatched control exact | Not run |
| Native frame time / cycles / HPS load | Not measured here | Not measured |

A larger three-instruction alternative also passed 65,833 synthetic cases,
but requires a bounded BIOS return and changes twelve byte values. Preserve it
as private evidence; prefer the one-byte all-input argument. A direct helper
skip would also remove BIOS stack/register effects and is not qualified.

The shared scanner now finds the carry-derived shape with renamed registers
and rejects broken dataflow, flag updates, conditional context, special
registers and ARMv4 multiply destination/source aliases. Thirteen detector
tests pass, including the existing dispatch/mask tests. The actual ROM scan
finds the exact ARM7 autoload-2 sequence, without title-specific scanner logic.
Capstone reports a carry read as a flag update for ADC in this environment;
the detector verifies the encoded S bit for these five specific opcodes.

The candidate remains disabled. Current delivery explicitly rejects ARM7
autoload targets and reproduces all 128 MiB of the original cartridge on that
fallback. No candidate ROM is written. Extending the existing guarded virtual
stream needs exact ARM7/section identity, verified load mapping and an unchanged
control before a changed-code replay. Entry paths, interrupt/audio timing,
cache visibility, reset and state-load behavior remain separate obligations.
The three earlier rejected Platinum patches stay disabled; FFTA2 Beta2 is
unchanged. The proof establishes no perceptual allowance or release readiness.

Evidence: `ARM7_PITCH_CARRY_DECISION_V1.json`,
`ARM7_PITCH_CARRY_SYNTHETIC_V1.json`,
`ARM7_PITCH_CARRY_CENSUS_QUALIFICATION_V1.json`,
`ARM7_PITCH_CARRY_CALL_CONTRACT_V1.json`,
`ARM7_PITCH_CARRY_DELIVERY_PREFLIGHT_V1.json`,
`ARM7_PITCH_CARRY_PATTERN_SCAN_V1.json` and
`ARM7_PITCH_CARRY_BEFORE_AFTER_V1.csv`.

Next three investigations:

1. Qualify ARM7 autoload delivery in the existing virtual-stream loader, then
   run the one-byte candidate through strict replay comparison. Keep it only
   if it produces a measurable benefit after all required validation.
2. Extend active outdoor movement, battle and isolated save-write/reload
   coverage. Profile those scenes before spending further effort on town idle.
3. Investigate pitch reuse only if a safe storage/lifetime contract emerges;
   the apparent cache hit rate alone does not authorize guest scratch.

## ARM7 autoload delivery control

The existing `guest_byte_patch` loader now supports an explicitly pinned,
uncompressed ARM7 WRAM autoload section. Platinum's settings are at ARM7
offset `1d0`; the raw final copy table and all three payloads match the shared
decoder. Selected section 2 starts at `037f8000`, contains 60,564 bytes and has
16,952 BSS bytes. Its source starts at cartridge offset `409aa4`. The original
boot prefix, table, BSS sizes, header and cartridge layout are preserved.
This prepares bytes in the existing virtual stream; it installs no new hook.

All 33 loader tests pass, including existing ARM9 main/overlay paths, malformed
table and identity rejection, mixed-selection atomic fallback, protected data,
same-byte control and the actual stream worker protocol. The original ROM is
opened read-only. The same-byte control reproduces all 128 MiB, and offline
preparation of the candidate changes exactly one byte at cartridge `40d8a7`.
The changed stream has not been executed or delivered as a beta.

The long control reproduces all 241 files of the 16,800-frame town reference,
including the nine-site register trace. A separate 2,601-frame boot baseline
and its same-byte control reproduce all 83 files. Their screens, every RAM/save
frame hash, audio prefix, captures and retained dumps also match the long
reference's prefix. Only the explicitly different profile window and observer
diagnostics differ from that long reference.

The existing register observer captures all 40,316 word stores in the original
ARM7 copy routine at `02380154`, during frames 0–5. Each table pointer, source,
destination, length/end, data word and return/pipeline link matches the pinned
image: 47 words for section 1, 15,141 for section 2 and 25,128 for section 3.
This directly verifies the bounded original boot mapping, beyond inferring it
from a parser. It does not test changed instruction timing or native mapping.

| Delivery check | Original | Identical-byte control |
|---|---:|---:|
| Cartridge bytes | 134,217,728 | All identical |
| Town replay frames / complete files | 16,800 / 241 | All identical |
| Boot replay frames / complete files | 2,601 / 83 | All identical |
| Boot copy word stores | 40,316 | All identical |
| Changed-code replay / native timing | Not part of control | Not run |

The 36-byte target context is absent from shared WRAM at frame 0 and present
by frame 1. Its initial staging copy at `02384088` still matches through the
early checkpoints, but has been overwritten by frame 2600. The comparison
extension must handle both physical copies and leave reused or unmatched
memory raw. The current comparator only supports ARM9 main/overlay RAM, so
it cannot yet authorize an ARM7 candidate comparison. Never blindly subtract
the patch address from the main-RAM base or mask the staging location forever.

The candidate remains disabled, and no speedup or new beta is claimed. Next:
qualify context-aware ARM7 shared/private-WRAM and staging comparisons, then
run the changed stream through exact replay, lifecycle and native-performance
gates. Broader active outdoor, battle and save-write/cold-reload routes remain
needed; safe pitch-cache storage is still unproved.

Evidence: `ARM7_AUTOLOAD_DECISION_V1.json`,
`ARM7_AUTOLOAD_LOADER_TESTS_V1.json`, `ARM7_AUTOLOAD_NOOP_PREFLIGHT_V1.json`,
`ARM7_AUTOLOAD_CANDIDATE_PREFLIGHT_V1.json`, `ARM7_AUTOLOAD_CONTROL_V1_STATUS.json`,
`ARM7_AUTOLOAD_BOOT_MAPPING_V1.json`, `ARM7_AUTOLOAD_BOOT_CONTROL_V1_STATUS.json`
and `ARM7_AUTOLOAD_BEFORE_AFTER_V1.csv`.

## ARM7 comparison qualification

The existing comparison helper now accepts explicit main/shared/private RAM
views for authenticated autoload contexts. It checks the full 36-byte context
before normalizing the single changed byte in a local copy. Unloaded, partial
and reused contents remain raw. Both initial staging and executing copies are
derived from the existing guarded loader; no alternate patch loader or live
memory mutation is involved. Legacy ARM9 and full-body overlay behavior remains.

All 51 C++ comparison checks and seven Python tests pass. Only the diagnostic
frontend is rebuilt as `arm7_compare_oracle_v11`; the linked CPU, core, renderer
and audio objects remain identical. Its unpatched town control reproduces all
241 files over 16,800 frames, and its boot control reproduces all 83 files over
2,601 frames. Normalized main/shared/private RAM hashes equal the raw control
hashes on every frame. The counters explicitly retain unmatched staging after
reuse instead of masking it by address. This qualifies comparison controls,
not the candidate's asynchronous behavior or native performance.

Evidence: `ARM7_COMPARISON_TESTS_V1.json`, `ARM7_COMPARISON_BUILD_V11.json`,
`ARM7_COMPARISON_QUALIFICATION_V1.json`, `ARM7_PITCH_CARRY_CONTROL_V2_STATUS.json`
and `ARM7_COMPARISON_BOOT_CONTROL_V1_STATUS.json`.

## One-byte ARM7 pitch trial — rejected

The changed stream completed all 16,800 frames. The observer fetched the new
`20211593` opcode in all 57,827 target calls, each with C=0 and R3=0. Pitch
still has 397 captured input pairs, with identical R0 results for every shared
pair. This verifies bounded changed-instruction execution in the software
reference; it does not prove native fetch/cache behavior or whole-game equality.

| Metric | Control | Candidate |
|---|---:|---:|
| ARM9 reference entries, frames 15000–16799 | 292,331,250 | 292,330,960 |
| ARM7 reference entries, same window | 45,944,604 | 45,944,758 |
| Top / bottom screen mismatches | 0 / 0 | 0 / 0 |
| Different stereo samples of 13,479,065 | 0 | 73,833 |
| Maximum signed-16 audio delta | 0 | 2,974 |
| Main-RAM / DTCM word differences at checkpoint 14300 | 0 / 0 | 49 / 3 |
| Per-frame / final save mismatches | 0 / 0 | 0 / 0 |

Audio RMS delta is 8.593533, with no alignment, masking or audibility judgment.
Ten of eleven fixed RAM checkpoint sets match; frame 14300 fails main RAM and
DTCM. Its ARM7 private/shared RAM and ITCM still match after exact code
normalization. The retained frame-2600 main-RAM dump also matches. Transient
per-frame differences occur in main RAM on 30 frames, DTCM on 110 and ARM7
private WRAM on 618; normalized shared WRAM and save hashes match throughout.
The reference frame timestamp differs on 445 frames, with identical per-frame
audio sample counts. No benign or timing-only explanation has been established
for the differing data, and the output gate is not relaxed.

**Rejected and disabled.** The two CPU entry totals are reference observations,
not native cycles or gameplay speed. The failed predicate still has an
instruction entry; skipping the multiply does not make the nine-entry block
shorter. No native frame-time, dropped-frame, HPS-load or load-time improvement
is qualified. Do not repeat the unchanged candidate, combine it, transfer FFT's
perceptual allowance or promote it to a beta. The existing Beta2 stays intact.

The shared ARM7 loader and comparison remain useful for future candidates.
The next priority is a visually reviewed active outdoor route, then a battle
and isolated save-write/cold-reload coverage, followed by profiling those
scenes. A safe pitch cache and the whole-empty HBlank callback idea remain
deferred; neither has a storage/lifecycle or layout proof.

Evidence: `ARM7_PITCH_CARRY_REPLAY_DECISION_V1.json`,
`ARM7_PITCH_CARRY_PAIR_COMPARISON_V1.json`,
`ARM7_PITCH_CARRY_EXECUTION_AUDIT_V1.json`,
`ARM7_PITCH_CARRY_CHECKPOINT_DIFF_V1.json`,
`ARM7_PITCH_CARRY_CANDIDATE_V1_STATUS.json` and
`ARM7_PITCH_CARRY_REPLAY_BEFORE_AFTER_V1.csv`.

## Bounded outdoor walking baseline

The unpatched route now walks 16 tiles outside the player's house. Five
checkpoint positions follow `(116,886) → (119,886) → (119,891) → (119,886) →
(116,886)`. Screenshots, coherent avatar/manager backlinks, stored location and
fixed-point world position agree. The 600-frame profile window includes turns,
pauses and a collision at the southern tree boundary. This establishes bounded
walking coverage, not continuous movement, battle or a representative full-game
benchmark.

An independent 15,600-frame repeat matches all 180 complete output files:
both screens, per-frame RAM hashes, five full checkpoint sets, audio, saves and
profiles. No code bytes or RAM regions are normalized for these unpatched runs.

| Metric | Baseline | Independent repeat |
|---|---:|---:|
| Complete replay frames | 15,600 | 15,600 |
| ARM9 reference entries, frames 15000–15599 | 98,783,080 | 98,783,080 |
| ARM7 reference entries, same window | 16,043,379 | 16,043,379 |
| Different complete output files | 0 | 0 |
| Native speed improvement | Unmeasured | Unmeasured |

All 31 256-byte bins above 2% of that CPU's instruction-sample total were
screened. The largest ARM9 bins remain IRQ/context dispatch (10.53%), transfer
helpers (10.40%), and hardware-math context preservation (6.49%). These are bin
sample shares, not function cycle shares. Two additional ARM7 bins cross the
threshold: timed callback queue dispatch at `037fa700` (2.23%) and sound sequence
state traversal at `037fd000` (2.06%). The former changes timer/queue state and
calls callbacks; the latter traverses 16 state records, advances accumulators
and invokes sound helpers. Neither is established as dead or redundant work.
All 133 newly sampled sites in these bins match owned main/autoload bytes;
overlay 5 matches its complete original body at all five checkpoints.

The generic ARM detector again finds the known copy, sparse-mask and
carry-predication shapes. This is no reason to reinstate rejected candidates.
All four remain disabled, and rc12 plus accepted FFTA2 Beta2 are unchanged.

The first navigation probe exposed a tooling issue: a comment stopped the
oracle's formatted input reader before the added movement. That run is retained
and excluded. The shared `validate_replay_inputs.py` preflight now rejects
comments, malformed rows and invalid bounds/masks. Eight tests pass, and the
actual malformed route is rejected. The corrected route has 127 validated
intervals. The oracle and product runtime were not rebuilt or changed.

Next priorities are ordinary-input rival/story progression into a battle,
isolated save-write/cold reload, and candidate selection from that broader
workload. A pitch cache still requires safe storage/lifetime proof; the
whole-empty HBlank idea still lacks layout and callback/IRQ proof.

Evidence: `OUTDOOR_ROUTE_V2_REPEAT_COMPARISON.json`,
`OUTDOOR_ROUTE_V2_REVIEW.png`, `OUTDOOR_ROUTE_V2_COORDINATES.json`,
`OUTDOOR_PROFILE_SCREEN_V1.json`, `OUTDOOR_PATTERN_SCREEN_V1.json`,
`OUTDOOR_BASELINE_REPEAT_V1.csv`, `REPLAY_SCENE_REVIEW_V4.json`,
`REPLAY_INPUT_VALIDATION_TESTS_V1.json` and
`ACTIVE_BATTLE_ROUTE_PROPOSAL_V1.json`.

## Rival story, in-game save and cold-load baseline

Normal inputs now reach the rival's outdoor collision/dialogue event and enter
his house. Screenshots and checkpoint coordinates show the outdoor event at
`(105,877)` after the scripted push-back, followed by house 1F, map 412, at
`(6,10)`. The independent 23,000-frame story-and-save repeat matches all 258
complete output files, including both screens, every RAM/save hash, seven full
checkpoint sets, audio and the final save. Unchanged prefixes of every route
extension also match; the initial navigation profile has a separately declared
measurement window.

The game menu's normal Save command writes only to the disposable replay
buffer. Its first 19,600-frame probe ended mid-write and is excluded as a seed.
The extended run visibly displays "A saved the game" at frame 19920 and returns
to the room. Save hashes first change at 19435, last change at 19776, and remain
stable for the final 3,223 frames. The independently repeated save is identical.
The original ROM and parent save remain unchanged.

| Metric | Baseline | Independent repeat |
|---|---:|---:|
| Complete story/save frames | 23,000 | 23,000 |
| Identical story/save output files | 258 | 258 |
| Last save-hash change frame | 19,776 | 19,776 |
| Stable final save frames | 3,223 | 3,223 |
| Cold-load frames | 3,200 | 3,200 |
| Identical cold-load output files | 61 | 61 |
| Native speed improvement | Unmeasured | Unmeasured |

Cold boot with the completed game-generated save restores house 1F at `(6,10)`
in all three checkpoints (1600, 2600 and 3000), rather than the original bedroom.
Screenshots and internally consistent avatar/location state agree. The complete
save remains unchanged on every cold-load frame. A second independent cold-load
run reproduces all 61 files exactly. This qualifies an unpatched software-reference
seed for later route construction; it is not native save validation or an emulator
save-state round trip.

The new 524,288-byte seed has SHA-256
`706c9febdf25cb903481c4a6d405f647c4309cfdf841a995a4c56f01157e6292`.
Its admission receipt pins the original parent, complete producing input route,
save completion evidence, both repeats and cold-load inputs. Keep this provenance
when using it to shorten future setup. Never use the excluded partial output.

The exploratory navigation/dialogue window at frames 15600–16799 has 30 bins
above 2% instruction-sample share. They retain previously evidenced roles; all
21 newly sampled sites match owned code. There is no new removable-work proof.
Save and cold-load runs disable profiling. All four guest candidates remain
disabled, with no new native measurement, beta, RTL or product-runtime change.

The next three priorities are rival-house 2F/story progression into a deterministic
battle, a controlled native walking/battle baseline after fresh ownership checks,
and candidate selection from that broader workload. The pinned source suggests a
staircase at `(2,3)` in house 1F; the route around furniture is still a proposal.
Pitch-cache storage/lifetime and the HBlank callback/IRQ proof remain open.

Evidence: `STORY_SAVE_SEED_ADMISSION_V1.json`,
`STORY_SAVE_V2_REPEAT_COMPARISON.json`,
`STORY_COLD_LOAD_V1_REPEAT_COMPARISON.json`,
`STORY_SAVE_V2_COMPLETION_REVIEW.png`, `STORY_COLD_LOAD_V1_REVIEW.png`,
`STORY_ROUTE_PREFIX_AUDIT_V3.json`, `STORY_NAVIGATION_PROFILE_SCREEN_V1.json`,
`STORY_SAVE_RELOAD_BASELINE_REPEAT_V1.csv`, `REPLAY_SCENE_REVIEW_V5.json`
and `RIVAL_HOUSE_BATTLE_ROUTE_PROPOSAL_V2.json`.

## First trainer battle and broader profile — 28 October 2026

Ordinary input from the admitted rival-house save now reaches house 2F,
Route 201, starter selection and the first rival battle. Turtwig fights Chimchar,
uses Tackle, takes damage, wins, gains 69 experience points and reaches level 6.
The 26,000-frame exploratory route then returns home. No coordinates, story
flags, ROM bytes or save data were edited. Its final save remains the original
pre-starter checkpoint; it is not a post-battle seed.

An independent 23,400-frame run repeats the exact input prefix and profiles
frames 18000–23399: trainer introduction, turns, victory, level-up and the exit
transition. Both screen hashes, frame metadata, every game RAM/save hash,
18,774,412 stereo audio samples and all 247 shared complete files match. The six
fixed checkpoint sets include full CPU registers and RAM. Only the declared
instruction counters and PC-sample files differ because the first run disabled
profiling. No game data is normalized. The later return-home tail is visually
reviewed but is outside this independent repeat.

| Metric | Unpatched baseline prefix | Independent profiled repeat |
|---|---:|---:|
| Compared frames | 23,400 | 23,400 |
| Different screen / game-RAM / save frames | 0 | 0 |
| Different stereo samples | 0 | 0 |
| Matching complete shared files | 247 | 247 |
| ARM9 entries, frames 18000–23399 | Profiling disabled | 294,410,989 |
| ARM7 entries, same window | Profiling disabled | 203,495,901 |
| Native speed improvement | Unmeasured | Unmeasured |

The profile has 21 bins above 2% of their CPU's periodic instruction samples,
including seven newly prominent bins. All 502 newly sampled sites in these bins
match owned code. The six battle checkpoints also match the entire decoded
overlay 16 body, SHA-256
`cdee3e91570eca14296be7164b03926d729d914a293d4db5098aeed4bb7f1950`.
These are 256-byte screening bins, not function cycle shares or native speed.

The leading ARM9 bin is cartridge block-read polling at `020cd400` (27.38%).
Owned instructions at `020cd488–020cd4ac` poll `040001a4`, read `04100010` when
data is ready, and store data for a 512-byte block. This is an active transfer
with request bookkeeping; blindly removing the loop or replacing it with a
generic interrupt wait is not justified. A request/recurrence census can test
whether repeated reads offer a safe cache or prefetch opportunity.

Other leads are six-byte strided callback uploads at `020a7e00` (3.33%), a
four-input packed-nibble lookup-table generator at `0201da00` (2.48%), a
completion-flag wait at `020cac00` (2.18%), and overlay 16's 256-byte table
reduction at `02251f00` (2.02%). The generator writes 256 halfwords into existing
storage; repeated inputs and all table writers have not yet been observed.
The overlay's nearby helpers mutate its table, so caching the sum requires an
invalidation/lifetime proof. The wait condition has mode-dependent service
calls, whose wakeup contract remains unknown. ARM7 adds stateful sound-sequence
work and a 25-bit IRQ-table scan; neither is established as removable work.

The existing generic ARM scanner was rerun with the new profiles. Its coverage
still excludes Thumb and overlays; the new generator and reduction are manual
leads, not reusable automatic signatures or admitted patches. No unchanged
rejected candidate was retried, and all four patches remain disabled.

The first contact sheet had red and blue swapped because legacy `.rgba` files
contain BGRA8888. Correct decoding shows the trainer followed by Chimchar;
there is no retained-trainer evidence in those frames. Corrected previews are
new artifacts. Raw captures, equality evidence and the renderer are unchanged.

Native tooling was inspected offline only. The old FFT wrapper hard-codes a
64 KiB save; Platinum needs 512 KiB. Reuse the existing rig with an isolated
Platinum configuration and fresh ownership/lease/process checks. The diagnostic
PC collector requires a tagged bitstream; exact rc12 support and overhead are
unqualified. No hardware was contacted, no new service/RTL was introduced,
and no new beta or native improvement is claimed.

The next three investigations are the table generator's input/write lifetime,
cartridge transfer recurrence and phase distribution, and the upload/reduction
helpers' data contracts. Native walking/battle cadence, pacing and audio remain
a separate required baseline before accepting a speedup.

Evidence: `FIRST_BATTLE_REPEAT_COMPARISON_V1.json`,
`FIRST_BATTLE_PROFILE_SCREEN_V1.json`, `FIRST_BATTLE_PATTERN_SCREEN_V1.json`,
`FIRST_BATTLE_NEW_BINS_DISASSEMBLY_V1.txt`,
`FIRST_BATTLE_NEW_BINS_CONTEXT_V1.txt`, `FIRST_BATTLE_OVERLAY_IDENTITY_V1.json`,
`FIRST_BATTLE_ROUTE_V1_REVIEW_BGRA.png`,
`FIRST_BATTLE_ROUTE_V2_PROGRESS_BGRA.png`, `FIRST_BATTLE_RESULT_REVIEW_BGRA.png`,
`FIRST_BATTLE_PREVIEW_FORMAT_REVIEW_V1.json`,
`FIRST_BATTLE_BASELINE_REPEAT_V1.csv`, `REPLAY_SCENE_REVIEW_V6.json`,
`NATIVE_BASELINE_PREPARATION_FINDINGS_V1.json`
and `BATTLE_HOTSPOT_CONTRACT_PROPOSAL_V1.json`.

## Font lookup-table recurrence and complete-function effects

The owned Thumb routine at `0201d9fc` builds 256 halfwords at `021c0500` from
three color arguments. Its structure matches the pinned decompilation's
`Text_GenerateFontHalfRowLookupTable`: four nested loops enumerate combinations
of `[0, foreground, shadow, background]`. That source calls the generator
before immediate text rendering and during text-printer task updates. It is a
semantic guide; the exact owned bytes, observed arguments and writes establish
the contract. No shared SDK or cross-title signature is claimed.

The existing generic memory and RAM-bus observers were enabled for the entire
23,400-frame route. The first probe incorrectly requested a main-RAM stack
span and stopped on the existing mapping guard. It is retained and excluded.
The corrected probe records entry table/metadata and entry/exit registers
without guessing the stack mapping. All 250 shared complete output files,
screen/frame metadata, audio, save and game-RAM hashes match the qualified
unpatched replay. Only declared counters/sample files and new observer files
differ. No product code or observer binary changed.

| Observation | Full route, 0–23399 | Battle window, 18000–23399 |
|---|---:|---:|
| Complete generator calls | 8,900 | 1,338 |
| Distinct color triples | 12 | 8 |
| Existing table already correct for current inputs | 8,833 | 1,281 |
| Existing three-color key falsely predicts a correct table | 0 | 0 |
| Same-table opportunities | 99.25% | 95.74% |

The generic recurrence tool separately verifies complete argument recurrence
and the declared R0/R1/R2 output registers. Its fixture does not pretend to
capture output table bytes. A separate write-contract audit validates every
one of the 2,278,400 table halfword stores, plus 26,700 color-metadata stores,
against the exact nested-loop model and paired entry arguments. All 8,900
invocations complete, and their pre-POP registers and NZCV match the modeled
original effects.

All 2,305,400 observed writes to the selected ranges are attributed: the
generator, 130 bootstrap zero-word stores, and 170 writes to an unrelated
metadata byte at `021c04d8`. After initialization, the generator is the only
observed table/color-field writer. There are no ARM7 or DMA writes to these
ranges in this replay. This is bounded interpreter/bus evidence; direct host
initialization, untested scenes, save-state loading and native cache visibility
are outside that claim. No unused scratch memory is asserted.

A naive early return would fail exactness even with a correct table. Thirty-two
synthetic cases using the existing equivalence runner verify that the original
function also leaves R0=4, R1=510, R2 as the background value replicated by
bitwise shifts/ORs, R12 and LR equal to entry SP minus 40, and NZCV=`0110`.
It restores saved registers/SP but writes 72 bytes below entry SP, including
local counters, pointers, colors and saved registers. The observed entry SPs
are `027e3510–027e3700`, within the DTCM range shown by the checkpoints; frame
boundary SP snapshots in a different task did not predict this call stack.
Dynamic stack bytes were not captured in the corrected census. The synthetic
model checks their complete original contents and all mapped memory effects.

The original takes 5,247 synthetic instruction entries per call. Eliminating
every instruction from all 1,281 matching battle calls would remove at most
6,721,407 entries, or 2.283% of that window's ARM9 total. This intentionally
optimistic bound excludes the necessary guard, register/stack reproduction and
fallback costs. It is not a measured candidate improvement or native speedup.

The next patch design should use a guarded replacement within the authenticated
function extent, preserve the original input-domain semantics and complete CPU/
stack effects, and retain generation on a miss. No extra validity flag, code
cave or scratch area is admitted. Cache lifetime, asynchronous readers, reset,
save/reload and non-target scenes still need qualification. All four earlier
patches remain rejected and disabled; no new candidate or beta is enabled.

Evidence: `LOOKUP_TABLE_IDENTITY_V1.json`, `LOOKUP_TABLE_SOURCE_GUIDE_V1.json`,
`LOOKUP_TABLE_CENSUS_V1_EXCLUSION.json`,
`LOOKUP_TABLE_CENSUS_QUALIFICATION_V1.json`, `LOOKUP_TABLE_RECURRENCE_V1.json`,
`LOOKUP_TABLE_ENTRY_REUSE_V1.json`, `LOOKUP_TABLE_WRITER_CENSUS_V1.json`,
`LOOKUP_TABLE_WRITE_CONTRACT_V1.json`,
`LOOKUP_TABLE_ORIGINAL_EFFECT_MODEL_V1.json`,
`LOOKUP_TABLE_BEFORE_AFTER_V1.csv` and `LOOKUP_TABLE_REUSE_PROPOSAL_V1.json`.

## Font-table reuse replacement: rejected by full replay

`font-table-last-colors-reuse` fits in the original 164-byte ARM9 Thumb
function/literal extent at `0201d9fc`. It compares the three stored 16-bit
colors with the complete 32-bit arguments. A match reuses the table; a miss
regenerates it. Both paths reproduce the original register, flags and 72-byte
stack effects. There is no code cave, new scratch, overlay, HPS service or RTL
change. The original ROM is read-only; the existing virtual cartridge loader
streams the guarded replacement into the reference instance.

The existing block checker now supports explicit ordinary-RAM effect ranges
and reads of unchanged code literals. It still compares every mapped byte,
all CPU effects and ordered accesses outside the declared ranges. Six focused
tests and the prior 6,800-case ARM7 suite pass. The new patch passes 8,672 cases:
all 4,096 four-bit color triples as coherent hits and misses, wider inputs,
every mismatch branch, all NZCV combinations and ARM/Thumb returns. A deliberate
matching-key/wrong-table case fails as expected. Table coherence remains a
precondition, not a consequence of matching the key.

The unchanged virtual-adapter control matches all 253 baseline files across
23,400 frames. The first control launch used a system Python without NumPy and
failed before starting the oracle; it is retained and excluded. The successful
control and candidate use the existing testing-rig virtual environment.

| Measurement | Original | Replacement |
|---|---:|---:|
| Synthetic coherent-table hit, entries/call | 5,247 | 42 |
| Synthetic changed-color miss, entries/call | 5,247 | 6,701–6,707 |
| ARM9 reference entries, frames 18000–23399 | 294,410,989 | 287,746,374 |
| ARM7 reference entries, same window | 203,495,901 | 203,495,544 |
| Upper-screen frames differing from control | 0 | 5 of 23,400 |
| Lower-screen frames differing from control | 0 | 0 |
| Stereo samples differing from control | 0 | 61,453 of 18,774,412 |
| Fixed RAM checkpoint sets matching control | 6 | 6 |
| Per-frame save hashes and final save | Reference | Exact |
| Native cycles, pacing, HPS load and load time | Unavailable | Unavailable |

All 1,338 watched battle calls execute the replacement: 1,281 reuse the table
and 57 regenerate it. Their input sequence and entry/exit frame bounds match
the original census, and every observed pre-POP CPU state meets the declared
model. Dynamic stack bytes were not captured; their complete effects were
checked synthetically. The replacement body is recognized on every replay
frame. These observations establish execution and the local call contract,
not full-game equivalence or native cache visibility.

Upper-screen hashes differ at frames 18131, 19457, 20891, 22807 and 22819.
Audio lengths match, but the maximum signed-16 delta is 2,870 and RMS delta
15.591, without alignment, masking or an audibility judgment. Per-frame RAM
hashes differ in 200 main-RAM, 607 DTCM and 75 ARM7-WRAM frames. All six fixed
checkpoint sets and retained frame-2600 main RAM are exact after normalizing
only the authenticated code extent; no game RAM or stack is masked.

The measured 2.264% reduction is reference instruction accounting, not native
speed. The unchanged-call synthetic model predicts 2.237%; the full reference
also changes execution timing and surrounding work. Reject the patch under
the current screen/audio gate and retain it disabled. Do not rerun it unchanged,
combine it with other rejected patches, or transfer FFT's perceptual approval.
Further reset, save/reload, unrelated-scene and native trials are not performed
for this rejected version. Accepted Beta2 and exact rc12 remain unchanged.

Next, prepare the native walking/battle baseline using the existing rig with
an isolated 512 KiB save and fresh ownership/runtime checks. The three deferred
optimization leads are cartridge-request recurrence and transfer phases,
small strided upload callbacks/data, and overlay 16 table-reduction lifetime.
Active cartridge FIFO polling is not proven dead work. Native profiling that
needs a new diagnostic bitstream remains a proposal requiring approval.

Evidence: `LOOKUP_TABLE_REUSE_BUILD_V1.json`,
`LOOKUP_TABLE_REUSE_INPUT_MANIFEST_V1.json`,
`LOOKUP_TABLE_REUSE_SYNTHETIC_SUITE_V1.json`,
`LOOKUP_TABLE_REUSE_COST_MODEL_V1.json`,
`LOOKUP_TABLE_REUSE_CONTROL_V1_EXCLUSION.json`,
`LOOKUP_TABLE_REUSE_CONTROL_V2_STATUS.json`,
`LOOKUP_TABLE_REUSE_CANDIDATE_V1_STATUS.json`,
`LOOKUP_TABLE_REUSE_PAIR_COMPARISON_V1.json`,
`LOOKUP_TABLE_REUSE_EXECUTION_AUDIT_V1.json`,
`LOOKUP_TABLE_REUSE_REPLAY_DECISION_V1.json`,
`LOOKUP_TABLE_REUSE_BEFORE_AFTER_V1.csv`,
`LOOKUP_TABLE_REUSE_FINAL_AUDIT_V1.json` and
`AFTER_FONT_REUSE_NEXT_STEPS_V1.json`.

## overlay5-empty-tail-exit — authorized native perceptual screening

The user explicitly authorized testing potentially imperceptible differences and
recording videos on 28 October. This supersedes the historical no-retry/native
restriction for this isolated experiment, without accepting its mismatches.

Walking: 16.70–16.80 control versus 16.65 patched screen publications/s; menu: 14.89–15.13 control versus 14.74 patched. No native gain demonstrated. These are endpoint screen-buffer publication counts, not unique gameplay
FPS, frame-time percentiles or emulated cycles. Native battle benefit remains
unmeasured. The candidate stays disabled.

The cold-boot trial used the same qualified disposable story save, stock 1 GHz,
unchanged rc12 FPGA and accepted Beta2 renderer. Expected original bytes and
the selected virtual-cartridge replacement were guarded; this is not direct
ARM instruction-cache readback. Saves remained exact and OBS added no dropped
frames. No RTL, new HPS service, persistent save-state format or ROM file changed.

Reference audiovisual review: `Platinum_Overlay_Review.mov` (verified original PCM),
with an AAC convenience copy. Both screens are shown side by side; every scene
repeats with control then candidate audio, without mixing or volume changes.
These deterministic software clips are separate from the native speed tests.
Evidence: `NATIVE_PERCEPTUAL_RESULTS_V1.json`, native trial `PLATINUM_E2`,
`PERCEPTUAL_EMPTY_CONTROL_V1_STATUS.json`,
`PERCEPTUAL_EMPTY_CANDIDATE_V1_STATUS.json`, and `Platinum_Overlay_Review.json`.

## fifo-word-stream-predication — authorized native perceptual screening

The user explicitly authorized testing potentially imperceptible differences and
recording videos on 28 October. This supersedes the historical no-retry/native
restriction for this isolated experiment, without accepting its mismatches.

Menu: 14.6755 control versus 14.6280 patched; Bag: 30.2040 versus 30.0440 screen publications/s. Bag-opening near-black mean: 0.4333s control versus 0.4417s patched. No native gain demonstrated. These are endpoint screen-buffer publication counts, not unique gameplay
FPS, frame-time percentiles or emulated cycles. Native battle benefit remains
unmeasured. The candidate stays disabled.

The cold-boot trial used the same qualified disposable story save, stock 1 GHz,
unchanged rc12 FPGA and accepted Beta2 renderer. Expected original bytes and
the selected virtual-cartridge replacement were guarded; this is not direct
ARM instruction-cache readback. Saves remained exact and OBS added no dropped
frames. No RTL, new HPS service, persistent save-state format or ROM file changed.

Reference audiovisual review: `Platinum_FIFO_Review.mov` (verified original PCM),
with an AAC convenience copy. Both screens are shown side by side; every scene
repeats with control then candidate audio, without mixing or volume changes.
These deterministic software clips are separate from the native speed tests.
Evidence: `NATIVE_PERCEPTUAL_RESULTS_V1.json`, native trial `PLATINUM_Q1`,
`PERCEPTUAL_FIFO_CONTROL_V1_STATUS.json`,
`PERCEPTUAL_FIFO_CANDIDATE_V1_STATUS.json`, and `Platinum_FIFO_Review.json`.

## Native before/after — 28 October perceptual screening

All trials use the same rc12 FPGA, accepted Beta2 renderer, stock 1 GHz and
qualified disposable story seed. This comparison isolates each guest patch;
it is not an overall Beta2-versus-original-rc12 comparison. C4/E2/C5 share the
boundary-traversal then menu route. F1/Q1/C6 share field anchor, menu, then Bag
without the traversal warmup. C5 Bag is supplementary control evidence.

| Native scene / metric | Original game code | One patched routine | Result |
|---|---:|---:|---|
| Anchored walking, screen publications/s | 16.7975, 16.6995 | Empty tail: 16.6457 | No demonstrated gain |
| Menu after walking, publications/s | 15.1344, 14.8884 | Empty tail: 14.7406 | No demonstrated gain |
| Menu from field, publications/s | 14.6755 | Font: 14.6349; FIFO: 14.6280 | No demonstrated gain |
| Bag cycling, publications/s | 30.2040 | Font: 30.0610; FIFO: 30.0440 | No demonstrated gain |
| Bag-opening near-black mean, 4 cycles | 0.4333 s | Font: 0.4500 s; FIFO: 0.4417 s | No shorter visible transition |
| Bag-closing near-black mean, 4 cycles | 1.3208 s | Font/FIFO: 1.3167 s | Sub-frame mean difference; not a qualified gain |
| HPS helper, menu, percent of one core | 147.54% | Font: 147.30%; FIFO: 147.29% | No worthwhile load reduction |
| HPS helper, Bag, percent of one core | 122.20% | Font: 122.68%; FIFO: 121.83% | No worthwhile load reduction |
| Native cycles, unique-frame pacing p50/p95/max, missed VBlanks | Unavailable | Unavailable | Do not infer from publication counts |
| Capture drops added by OBS | 0 | 0 | Capture health passed, not an emulated dropped-frame metric |

Native real-time input and RTC are not deterministic reference replay. Initial
short walking C3/E1 trials had a one-tile mismatch and are excluded, including
their apparent positive delta. The anchored scene snapshots differ only in
player-foot animation at entry. Staged cartridge hashes and saves match the
intended trial before/after; direct ARM fetch/cache readback is unavailable.
No native save-write, soft-reset, unrelated-scene or combined-patch validation
is claimed. These results justify keeping the screened candidates disabled,
not declaring all possible Platinum optimizations exhausted.

After all measurements, a separate 15-second, 199 Hz CPU-clock profile collected
4,668 HPS-helper leaf samples. Symbolization uses the exact accepted renderer
binary. Functions in `SoftRenderer3D` account for 1,409 samples (30.18%); its
cached perspective interior batch alone accounts for 332 (7.11%). Additional
perspective math, command processing and transfer work are recorded individually
in `PLATINUM_HPS_BASELINE_ANALYSIS_V1.json`; overlapping name groups must not be
summed. This is HPS sampling, not an ARM9/ARM7 guest profile or cycle share.
It supports investigating unnecessary game-side graphics submissions before
spending more effort on small CPU-only loop savings. It does not prove that a
particular draw call is removable or authorize a renderer/RTL change.

The top three unfinished investigations are:

1. Trace game-side graphics submissions in the slow outdoor scene and classify
   repeated or provably invisible work. Test visibility/dependency contracts
   before removing a call; no safe call site or gain has yet been established.
2. Census the six-byte strided upload callback at `020a7e00`: compare destination,
   data and reader lifetime to determine whether uploads repeat unnecessarily.
   A redundant-looking transfer may still synchronize another component.
3. Census cartridge request recurrence around `020cd488–020cd4ac`, recording
   actual blocks, consumers and completion semantics. Active FIFO polling is
   not dead code; any cache must fit existing mechanisms and be proven safe.

The font patch's battle-specific native effect is also unmeasured. A future
battle test first needs a qualified native route matching the reference scene;
its reference-entry saving alone is not a reason to enable it.

## font-table-last-colors-reuse — authorized native perceptual screening

The user explicitly authorized testing potentially imperceptible differences and
recording videos on 28 October. This supersedes the historical no-retry/native
restriction for this isolated experiment, without accepting its mismatches.

Menu: 14.6755 control versus 14.6349 patched; Bag: 30.2040 versus 30.0610 screen publications/s. Bag-opening near-black mean: 0.4333s control versus 0.4500s patched. No native gain demonstrated. These are endpoint screen-buffer publication counts, not unique gameplay
FPS, frame-time percentiles or emulated cycles. Native battle benefit remains
unmeasured. The candidate stays disabled.

The cold-boot trial used the same qualified disposable story save, stock 1 GHz,
unchanged rc12 FPGA and accepted Beta2 renderer. Expected original bytes and
the selected virtual-cartridge replacement were guarded; this is not direct
ARM instruction-cache readback. Saves remained exact and OBS added no dropped
frames. No RTL, new HPS service, persistent save-state format or ROM file changed.

Reference audiovisual review: `Platinum_Font_Review.mov` (verified original PCM),
with an AAC convenience copy. Both screens are shown side by side; every scene
repeats with control then candidate audio, without mixing or volume changes.
These deterministic software clips are separate from the native speed tests.
Evidence: `NATIVE_PERCEPTUAL_RESULTS_V1.json`, native trial `PLATINUM_F1`,
`PERCEPTUAL_FONT_CONTROL_V1_STATUS.json`,
`PERCEPTUAL_FONT_CANDIDATE_V1_STATUS.json`, and `Platinum_Font_Review.json`.

## Qualified geometry census and existing prop culling

The next investigation reuses the existing `NDS4MiSTer_2DTrace` sink through a
bounded, read-only extension of the reference frontend. It changes no core,
renderer, FPGA, HPS service or game byte. Across the full 15,600-frame outdoor
replay, all 180 retained golden files remain exact, including screens, audio,
saves, RAM/CPU checkpoints, profiles and instruction totals. Observation covers
frames 15000–15599; the scene remains the previously verified walking route.

| Measurement | Golden replay | Geometry observer |
|---|---:|---:|
| Retained golden files matching | Reference | 180 / 180 |
| Selected ARM9 instruction entries | 98,783,080 | 98,783,080 |
| Selected ARM7 instruction entries | 16,043,379 | 16,043,379 |
| Native speed/pacing measurement | Not part of this unit | Not part of this unit |
| Game patches enabled | None | None |

The 600-frame observation has 300 swap submissions and 5,686,767 normalized
command parameter packets; 4,811,611 occur while DMA is active. Of 299 complete
swap-bounded intervals, 197 payload hashes are distinct and 102 adjacent pairs
match. Partial leading traffic is excluded. Matrix, texture, palette and other
external dependencies still matter; no frame reuse or draw omission is admitted.
The existing geometry-frame counters report 1,075–1,327 vertices and 280–350
polygons (medians 1,284 and 339). These are renderer bookkeeping counters, not
unique animation FPS or guest/native cycle counts.

The leading CPU context is the known word-stream store at `020c4bac`, reached
from `020b2834`, with 842,156 parameter packets. The guarded disassembly shows
that this caller sends an opcode to `04000400`, then calls the word-stream
helper. It is a submission path, not a proof that its payload is redundant.
DMA traffic is deliberately not attributed to the interrupted instruction.

Owned ARM9 instructions at `0201ced8–0201cf73` match the model-box-test
structure described in the pinned decompilation: set model transforms, push/
scale, issue the query, wait for completion, pop and return. The overlay-5 call
at `021e1824` tests the result and branches around the prop draw at `021e1862`.
An independently qualified register census matches all 180 golden files and
records 2,400 complete calls with no partial boundaries: 1,729 return zero and
671 return two. The owned getter at `020bfe80` explicitly masks GXSTAT with 2;
raw success is **2**, not 1. Any replacement must preserve that actual value.
All calls originate at `021e1829` in this scene. This confirms substantial
existing prop culling, rather than a missing off-screen-prop test.

Only four model resource pointers appear, but several are shared by different
instances. Model `022fbe64` returns visible 300 times and hidden 900 times, with
four scale pointers and reused stack position/rotation pointers. Model-pointer
or stack-pointer equality is not a valid visibility-cache key. Actual object
transforms, camera/projection, bounds, viewport and all query side effects must
be captured before proposing a cache.

The first register census stopped on the strict opcode guard: at aligned Thumb
`0201ced8`, the sampler exposes the two-halfword prefetch value `b08db5f0` although
the current instruction is `b5f0`. That run is excluded. The corrected observer
uses `0201ceda`, after the unchanged register push, where R0–R3/LR are intact and
SP is caller-SP minus 20. The byte/mode guard is retained. No failed trace was
used to establish runtime behavior.

A separate owned overlay path at `021e89d0–021e8a97` calculates a map-chunk
position, checks its loaded-valid flag, sets identity rotation/unit scale and
calls the draw helper at `021e8a56`; it then handles props separately. This
matches the decompiled terrain path, which lacks the prop-level box test.
The exact call-site bytes are retained with the decoded overlay identity.
This is a promising **research lead**, not proof that a loaded terrain chunk is
invisible or can safely be skipped. Next census its model/transform inputs and
actual visibility, then prove state effects and a safe patch location. Added
query/round-trip costs could outweigh saved submissions, so native A/B remains
mandatory before recommending a beta.

The next three bounded investigations are terrain-chunk draw/visibility
contracts, complete visibility-query input/state recurrence, and repeated
strided-upload data/reader lifetimes. Cartridge-request recurrence remains
queued. No native session, patch enablement or new beta follows this census.

Evidence: `GEOMETRY_BUILD_V12.json`, `GEOMETRY_OUTDOOR_QUALIFICATION_V1.json`,
`GEOMETRY_OUTDOOR_CENSUS_V1.json`, `GEOMETRY_CALLER_DISASSEMBLY_V1.txt`,
`GEOMETRY_OVERLAY5_CALL_SITES_V1.json`, `TERRAIN_DRAW_DISASSEMBLY_V1.txt`,
`BOXTEST_REGISTER_CENSUS_V1_EXCLUSION.json`,
`BOXTEST_REGISTER_QUALIFICATION_V2.json`, `BOXTEST_REGISTER_FINDINGS_V2.json`
and `BOXTEST_RESULT_DISASSEMBLY_V1.txt`.


## overlay5-terrain-visibility — disabled reference experiment

A terrain-only argument census at the owned overlay-5 call `021e8a56` passes
all 180 retained golden files. It observes 1,200 draws: four render objects,
300 calls each. Every rotation and scale equals the existing overlay's identity
matrix at `021faeb8` and unit vector at `021faea0`. The four model pointers and
positions remain stable in frames 15000–15599. Full-route RAM bus observation
records loading writes, but none to these model headers or constants during
that target window; this does not establish globally unused memory.

The experiment replaces exactly 48 bytes at `021e8a2a`, within the original
terrain function. It calls the game's existing `GFXBoxTest_IsModelInView` with
that chunk's model and transforms, then draws only on a nonzero result. Props
continue through the original independent path. Passing the existing immutable
rotation/scale constants directly frees space previously used for stack copies.
No trampoline, new storage, HPS service, RTL or ROM-file write is involved.
Overlay ID 5, its full decoded hash, game/header/ARM9 identities and all original
bytes are guarded by the existing virtual-cartridge mechanism. The replacement
inherits overlay loading and reloading; it is not keyed by address alone.

| Target-window measurement | Control | Terrain candidate |
|---|---:|---:|
| ARM9 instruction entries | 98,783,080 | 97,162,803 (−1.640%) |
| ARM7 instruction entries | 16,043,379 | 16,043,379 |
| Terrain draw-helper calls | 1,200 | 590 |
| Added terrain box tests | 0 | 1,200 |
| Existing prop tests: hidden / visible | 1,729 / 671 | 1,729 / 671 |
| Native speed / frame-time percentiles | Not measured | Not measured |

The new tests return 610 hidden and 590 visible results. Other draw callers
retain their observed counts. These are reference execution counts, not native
cycles, geometry work saved, unique FPS or a native speedup. Extra synchronous
queries could erase the benefit on hardware.

The full 15,600-frame replay fails the strict gate: six top-screen frames differ
(14357, 14359, 14479, 14481, 14483, 14485), while every bottom screen and the
final save match. All 600 target-window screen pairs match. Of 12,516,274 stereo
samples, 239,992 differ, with maximum channel delta 1,215 and RMS 9.153. Fixed
main-RAM and DTCM checkpoints also differ after normalizing only the exact code
replacement. Removed stack copies and the added graphics query alter execution,
but that is not a blanket explanation or acceptance of all RAM/audio changes.
The differing frames, audio and RAM remain explicit and unaccepted.

The user authorized perceptual experiments, so the next gate is visual review
of the changed frames and an isolated native A/B if the route remains usable.
Cold boot is covered by reference replay; native save/load, reset, additional
transition/overlay and unrelated-scene checks remain pending. The core does not
currently support persistent save states. Nothing is enabled in a default beta.

Evidence: `DRAW_REGISTER_QUALIFICATION_V1.json`, `DRAW_REGISTER_FINDINGS_V1.json`,
`TERRAIN_CONTRACT_QUALIFICATION_V1.json`, `TERRAIN_CONTRACT_FINDINGS_V1.json`,
`TERRAIN_CULL_BUILD_V1.json`, `TERRAIN_CULL_DISASSEMBLY_V1.txt`,
`TERRAIN_CULL_CONTROL_V1_STATUS.json`, `TERRAIN_CULL_CANDIDATE_V1_STATUS.json`,
`TERRAIN_CULL_REFERENCE_FINDINGS_V1.json`, `TERRAIN_CULL_RAM_DIFF_V1.json`.
