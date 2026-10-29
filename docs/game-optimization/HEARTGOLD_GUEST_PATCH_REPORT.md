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
