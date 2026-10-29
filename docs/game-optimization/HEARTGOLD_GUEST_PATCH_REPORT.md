# HeartGold guest-code optimization — 28 October 2026

Status: USA IPKE revision 0 terrain visibility candidate passes bounded native
function checks and improves the longer matched plaza screen by3.07% over the
original image and3.50% over decoded delivery. These are display-throughput
results, not whole-game FPS. Cumulative private HeartGold Beta1 explicitly
selects this patch through its pinned catalog, preserving accepted Platinum
and FFT behavior. Existing beta kits remain unchanged; general defaults stay
disabled.
The current user budget permits timing/RNG/hash drift when the game remains
functional and the result is perceptually acceptable. Keep raw comparisons;
reject broken progression, crashes, corrupted saves and perceptible defects.

## Existing implementation and boundaries

Reuse `tools/standalone_host/fmv/prepare.py` (`VirtualRom`, `read_overlay`),
`hook_guard.py` and `guest_byte_patch.py`. Private manifests select CPU,
ARM/Thumb mode, revision/header/full-ROM/code identity and expected bytes.
Overlays are identified by ID, file ID and complete content hash. The existing
worker streams a virtual cartridge while reset is held, then exits; normal
boot and overlay reloads copy the replacement bytes. Source ROMs stay read-only.
There is no assumed arbitrary live-PC HLE service or spare-memory trampoline.

`tools/game_optimization/replay_oracle.cpp` provides fixed-RTC input replays,
ARM9/ARM7 instruction counts and samples, both screen hashes, per-frame RAM
and save hashes, audio, full checkpoints and opt-in memory/geometry traces.
Reuse `validate_replay_inputs.py`, `compare_replays.py`, `scan_guest_patterns.py`
and the configured native session/capture tools. Reference instruction counts
are not FPGA cycles or a native speed claim. Native cycle attribution, DMA/cart
byte totals and missed-VBlank counts are not supplied by this intake run.

Both DS CPUs, memory, DMA, timing and sound remain FPGA-owned. Ordered graphics
and readback records cross the existing shared-DDR packet/mailbox interface;
the HPS helper renders/composes both screens and publishes complete pairs to
four framebuffer banks. The control window starts at HPS physical `3fc00000`;
complete-pair banks occupy `3fe00000..3fffffff`. See `docs/architecture.md` and
`docs/hybrid-3d-abi.md`. Do not add per-call HPS round trips or change RTL.

Prior guest work includes FFTA2 copy/vertex/decoder investigations and Platinum
copy/FIFO/archive/IRQ/ARM7/terrain studies. Platinum's accepted terrain beta is
the cumulative baseline; its addresses and scene-specific benefits do not
transfer to HeartGold. Historical SoulSilver readback experiments proved that
zero clip-matrix or visibility results can remove the player and furniture.
Those are correctness dependencies, not safe opportunities to skip readbacks.

## Owned input and delivery intake

The complete 128 MiB USA image has SHA-256
`65f02a56842b75aa92d775d56d657a56fe3fa993550b04dc20704ab82d760105`;
352-byte header SHA-1 `1b7be2e5079b10c7122aa048656c1d3a6d6bd0c1`.
The owned 512 KiB save contains only `ff`, so it supplies no existing gameplay
progress. Private copies were verified against remote hashes before and after
transfer. No original ROM or save was modified.

The stored ARM9 is compressed (762,644 bytes; initial decoded main section
1,120,352 bytes). Of 129 ARM9 overlays, 127 are compressed; only tiny overlays
35 and 124 are uncompressed. The default same-layout adapter still rejects
compressed main code. The new explicit overlay-only delivery mode below reuses
FMV relocation while preserving the stored ARM9; it does not enable main-code
or ARM7 edits on this image. No parallel patch service is introduced.

## First reusable detector pass

The unchanged structural scanner finds ten leads across main/autoload sections:
three nibble-arithmetic sequences, ARM9 and ARM7 fixed-width mask walks, one
branch-heavy halfword copy, three stack-file-header halfword reads, and one
carry-derived zero multiply. These are static matches only. The scanner does
not cover overlays or all ten optimization families; zero profile weight here
means no profile was supplied, not that a routine never runs.

Private evidence: `OWNED_INPUT_TRANSFER_V1.json`, `OWNED_IDENTITY_V1.json`,
`STATIC_PATTERN_SCAN_V1.json` and the `BOOT_INTAKE_V*` jobs/captures.
The initial input routes are exploratory menu navigation, not qualified
outdoor/transition/battle benchmarks. Establish a real saved checkpoint,
visually verify the route and repeat the control before prioritizing patches.

The oracle now accepts optional validated touch windows through
`NDS_REPLAY_TOUCH_INPUTS`; this extends the same input path and calls the
existing reference-core touch API. No product runtime or FPGA change is
involved. All 29 parser/boundary checks pass. With touch disabled, all 64 files
from the 3,600-frame boot control remain byte-identical. A touch-enabled route
selects No info needed and reaches Oak's introduction; extending it repeats
the first 4,800 frames' screen/RAM/audio output exactly. These are navigation
and harness checks, not a gameplay-performance qualification.

Read-only symbol/navigation reference: [pret/pokeheartgold](https://github.com/pret/pokeheartgold),
pinned at `ce27b413f47f44b16211307426dcf62d8b7031bb`. Its declared USA ROM
SHA-1 matches the owned complete image. No external build or code was run.
Source labels remain leads until checked against the actual disassembly and
trace. The map event and mother script correctly predicted the staircase
transition and Save-button unlock; the 16,800-frame route visually reaches
both. This establishes navigation, not a native performance result.

The first private save route runs 18,000 frames. Frame 16,080 visibly reports
that the game was saved, and the save buffer is stable for the final 2,080
frames. Repeating the entire route from the original blank seed reproduces
all 193 output files exactly. The private generated save has SHA-256
`756f721263a071ea824d64e36d59d0569c1ed8f3d93d84a1f58e8024f0461a05`.
This is a separate disposable save; the user's original remains untouched.
Two separate 3,600-frame cold boots reach the expected downstairs scene with
Save/bag/options retained. All 64 recorded files match on repeat and the save
buffer remains identical to the generated seed. `FIRST_SAVE_SEED_ADMISSION_V1.json`
admits this reference seed. Later native save/reset coverage is recorded below.

## Initial indoor profile

Frames 1,800–3,599 of the qualified cold load show the idle downstairs room,
without movement or menu inputs. The following are **instruction sample
shares**, not FPGA cycle shares or native speedups. The decoded original bytes
for each span match checkpoint 2,400's actual main RAM or ITCM. Evidence:
`INITIAL_INDOOR_PROFILE_V1.json` and `INDOOR_PATTERN_SCAN_V1.json`.

| ARM9 span | Sample share | Evidence and next check |
| --- | ---: | --- |
| `020d47b8..020d47eb` | 4.469% | Indexed halfword copy; census source/destination/length before choosing a replacement |
| `020d4830..020d4857` | 6.151% | Source increments, destination stays fixed; observe the destination before calling this graphics FIFO work |
| `01ff8000..01ff804f` | 3.677% | IME/IE/IF read, selected interrupt acknowledgement and handler dispatch; necessary synchronization, not a proven idle loop |

The ARM9 mask-walk detector covers 1.173% of samples; the ARM7 zero-multiply
sequence covers 0.533%. Other structural matches have no samples in this
specific idle window. This does not reject them in transitions or battles.
Moving-scene and overlay-identity coverage must precede prioritization.

## Measurement status

| Scope | Control | Patched | Conclusion |
| --- | --- | --- | --- |
| Owned image and save | Verified copies | None | Originals preserved |
| Structural detector leads | 10 | None | Execution/semantics still required |
| Save-creation replay | 18,000 frames | Exact repeat | All 193 files identical |
| Cold-load replay | 3,600 frames | Exact repeat | All 64 files identical; private save admitted |
| Native gameplay speed | Not yet measured | Not run | No speedup claimed |

Top three investigations not completed in this intake:

1. Moving outdoor, transition and battle profiles from the qualified seed,
   including runtime arguments/content for the two transfer loops.
2. Compression-aware guarded delivery through the existing virtual image,
   if a measured candidate justifies extending support.
3. Content-complete graphics-work recurrence and overlay hotspot identity,
   preserving matrix/visibility results, IRQ behavior and moving-scene effects.


## Moving outdoor profile and transfer census

The 9,600-frame route cold-loads the qualified private seed, exits the house,
completes the first town dialogue, then walks south and alternates west/east
from frame6,000. Reviewed screenshots show real camera/player movement.
The earlier short doorway route is excluded. Profile frames 6,000–9,599 contain
702,392,065 ARM9 and 112,451,250 ARM7 instruction entries on the original image.
These are reference counts, not native cycles. All 154 baseline files match the
unchanged transfer/geometry observer replay.

A600-frame guarded census pairs267,980 calls across535,960 events. The halfword
copy makes147,600 main-RAM-to-OAM calls totaling592,800 bytes, only lengths2/6.
The word stream makes120,380 calls, including10,242 zero-length calls; all 110,138
nonempty calls send6,097,932 bytes to geometry FIFO04000400. Its sources are
main RAM or DTCM. These are real sprite/geometry submissions, not ordinary
memcpy or proven redundant payloads. The generic auditor now permits complete
loaded-code snapshots when the stack mapping varies, retaining opcode, mode,
register, pairing and exact observer qualification. Twelve tests pass; the old
1,206,700-event Platinum census retains identical function results.

The geometry observer records6,554,000 normalized command-parameter packets;
5,131,175 occur during DMA. All 298 complete swap intervals have distinct payload
hashes. Whole-frame reuse is unsupported by this trace. Repeated viewport and
material assignments remain leads only. Renderer counters span1,254–1,490
vertices and 356–416 polygons; these are bookkeeping counts, not native FPS.

All 28 profile bins above2% are classified in
`OUTDOOR_HOTSPOT_CLASSIFICATION_V1.json`. Each bin is256 bytes, not a function:

| ARM9 bin | Samples | Classification |
|---|---:|---|
|020d4800|9.306%|Geometry FIFO stream|
|01ff8000|8.628%|IRQ selection/acknowledgement and scheduling|
|020d1000|5.647%|Interrupt-handler mask traversal|
|020d9c00|4.657%|DIV/SQRT context save/restore|
|020d4700|3.570%|Tiny OAM field copies|
|021fb500|3.384%|Overlay1 two-callback field task dispatcher|
|01ff8100|3.379%|IRQ thread context switching|
|020d3a00|2.538%|CPSR interrupt-mask primitives|
|021fa500|2.444%|Overlay1 model-load queue/compaction|
|020d2300|2.252%|CPU context and message-queue routines|
|020d1f00|2.163%|Runnable-thread selection/wakeup|
|020d1900|2.053%|Scheduler/context-switch decisions|

ARM7 bins are sound-track updates037fdb00(7.544%)/037fdc00(5.213%), word
copy037faf00(7.165%), timer/volume037fbd00(4.607%)/037fbc00(3.739%),
channel processing037fc600(3.746%)/037fc400(3.575%)/037fc300(3.563%)/
037fc500(2.774%)/037fc200(2.256%), LFO037fcd00(3.599%), track lookup
037fda00(3.204%), sequence037fcf00(3.043%), interrupt-mask037fad00(2.772%),
channel status037fba00(2.377%), and BIOS service dispatch00001000(2.790%).
The BIOS bin uses observed opcodes; it is outside the owned ROM sections.
The WRAM code bins match the actual shared-WRAM backing at checkpoint6,000.
A prior diagnostic compared the wrong backing array; that result is excluded.

Owned code shows the DIV/SQRT context routines accessing04000280–040002bc,
matching pinned NitroSDK context code and the ITCM callers. They are not cache
maintenance or dead arithmetic. The two overlay hotspots match overlay1's full
decoded identity and loaded code. Remaining decompression, FS, debug-work and
battle coverage is not declared exhausted by this outdoor profile.

## Compressed overlay delivery control

`append-decoded-overlays-v1` extends the existing guarded virtual loader and
FMV FAT/overlay relocation. It pins both stored and decoded hashes, ID, file ID,
mode, exact bytes and protected constants. It rejects unsupported flags, shared
file IDs, overlapping/protected edits and mixed CPU/main-code requests.
Fifty admission/worker tests pass. Both stored CPU images remain unchanged;
the original ROM/save files are untouched and no HPS service or RTL is added.

For owned overlay1, the virtual image grows from 134,217,728 to 134,366,208 bytes,
appending 148,064 decoded bytes plus alignment. Only18 original metadata bytes
change. The actual disposable worker reproduces the complete pinned image.
Normal overlay-file loading carries the code; it is never keyed by address
alone. SDK overlay loading invalidates instruction/data ranges, conditionally
decompresses and flushes the image. Later native reset/loading checks pass;
no direct native guest-RAM or cache/fetch probe was added.

The identical-code control has timing differences versus original compression:
4,550 top and 22 bottom frame hashes differ, and 6,911,734 of 7,702,322 stereo
samples differ. Save data matches; all eight loaded-overlay checkpoints match
the original decoded body. Eight reviewed scene pairs preserve navigation and
movement. Its repeat matches all 154 files. This is a bounded functional research
control, not bit-exactness, inaudibility or full-game/lifecycle acceptance.

## overlay1-terrain-visibility — disabled candidate

Owned `MapLoadManager_RenderLoadedMap` at 021f595c checks the loaded-valid flag,
then draws terrain. Props independently use the existing model visibility helper
at 0201f990. The guarded outdoor contract captures1,158 terrain calls across four
objects with exact unit scale/identity rotation; positions vary as chunks move.
Existing prop results are raw0 or2. No visibility result is fabricated or cached.

Replace48 Thumb bytes at 021f5996 inside overlay1 with a call to that same helper,
then call the original draw helper0201f554 only on nonzero. Reuse existing
immutable constants instead of stack copies to fit the original extent. Props
retain their independent code path. No trampoline, spare-memory allocation or
new scratch is used. The manifest guards the exact original bytes, literal
pointers, scale/rotation contents and complete overlay identities.

| Measurement | Decoded-delivery control | Terrain candidate |
|---|---:|---:|
|ARM9 instruction entries,frames 6000–9599|702,428,642|671,827,915(−4.356%)|
|ARM7 instruction entries,same window|112,449,590|112,445,779|
|Terrain draws,frames 6000–6599|1,158|430|
|Added terrain box tests|0|1,158|
|Complete prop box tests|5,124|5,121|
|Final save buffer|Reference|Exact|
|Native throughput/HPS load|See native screening below|See native screening below|

The candidate's own terrain queries reject728 draws (62.867%) and accept430.
The control has one leading partial prop return excluded from pairing; timing
shifts the fixed-window workload. Do not claim identical prop call counts.
Its observer control preserves all 154 earlier control files. The candidate
executes the full patched overlay identity on 8,663 frames; the remaining937
precede its recognition. The constant write trace has52 nonmatching writes
before the first complete overlay identity, caused by earlier address use;
none occur afterward, and no watched writes occur in the target window.
These addresses are existing constants, not unused storage.

All 9,600 candidate frames complete and the save matches. There are4,315 top/
8 bottom frame differences,6,053,116 differing stereo samples, and main-RAM,
DTCM and ARM7-WRAM differences. ITCM/shared-WRAM hashes match. Eight reviewed
full-resolution scene pairs retain the player, terrain, house, dialogue and
movement; small animation/NPC phase differences remain. Audio maximum delta
40,337 and RMS3,324.343 are same-index comparisons, not an audibility verdict.
The legacy runner label `rejected_replay_mismatch` reports strict exactness;
the user's functional budget permits continued investigation with raw evidence.

The reference result justified the native screening below. Release defaults
remain disabled outside explicit private catalog selection. Native checks
are bounded; no full-game or human audiovisual approval is claimed.
The core still lacks persistent save states; no save-state format changed.

Evidence: `OUTDOOR_OBSERVER_QUALIFICATION_V1.json`,
`OUTDOOR_TRANSFER_AUDIT_V1.json`, `OUTDOOR_GEOMETRY_CENSUS_V1.json`,
`OUTDOOR_SOURCE_REFERENCE_PINS_V2.json`, `TERRAIN_CONTRACT_FINDINGS_V1.json`,
`TERRAIN_CULL_BUILD_V1.json`, `OVERLAY1_WORKER_QUALIFICATION_V1.json`,
`OVERLAY1_DELIVERY_QUALIFICATION_V1.json`, `TERRAIN_REFERENCE_FINDINGS_V2.json`
and `TERRAIN_BEFORE_AFTER_V1.csv`.

Next three gameplay investigations: model-load queue
empty-tail work with live callback/record contracts; repeated OAM payload and
reader lifetimes; representative starter/battle and transition profiles for
remaining decompression, archive and ARM7 sound work. The existing08:00 Central
handoff keeps the last qualified cumulative beta until a useful new one passes.

## Native screen and bounded lifecycle

Six cold sessions reuse the exact accepted host, renderer and rc12 FPGA at
stock1GHz. Original, decoded-overlay delivery control and terrain candidate
first run from the same indoor save; three further sessions cold-load one
new private plaza save written by the candidate. All staged header/byte guards
pass. A source-header guard is kept separate from the changed staged header.

|45-second plaza measurement|Original|Delivery control|Terrain candidate|
|---|---:|---:|---:|
|Completed screen publications/s|18.6837|18.6071|19.2577|
|Published frame identifiers/s|59.8234|59.7736|59.7922|
|Host CPU, percent of one core|3.33|3.38|3.42|
|Renderer CPU, percent of one core|160.92|160.96|161.85|
|Save after measurement|Exact seed|Exact seed|Exact seed|

The longer matched standing screen improves3.072% over original and3.497%
over identical-code decoded delivery. The earlier15-second standing intervals
show18.9018/18.8055/19.8759 publications/s. Report the longer result as the
conservative screen; do not pool unequal windows into a whole-game guarantee.
Indoor original/candidate rates are59.6416/59.6307, effectively unchanged.
Publications are not unique animation FPS or game-clock acceleration. Native
emulated cycles, missed VBlanks and frame-time percentiles are unavailable.

Identical timed walking inputs end at different positions even in the two
unchanged-code controls. Their18.8662/19.7210/21.7512 publications/s are
observations, not equal-work speed estimates. The recorded moving footage
is useful for function and visual/audio review, not a claimed walking speedup.
All six captures report zero added render/output drops.

The candidate's soft reset returns through startup and Continue into the
original indoor seed, then repeats the opening town route. Its new native Save
returns to normal field control and is read back after clean exit. Original,
delivery and candidate cold Continue all load the expected plaza. Candidate
house entry, Bag open, both menu-close levels and return outdoors work. Saves
remain unchanged during the timed measurements. No original ROM/save is used
as a write destination. These are bounded checks, not full-game/battle proof.

A separate3600-frame replay never enters the outdoor target scene. It finishes
indoors with the exact save and expected room/player/menu in all three reviewed
checkpoint pairs. Raw differences remain:6 top/7 bottom frames, main RAM, DTCM
and ARM7 WRAM, and2,103,396/2,888,368 stereo samples (max25,616,RMS3,184.534).
The strict runner's mismatch label is not a rejection under the functional
budget. Native review copies preserve original video and game-audio packets
and timestamps; OBS track0 is silent, so track1 is selected without reencoding.
No inaudibility or human full-motion approval is inferred from levels or stills.

The bounded gain supports the separately installed cumulative private beta.
The existing loader now supports an explicitly pinned embedded catalog,
preserving accepted Platinum selection without a new HPS service. Exact
previously qualified whole-image hashes match for HeartGold, Platinum,
Portrait, Ni no Kuni and NSMB. All128 loader tests pass, including malformed,
ambiguous, unknown and wrong-revision selection cases. Existing single-manifest
behavior and ordinary FMV/NSMB fallback remain intact.

Evidence: `NATIVE_TERRAIN_SCREEN_FINDINGS_V1.json`,
`NATIVE_TERRAIN_REPLICATION_FINDINGS_V1.json`,
`NATIVE_TERRAIN_REPLICATION_BEFORE_AFTER_V1.csv`,
`NATIVE_TERRAIN_LIFECYCLE_SCREEN_V1.json`,
`NATIVE_PLAZA_RELOAD_QUALIFICATION_V1.json`, `TERRAIN_INDOOR_FINDINGS_V1.json`.

## Cumulative private Beta1

`NDS4MiSTer_HeartGold_Beta1_20261029.zip` has SHA-256
`7cce7b28151d562722924e83a573c6bf28eb817ae68bafe89c70175c25d4d657`.
The separate `NDS_HeartGold_Beta1` launcher uses the same accepted host, renderer
and rc12 FPGA; the archive includes corresponding source and build provenance.
Runtime source is `c0fd3d7ddaea5ad596c964fc18ae028356fcf4ce`.
The validation harness additionally permits a configured pinned catalog
filename in `9cca264`; this does not change the packaged runtime.

The actual installed launcher cold-loads HeartGold's candidate-written plaza
save with the expected staged header and48 replacement bytes. House entry,
Bag open/close, return outdoors and clean exit work; the QA save is unchanged.
A second launch selects Platinum's retained48-byte patch, cold-loads its
Twinleaf save and responds to bounded walking input. Both use separate save
aliases. The beta retains the documented Platinum first-battle trajectory
difference; this packaging pass makes no new full-battle claim.

This is a testable private beta under the user's functional budget. No human
full-motion/audio verdict is claimed for HeartGold. The same tested terrain
algorithm and complete image are retained, so the existing native gain and
review clips apply; an unchanged benchmark was not repeated for packaging.
See `BETA1_STREAM_VALIDATION.json`, `BETA1_INSTALL.json`,
`BETA1_NATIVE_LIFECYCLE_V1.json` and `BETA1_ARCHIVE_QUALIFICATION_V1.json`.
Continue HeartGold's model-load queue, OAM lifetime and starter/battle profiling
work; this beta does not close the game's evidence-based completion gate.


## overlay1-empty-tail-exit — parked after native screen

The owned 90-byte compaction block at 021fa5c2 is identical to Platinum's
independently guarded overlay 5 block. Replace 54 Thumb bytes at 021fa5d4 to
stop rescanning after an unsuccessful search proves the tail is empty. The
patch preserves record order/stale payloads, final reset, registers and flags;
it uses no scratch, trampoline or service. Full overlay/game/expected-byte
checks remain mandatory. The shared signature is a lead, not automatic approval.

299 paired calls show 64 empty records. The full-route write watch observes
capacity/record initialization ending at frame 1986; later IRQ activity updates
a separate array and lock. This bounded contract plus 1,338 synthetic cases
supports the trial, without claiming all possible concurrency is modeled.

The 9,600-frame comparison retains terrain visibility in both arms and removes
3.41349% of selected ARM9 instruction entries (671,827,915 to 648,895,132).
All top frames, final save and 41 checkpoint RAM files outside the new patch
match. One bottom frame and 3,660/7,702,322 stereo samples differ. These raw
differences are retained under the functional budget and do not reject the
trial. The cumulative comparison tool now authenticates retained patch bytes
against the full original overlay before normalizing only the new candidate.

Native screening used the same private plaza save, stock 1 GHz, unchanged
host/renderer/FPGA and ten-second idle warmup after a verified scene anchor.
The order was control, candidate, control, each a separate cold launch:

| Arm | Measured seconds | Complete publications/s | Renderer CPU, one core |
|---|---:|---:|---:|
| A1 — control | 45.083 | 19.6969 | 161.81% |
| B1 — candidate | 45.107 | 19.3983 | 162.17% |
| A2 — control | 45.040 | 19.3827 | 162.26% |

The candidate is -0.724% versus the two-control
mean. It does not satisfy the predeclared 1% gain over each control and their
mean. Keep it disabled: no useful native plaza benefit was demonstrated.
This small screen does not prove a general slowdown. Publications are not
unique animation FPS; native cycles, missed VBlanks and p50/p95 remain
unavailable. The scene stayed intact, captures had no drops, saves stayed
unchanged and all three owned hosts exited cleanly. Further lifecycle and
human listening checks were not pursued for this no-gain candidate.

Evidence: `MODEL_QUEUE_REFERENCE_FINDINGS_V1.json`,
`MODEL_QUEUE_NATIVE_FINDINGS_V1.json`, `MODEL_QUEUE_NATIVE_BEFORE_AFTER_V1.csv`.
HeartGold Beta1 and all previously accepted archives remain unchanged.

Next three leads: repeated OAM payloads with actual reader lifetimes;
starter/battle profiling from an isolated save; transition/archive/decompression
work in supported overlays. Do not repeat this queue screen unchanged.


## OAM source recurrence and reset contract

The terrain-only 9,600-frame route was repeated with the existing guarded
memory observer, without adding emulator callbacks or changing the game.
All 155 non-observer baseline files match exactly. The 600-frame observation
window contains 300 upload/reset groups for each sprite manager. The actual
outer call is overlay 1 at `021e590e`, returning to `021e5913`; its loaded
bytes match the owned overlay. The copy loops themselves remain in compressed
main code. The current loader does not yet support patching that code.

`audit_staged_buffers.py` reuses the existing snapshot reader. Its fixture
supplies all sites, code hashes, instance addresses, phases and strided fields;
there are no HeartGold addresses or OAM layouts in the tool. Nine focused tests
cover recurrence, reset differences and rejection of incomplete groups, wrong
order/code/instances, unguarded sites and invalid field extents.

| Observed source workload | Main engine | Sub engine |
|---|---:|---:|
| Sprite slots owned | 4–127 | 0–123 |
| Affine matrices owned | 1–30 | 0–30 |
| Used sprites / affine matrices | 0 / 0 | 19 / 4 |
| Six-byte attribute uploads | 37,200 | 37,200 |
| Two-byte affine uploads | 36,000 | 37,200 |
| Compared fields matching previous upload | 100% | 100% |
| Attribute records changed by reset | 0 | 5,700 |

This accounts for the earlier 147,600 tiny copies and 592,800 payload bytes.
All declared source fields remain unchanged during upload. Reset changes the
first halfword of 19 sub-engine records each frame and resets allocation
cursors; producers rebuild the same visible menu for the next upload. Repeated
payloads alone do not prove that destination writes or buffer reset can be
removed. No native gain is claimed from this census.

The existing implementation at `020b7cb8` branches on instance offset `14`.
Its bulk path flushes and uploads a contiguous range, and its reset routine
uses a different fill path. Enabling this for both managers is unsafe as stated:
the main sprite range also spans affine matrix 31, which this manager does not
own. The sub range exactly covers its owned matrices and is a supported lead
for a separate trial. Before patching, qualify reset/cursor/cache/DMA behavior
and find a guarded in-place overlay replacement. The 36-byte initializer at
`021e6178` and its call at `021e5a6e` are known code, not spare memory. Do not
claim neighboring alignment, heap or BSS as free trampoline space.

Evidence: `OAM_OBSERVER_QUALIFICATION_V1.json`,
`OAM_STAGED_BUFFER_CENSUS_V1.json`, `OAM_SOURCE_LIFETIME_FINDINGS_V1.json`.
No game patch or native session was added in this investigation. Keep Beta1
unchanged. Next: qualify the sub-only bulk path; investigate an empty-main
skip only with destination/transition proof; extend starter/battle coverage.


## Sub-only OAM bulk trial — disabled

The field initializer now has a separately toggleable, disabled manifest trial
for the existing sub-screen bulk upload/reset path. The sub allocation owns
all 992 contiguous bytes (sprite slots 0–123, affine matrices 0–30). Main bulk
remains disabled because its span would include unowned affine matrix 31.

The atomic extent `021e5a6e..021e619c` changes the sole direct call and a
38-byte initializer; intervening bytes remain unchanged. The initializer uses
two padding bytes at `021e6176`. A complete 9,600-frame write/fetch trace
shows no execution there while the authenticated field overlay is present,
and only the expected same-code reload writes. Earlier boot code does execute
that address: address-only patching or a global opcode watch would be wrong.
The first unrestricted context observer stopped at that earlier overlay; it
was excluded as an observer configuration failure. Restricted field snapshots
at frames 942/1958 match the owned code, and all 156 prior output files match.

Owned constructor, cache and DMA routines are authenticated. Thirty-two
synthetic constructor cases execute the real module initialization, allocation
wrappers and fill routines with a modeled heap allocation. R0, R2–R12,
SP/LR/PC/CPSR and mapped memory match except the intended sub flag, R1
(which the next callee overwrites), and one dead saved-return word at SP−28.
No persistent scratch or new heap allocation is added. Allocation failures,
async/cache interleavings and full-game indirect references are not proved.
The source is four-byte, not cache-line aligned; existing flush/invalidate
operations cover neighboring line bytes. Do not generalize this trial into an
arbitrary safe DMA substitution.

The candidate completes the same 9,600-frame route. All top frames and the
final save match; one bottom frame differs. Eight checkpoint pairs preserve
the visible player/map/menu. RAM changes and 1,762,724 of 7,702,322 stereo
sample differences remain explicit under the functional budget. Selected
ARM9 instruction entries fall 2.20598%, from 671,827,915 to 657,007,512.
That is a reference-work metric, not native speed.

| Arm | Variant | Seconds | Complete publications/s |
|---|---|---:|---:|
| A1 | control | 45.036 | 19.7618 |
| B1 | candidate | 45.097 | 19.6466 |
| A2 | control | 45.073 | 19.4128 |

Candidate versus the two-control mean: +0.303%.
It fails the predeclared 1% gain over both controls and their mean, so keep it
disabled. No useful native plaza benefit is demonstrated; this does not prove
a general slowdown. The three cold sessions preserve the private save,
verified patch bytes and scene, with zero capture drops and clean exits.
Native cycles, missed VBlanks and frame-time percentiles remain unavailable.
No wider lifecycle, save-state or human listening approval is claimed for this
no-gain candidate. The raw differences were not the rejection reason.

Evidence: `OAM_BULK_REFERENCE_FINDINGS_V1.json`,
`OAM_BULK_NATIVE_FINDINGS_V1.json`, `OAM_BULK_NATIVE_BEFORE_AFTER_V1.csv`,
`OAM_BULK_NATIVE_SCENE_REVIEW_V1.json`. Existing HeartGold Beta1 is unchanged.

Next three leads: profile private starter/battle progression; examine
transition/archive/decompression work in supported overlays; investigate an
empty-main-manager skip only after destination/transition liveness is proved.
Do not repeat this same bulk or queue plaza screen unchanged.

## Starter checkpoint and native baseline — 29 October 2026

The retained Beta1 completes Elm's introduction and the Chikorita selection
sequence on the native core, including inspection, zoom, confirmation, return
to the lab and the nickname prompt. Nicknaming was declined. All saves use the
separate Starter1 alias and the normal game UI. Original saves remain untouched.
The lab and machine-approach checkpoints cold-load on hardware. Both mirrored
save banks have valid main/PC chunk CRCs; choose the newest complete bank rather
than assuming bank zero. The first lab inspection made that wrong assumption;
the raw save was preserved and the inspection corrected, with no game failure.

An original-ROM replay opens overlay61 from the machine checkpoint. Repeating
3,600 frames reproduces all 80 output files exactly, including the unchanged
save. Full decoded overlay61 bytes match at three selected-window checkpoints
and the final RAM snapshot. Its address overlaps field overlay1, so the field
patch must never be selected by address alone. The selected 1,800-frame profile
contains 87,223,580 ARM9 and 55,214,651 ARM7 instruction entries. The existing
scanner flags the shared halfword copy (14.13% of ARM9 samples) and interrupt
mask walk (8.51%); no new structural match occurs in overlay61. These shares
measure instructions, not cycles, and do not establish a safe deletion.

| Measurement | Retained Beta1 starter idle | New candidate |
|---|---:|---:|
| Native observation duration | 30.044 s | None |
| Complete screen-pair publications/s | 14.079 | None |
| Published frame-identifier advance/s | 59.845 | None |
| Renderer CPU, percent of one core | 161.96% | None |
| Host CPU, percent of one core | 2.93% | None |
| OBS render/output drops | 0 / 0 | None |

The light reference CPU workload does not translate into fast native display
publication. This suggests renderer/submission work is the stronger lead than
another tiny copy-loop rewrite; it is not a causal native profile or a claim
about unique animation FPS. Keep the turntable, rocking, selection and camera
animations intact. Source hints about redundant matrices or manager allocation
must be authenticated at executed sites before proposing changes.

The selection video preserves the original video and game-audio packets and
timestamps. Sampled frames show the expected sequence; no human audiovisual
approval or first-battle qualification is inferred. Raw oracle frame files are
BGRA8888 despite their `.rgba` suffix. A first contact sheet swapped red/blue;
the corrected V2 sheet uses the renderer's documented `ExpandColor` format.
Raw hashes and replay comparisons were unaffected. Do not attribute that
preview-color error to game behavior or timing.

Evidence: `NATIVE_LAB_RELOAD_QUALIFICATION_V1.json`,
`NATIVE_MACHINE_RELOAD_QUALIFICATION_V1.json`,
`STARTER_OPEN_REFERENCE_QUALIFICATION_V1.json`, `STARTER_PROFILE_SCREEN_V1.json`,
`STARTER_NATIVE_BASELINE_FINDINGS_V1.json`, and
`HeartGold_Beta1_starter_selection_review.mp4`. No new patch or beta is claimed.

The existing geometry observer is neutral: all 80 ordinary replay outputs
still match. Its 60-frame window contains 444,349 events and 29 complete
swap intervals. Only four distinct command/parameter streams occur; 25 of 28
adjacent comparisons match. Each flush reports 2,760 vertices and 1,014
polygons. These are the existing post-cull/clip counters, not a count of every
submitted primitive. All observed polygon-attribute face masks are 2 and alpha
is 31, so a blanket two-sided-geometry optimization is not established.

The resulting lead is an idle-only draw gate that retains the previous 3D
frame when the visible animation phase is unchanged. First rendering,
turntable light changes, input, rocking, camera motion, sprite updates and
scene exits must remain correct. Command recurrence does not prove texture,
palette or other external dependencies are unchanged, nor that native reuse
works in this application. Authenticate those dependencies and safe code
placement before trialing a patch. The source field `work->frame` stores the
user's window-frame style; it is not spare scratch or an animation counter.
Evidence: `STARTER_GEOMETRY_OBSERVER_QUALIFICATION_V1.json`,
`STARTER_GEOMETRY_CENSUS_V1.json`, `STARTER_GRAPHICS_LEAD_V1.json`.

Next three leads: qualify the idle-only unchanged-frame gate; use the normally
saved post-Chikorita checkpoint for first-battle profiling; examine transition
and decompression work in supported overlays. HeartGold remains active.

The post-selection normal save also cold-loads in the original reference and
native Beta1. The native party screen shows one male Chikorita at level 5 with
20/20 HP. This is bounded save/progression and menu coverage, not a battle test.
The private seed SHA-256 is
`7a6f75079357c38569ce2ab54c1fc05a86abb5305f294d95072c98922c20e0c2`.


## Starter identical-redraw patch: native qualification (V9)

The new ARM9 Thumb patch removes redundant drawing from the starter picker's
idle state. It uses the existing overlay loader and an 88-byte replacement in
overlay 61, with no new memory, HPS service, FPGA change, or ROM-file write.
Main state 5 plus selection 0 identifies the stable view; all active selections,
rotations, camera changes, sprite updates and exits retain their original draw
path. The animation counter still advances normally. An authenticated 104-tick
material animation and a full-cycle geometry census identify the boundaries:
retain phases 0/7 modulo8 and omit only the 78 previously identical phases.
The extra phase 0 draw is necessary at the cycle wrap.

The owned resource is member 7 of a/0/8/2, SHA-256
`40d17d989bb118f908404cc46a5ab17f4aa85c47bf5c1b0eac68e6d128c0c478`.
The whole-ROM identity pins this asset as well as the code. The patch repacks
the existing three-ball reset and precomputes the fixed animation bound, then
gates the draw call. It preserves the explicit zero return: the draw helper's
final void callee happens to leave R0=1. Reusing that register as the app return
would incorrectly finish the application. No unused-memory claim is involved.

The existing instruction harness passes 4,680 cases. Both framebuffer hashes
match on every frame in the 3,600-frame idle comparison and the 8,400-frame
selection lifecycle. The latter covers all species, both rotation directions,
zoom, two cancellations, choice and overlay unload back into the lab. The
matched 3,600-frame off-target control/candidate match every output file.
Comparison against an original-ROM off-target run includes retained terrain
and delivery differences; those are not attributed to the new starter gate.
Raw RAM/audio/timestamp differences remain recorded under the approved
functional budget. The legacy comparator's strict mismatch label is retained
as evidence, not used as the current acceptance decision.

| Native starter idle, stock 1GHz | Control A1 | Candidate B1 | Control A2 |
|---|---:|---:|---:|
| Observation seconds | 30.048 | 30.021 | 30.040 |
| Complete screen-pair publications/s | 14.177 | 43.170 | 14.248 |
| Frame-identifier advance/s | 59.838 | 59.859 | 59.854 |
| Renderer CPU, percent of one core | 161.84% | 109.82% | 162.09% |
| Host CPU, percent of one core | 3.03% | 3.26% | 2.93% |

Publication throughput is 3.037 times the control mean,
and renderer CPU falls 32.19%.
This is not a whole-game or unique-animation FPS gain. The existing renderer
can reuse unchanged render state when the game avoids unnecessary swaps;
its implementation and settings remain unchanged. Four lamp regions in native
video show a dominant cycle of 3.467 seconds for A1 and 3.483 seconds for B1,
within one 60Hz video sample. This checks the cycle, not all motion or latency.
The idle reference segment executes 50.59% fewer ARM9 instructions; instruction
entries are not native cycles. Per-frame native cycle/p50/p95 data was not added.

Native recordings cover every starter, both directions, zoom/backout, choice,
return to the lab and nickname decline. A normal private save passes both-bank
CRC/counter checks. Soft reset reaches the game boot, cold Continue restores
the lab and follower, and the party shows male Chikorita, level 5, 20/20 HP.
Returning to the field and exiting preserve that save. Original saves and
accepted betas are preserved separately. No human full-motion/audio verdict
or persistent core save-state support is claimed.

The new patch remains individually disabled by default in the research
manifest; a pinned private catalog can explicitly select it alongside terrain.
Queue compaction and sub-OAM bulk remain parked. Evidence includes
`STARTER_DRAW_NATIVE_FINDINGS_V1.json`, `STARTER_DRAW_BEFORE_AFTER_V1.csv`,
the idle/lifecycle/off-target reviews, and `HeartGold_starter_draw_candidate_review.mp4`.

Next three investigations: first-battle rendering/submission hotspots from the
normal post-starter save; supported transition/decompression work; other
application states with a complete unchanged-state contract. The earlier
instruction-only copy/queue/OAM results are not native speed evidence.
HeartGold remains active; the queue completion gate is not met.
