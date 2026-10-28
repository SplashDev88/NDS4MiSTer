# Pokémon Platinum guest-code optimization — 27 October 2026

Platinum became the sole active target when the user explicitly advanced from
FFT due diminishing returns. Use exact rc12 with cumulative accepted changes;
preserve the earlier player-character and furniture fixes. Historical PBOX
binaries, timings and room screenshots are context, not the current baseline.
No guest patch is enabled and no new speed gain is claimed.

The owned local ROM is USA CPUE revision 1, 128 MiB, SHA-256
`fbce4c4def0c7797f8dd238a3d7a5e48b4a7e3abd86890ac65f6321cef781bdb`.
The identity-only manifest is `platinum-cpue-r1.json`. Original ROM and saves
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
and actual arguments; other hotspots still require them. A fixed-destination word stream must not be treated
as ordinary memcpy, nor a large interrupt sample share as removable dead work.

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

The first concrete candidate to investigate is branch compaction of the word
stream while retaining every ordered word load and FIFO write. Its original
control flow accounts for `6 * words + 8 * calls` instruction entries. A
proposed predicated loop would account for `4 * words + 6 * calls`, a nominal
4,390,320 fewer entries (1.765% of this selected ARM9 workload), assuming
unchanged calls and timing behavior. This is arithmetic from the unpatched
trace, not a tested patch, native cycle estimate or measured speedup. Synthetic
equivalence, whole-game exactness and lifecycle/native gates remain required.

Evidence: `TRANSFER_CALL_FINDINGS_V2.json`,
`TRANSFER_CALL_AUDIT_FIXTURE_V2.json` and
`TRANSFER_GUARDED_V1_COMPARISON.json`. V1 findings retained DTCM sources as
unclassified; V2 labels them using the mapped ARM9 DTCM range without rerunning
or changing the replay. No patch or scratch allocation has been installed.

| Measurement | Baseline | Candidate |
|---|---|---|
| Exact ROM and private seed identity | Verified and unchanged | No candidate |
| Bounded bedroom/menu replay | 6,000 frames, exact independent repeat | Not run |
| ARM9/ARM7 reference instruction entries, frames 4200–5999 | 248,802,085 / 45,859,032 | Not run |
| Native speed, pacing and audio | Not measured in this workflow | Not measured |
| Golden framebuffer/RAM/audio/save comparison | All required files match; all 100 outputs match | Not run |
| Transition, battle, save-write/reload, reset coverage | Pending | Not run |

Private evidence: `platinum-optimization-20261027/INPUTS_V1.json`,
`STATIC_PATTERN_SCREEN_V1.json`, `ROOM_ROUTE_V4_COMPLETE_REPEAT_AUDIT.json`,
`REPLAY_SCENE_REVIEW_V1.json`, `INITIAL_PROFILE_SCREEN_V1.json`,
`STATIC_ARM9_HOTSPOT_LEADS_V1.txt` and `WORKFLOW.json`. The last verified
cumulative beta remains FFTA2 Beta2 until a Platinum change qualifies.

Next three investigations:

1. Test the guarded word-stream branch-compaction proposal with the existing
   synthetic runner and virtual in-memory loader, preserving every ordered
   load/FIFO write. Reject any whole-route output mismatch or absent native gain.
2. Classify interrupt/context costs and remaining ARM7 bins from actual
   events; do not remove scheduler, sound or hardware-math preservation work
   based on sample share alone.
3. Extend the route to verified transitions, outdoor movement and battle;
   identify loaded overlays and asset recurrence with the existing observers.

No RTL, new HPS service, save-state-format change or non-bit-exact acceptance
is authorized here. No speed improvement or new beta is claimed.
