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

The generic byte-patch path currently rejects overlays. The existing FMV
`prepare.assemble` path already decodes overlays by ID, checks source and
instruction identities, reconstructs their virtual cartridge files and updates
the FAT. Reuse and qualify that code if extending generic overlay support;
do not build a parallel loader or apply an address-only RAM patch. It currently
also installs an FMV converter/ITCM extension, so it is not directly a
scratch-free Platinum adapter. Source/load identity, unchanged reconstruction,
reloads, instruction-cache visibility and fallback still need qualification.
No new hardware hook, HPS service or scratch allocation has been introduced.

Evidence: `THRESHOLD_CLASSIFICATION_V1.json`,
`THRESHOLD_PROFILE_OPCODE_AUDIT_V1.json`, `THRESHOLD_SOURCE_PROVENANCE_V1.json`,
`ARM7_CLASSIFICATION_SUPPORT_V1.txt`, `OVERLAY5_GUARDED_FINDINGS_V1.json`,
`OVERLAY5_SAMPLE_EXTENTS_V1.json` and `OVERLAY5_PATCH_DELIVERY_PROPOSAL_V1.json`.

Next three investigations:

1. Qualify reuse of the existing overlay preparation path, then test an empty
   tail early exit. Preserve record order, stale inactive payload bytes,
   observable registers and concurrent producer/IRQ behavior. No unused-memory
   assumption or overlay-lifetime assumption is admitted by these snapshots.
2. Test conditional suppression of proven dummy HBlank callbacks, preserving
   real callbacks, registrations and interrupt semantics. The current capture
   covers only 120 bedroom frames, not arbitrary scenes or overlay reloads.
3. Investigate ARM7 pitch/volume lookup recurrence after tracing actual calls;
   avoid changing audio update cadence. Extend replay coverage to transitions,
   outdoors, battle, save-write/reload and reset before promoting any candidate.

No RTL, new HPS service, save-state-format change or non-bit-exact acceptance
is authorized here. No speed improvement or new beta is claimed.
