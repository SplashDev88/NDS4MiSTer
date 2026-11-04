# Deterministic optimization replay tools

These tools reuse the existing software reference and instruction-entry hook.
They do not write a ROM file, modify hardware, install a service, or provide core
save states. ROMs, saves, recordings and RAM/audio dumps stay in private test
storage and must not be packaged with the core.

Build the ordinary `nds_layer_capture` target in a Ninja build, then run:

```sh
python3 tools/game_optimization/build_replay_oracle.py \
  --build /path/to/ninja-build --out /path/to/private-oracle
```

The private build substitutes an instrumented `ARM.cpp` object at link time;
product binaries and source are untouched. Invocation:

```text
replay_oracle ROM SAVE OUTPUT_DIRECTORY FRAME_COUNT INPUT_TSV WATCH_PC_FILE [PROFILE_START_FRAME]
```

At least 2,601 frames are required to reach both RAM checkpoint events. The
current raw dump filenames are reused, so only frame 2600 remains on disk;
per-frame hashes retain both checkpoints. Input
rows contain first frame, exclusive last frame, and hexadecimal DS key
mask. Watch files contain hexadecimal ARM9 PCs; an empty file disables register
watch logging. The oracle fixes RTC time, disables JIT, uses the existing game
profile selector, and requires complete 3D rendering. It records both screen
hashes, per-frame RAM-region hashes, audio, final saves, selected raw RAM dumps,
and instruction samples. CPU instruction counts are not FPGA cycle counts.

The software renderer's completed framebuffer is **BGRA8888**. Legacy snapshot
names ending in `.rgba` still contain those raw BGRA bytes; the suffix is not a
format declaration. Decode with an explicit BGRA input mode, as
`render_replay_comparison.py` does. Keep the original bytes and hashes unchanged.
Reading them as RGBA swaps red and blue in previews without changing the game.

Preflight each new or extended input file before starting the oracle, then pin
the input and receipt with the job:

```sh
python3 tools/game_optimization/validate_replay_inputs.py /path/to/route.tsv \
  --frames 16800 --output /path/to/input-validation.json
```

The oracle's formatted reader silently stops at malformed tokens, including
comments. The preflight rejects those tokens, incomplete rows, invalid frame
intervals and masks outside the 12 button bits. Blank lines, overlapping button
intervals and zero masks retain their existing semantics. Passing syntax checks
does not prove movement: review actual screenshots and checkpoint state before
labeling a measurement window as active gameplay.

Optional `NDS_REPLAY_TOUCH_INPUTS=/path/to/touch.tsv` adds touch windows to the
same replay. Each row has four decimal fields: `first last_exclusive x y`, with
coordinates in `0..255` and `0..191`. Windows must be ordered, nonoverlapping
and within the run. Blank lines are allowed; comments, extra fields, malformed
numbers and out-of-range coordinates fail before any frame executes. Touch is
released in gaps, and adjacent windows may move the stylus without releasing.
The button format is unchanged. With no touch file or an empty file, no touch
API is called. `touch_inputs.csv` records applied press/movement/release edges.
Pin the touch file alongside the button file and visually verify the result;
coordinate validity does not establish that the intended control was activated.

When creating a new seed through the game's Save command, the oracle's final
`save.bin` is only the buffer at the last requested frame. A successful exit
does not mean the game finished writing it. Require the visible completion
message, a stable save-hash tail, and a separate cold load into the expected
scene. Preserve the original seed and the producing route/job provenance;
repeat the save and cold-load routes before calling the new baseline qualified.
This is in-game save coverage, not an emulator save-state round trip.

Use the same verified ROM/save/input files for both runs. Enable an experimental
renderer only in its candidate process environment. Compare with:

```sh
python3 tools/game_optimization/compare_replays.py /path/to/control /path/to/candidate \
  --output /path/to/comparison.json
```

Missing evidence fails comparison. The software reference complements native
MiSTer testing; it does not establish native speed, output latency, or all-game
correctness. Native experiments must check actual helper flags and visually
confirm the same scene before counting screen publications. Game-specific
inputs and identities belong in `docs/game-optimization`, not these tools.

For guest-code diagnostics, `NDS_REPLAY_VIRTUAL_STDIN=1` accepts an in-memory
cartridge stream: ASCII `VROM`, a little-endian 32-bit size, then exactly that
many bytes and EOF. Use the existing `fmv/prepare.py:VirtualRom` and guarded
`fmv/guest_byte_patch.py` to construct it; the original ROM remains read-only.
The latter supports same-size uncompressed ARM9 main-code patches and
uncompressed ARM9 overlay files. Its default delivery rejects compressed code, autoloads,
scratch and HLE requests. Overlay targets use `target: "arm9.overlay"` with
`overlay` (integer ID), `overlay_ram` (hex address), `overlay_file_id` and
`overlay_sha256` (entire decoded body), alongside the usual CPU, mode,
address, expected/replacement bytes and complete game/ROM identities.
It reuses `prepare.read_overlay`, also used by FMV preparation, to resolve
the original overlay table and FAT. Flagged/compressed files are rejected;
file size, header, FAT and overlay metadata stay unchanged. Only declared
instruction bytes in the virtual file change. Overlays sharing a RAM address
remain distinct targets. Data guards are relative to the selected code body.

An explicit manifest `delivery: "append-decoded-overlays-v1"` reuses the existing
FMV overlay relocation mechanism for compressed ARM9 overlays. Every selected
patch must target `arm9.overlay` and additionally pin `overlay_stored_sha256`.
The normal game/header/full-ROM/ARM9, decoded overlay, ID/file-ID and expected
instruction guards still apply. Other flags, shared overlay file IDs, overlapping
patches, mixed main/ARM7 targets and protected-data changes fail atomically.
Decoded overlay bodies are appended only to the virtual stream; their FAT
extents and compression words are updated, along with capacity, used size and
header CRC. Both original CPU images retain every stored byte, even when ARM9
is compressed. Main-code reconstruction is not supported by this mode.

An identical-byte control for this mode is **not** an identical cartridge image:
file locations, compression work and load timing change. First verify the exact
allowed stream differences, unchanged decoded code and original files, then
run a separate gameplay/lifecycle control. Preserve raw differences and qualify
them under the selected budget before testing a changed-code candidate. Normal
overlay loading/reloading and cache maintenance remain the game's responsibility;
the loader does not install a live RAM or per-call HPS hook.

The native host supports explicit private experiments through its existing
disposable loader. Set `NDS_GUEST_PATCH_MANIFEST` to the manifest path,
`NDS_GUEST_PATCH_SHA256` to its exact SHA-256 and `NDS_GUEST_PATCH_IDS` to a
comma-separated list. Clear all three for the ordinary control. This explicitly
selects diagnostic candidates even if `enabled` is false; it changes no release
defaults. A partial selection, wrong pin, unknown ID or failed identity/byte
guard logs a skip and streams the original image atomically. No disk cache or
movie preparation is composed with this selection. The loader exits before
gameplay; there is no per-call HPS service or additional guest round trip.

A cumulative private kit can pin one embedded catalog using the same three
variables: the manifest path names the catalog, its SHA-256 pins the complete
file, and the IDs value is exactly `@catalog`. The format is
`{"catalog_version":1,"entries":[{"manifest":{...},"patch_ids":["patch-id"]}]}`.
Each entry embeds an ordinary manifest and an explicit selection. The loader
validates the bounded catalog, rejects duplicate header identities and patch
IDs, then routes by game code, revision and the original 352-byte header hash.
The selected manifest still passes every full-ROM, CPU, overlay and original-byte
guard. No entry discovery or cross-game composition occurs. Unknown identities,
invalid catalogs or mismatches skip atomically; the existing explicit
`NDS_GUEST_PATCH_FALLBACK_FMV=1` retains ordinary movie/NSMB dispatch on a skip.
Catalog pinning covers every embedded manifest; it never enables newly found
files. Legacy single-manifest selection remains supported.

Overlay replacements arrive through the game's normal overlay file loads,
including reloads of that file. This is not a live address-only RAM hook.
Qualification must still observe actual overlay loads, reset/reload behavior
and fetch/cache visibility for the game. Begin with an explicitly selected
`expect == replace` diagnostic and verify the complete virtual image is
identical to the original and the full replay matches. Stable repeated file
reads alone do not qualify guest overlay lifecycle or native behavior.

The normal host download holds reset through stream completion, uploads the
staged cartridge and retains the original path/save identity. Initial code
loads therefore see the replacement bytes; this is not a hot patch into a
running instruction cache. Native reset, ROM-switch and gameplay lifecycle
checks still qualify each candidate. `verify_guest_native_stream.py` compares
the actual worker's complete output to previously pinned virtual-image hashes
without creating a ROM file. This is a load-path check, not a native speed test.

The same explicit diagnostic selection also supports uncompressed ARM7 WRAM
autoload payloads. Use `cpu: arm7`, `target: arm7.bin/autoload:N` with the
shared decoder's positive section index, `section_base`, `section_sha256` and
`section_bss_bytes`. The manifest additionally pins `arm7_sha256`,
`arm7_crc32` and `arm7_code_settings_offset`; the existing full-ROM/header and
ARM9 identity gates still apply. The loader requires a contiguous payload and
final copy table, verifies every decoded entry against raw extents, and admits
only a selected section within `037f8000..03810000`. This intentionally does
not support arbitrary aliases, VRAM targets, compressed images or ARM9
autoload patches. Unsupported layouts fall back to the original stream.

Only the selected source bytes change. The original ARM7 boot prefix, table,
sizes, BSS and cartridge layout remain intact; the game performs its normal
copy. This does not claim a live-memory `autoload_complete` hook. Qualify an
identical-byte full-image/replay control, actual source-to-destination copying,
changed instruction fetch, reset and native mapping before use. Staging RAM
can be reused after copying, so never mask that source address unconditionally.
ARM7 comparison must also account for the transient staging copy, as described
below. Delivery controls alone do not qualify a changed-code replay.

Each patch may declare `data_guards: [{"addr": "0x...", "expect": "..."}]`
for literal pools or tables used by its proof. Each range must contain 1–4096
bytes within the selected main, overlay or autoload code/data body. Admission checks both original
bytes and the combined virtual image, so another selected patch cannot change
a protected invariant. This does not enforce invariants after loading; replay
write watches and entry-contract checks remain necessary where relevant.

`NDS_REPLAY_CODE_COMPARISON` optionally names a file of `hex_address
original_hex replacement_hex` rows. The oracle checks the exact code variant
each frame and writes a separate `code_normalized_state.csv`, restoring only
those declared instruction bytes in a local comparison copy. Raw hashes and
game memory are untouched. This does not grant permission to mask other RAM
differences or accept a non-bit-exact candidate.

For overlays, append `overlay decimal_id hex_base "original_body_path"` to
the row. Pin that private body's full SHA-256 to the admitted manifest in the
job. `replay_code_comparison.h` requires the entire loaded body to match its
original or combined replacement before normalizing any declared instruction
bytes. Absent, partially loaded, different or corrupted bodies remain raw and
increment `unmatched_overlay_regions`. Multiple patches in one body can share
a context; overlapping patch extents, conflicting identities and overlapping
different contexts are rejected. This is output comparison, not a live patch
loader. The checkpoint summarizer uses the same complete-body rule.

For pinned ARM7 autoload code, append `autoload mainram`, `autoload sharedwram`
or `autoload arm7wram` to a context row. These explicitly name complete physical
comparison views: canonical 4 MiB main RAM, 32 KiB shared WRAM at the final
`037f8000` alias, and 64 KiB private WRAM at `03800000`. Other aliases,
cross-bank spans, overlapping contexts and missing/wrong-sized buffers fail.
The row's full original/replacement context must match before any changed byte
is normalized. Partial, absent, corrupted or reused context remains raw and
increments `unmatched_autoload_regions`. No live emulated memory is written.

Use `summarize_guest_pair.arm7_comparison_contexts` to derive both the staging
and loaded contexts from the existing authenticated loader and exact ROM.
The runner must pin that specification, verify it against the manifest and
mapping, and compare the correct physical space at checkpoints. The frontend
adds normalized shared/private-WRAM hashes only when autoload rows are present;
legacy comparison columns remain unchanged otherwise. Raw hashes/dumps are
always retained. The shared Python checkpoint comparison follows the same
context and changed-byte rules; never apply the legacy main-RAM subtraction to
an ARM7 code address or mask staging after it is overwritten.

`NDS_REPLAY_CHECKPOINT_FRAMES=1441,2600` adds uniquely named full main-RAM,
ITCM, DTCM, ARM7/shared-WRAM dumps, current CPU registers/CPSR, TCM mappings
and both full-resolution screens. These are raw snapshots at video-frame
boundaries; a faster routine may be at a different instruction in that snapshot.
Do not silently mask live data or equate a video frame with a game-operation
boundary.

`NDS_REPLAY_BLOCK_TRACE` names a declarative file for one observed block. Its
first row is `cpu_decimal begin_pc_hex end_pc_hex`; subsequent rows are
`store_pc_hex address_register_decimal value_register_decimal`. At each site,
the observer requires the actual instruction to be an unconditional ARM
`STR value,[address]` with no offset or writeback. It hashes ordered 32-bit
address/value pairs, then records the count, end registers and CPSR for each
completed block in `block_trace.csv`. The summary reports restarted, unfinished
and unscoped observations. It observes existing instruction callbacks and never
writes game memory. This is not a general MMIO/memory tracer. Use profile start
zero for complete observation from boot; those instruction totals cannot be
compared directly with totals from a later profiling window.

Build with `--trace-spu-writes` and set `NDS_REPLAY_SPU_WRITES=1` to observe
audio-register writes. The builder instruments a private `SPU.cpp` copy at the
three write handlers and the mix callback. `spu_writes.csv` records ordered
width/address/value payloads, raw ARM7 timestamps and mix-call ordinals. It
does not change emulated time or registers. The trace includes initialization
writes before frame zero; frame zero alone is not a timestamp. This observes
control writes, not sample-buffer contents or channel output. An unpatched
control must reproduce the original audio, screens, RAM and saves before the
new trace is used to explain a candidate.

`compare_event_traces.py CONTROL_CSV CANDIDATE_CSV --payload COLUMN ...
--timing COLUMN ... --output REPORT` compares events in ordinal order while
reporting timing differences separately. It rejects malformed/discontinuous
traces, counts unmatched tails, and never aligns away a changed event. Matching
event payloads do not approve output differences or establish native timing.

`--trace-spu-samples` includes the write observer and adds sample observation
to the same private source copy. Enable both `NDS_REPLAY_SPU_WRITES=1` and
`NDS_REPLAY_SPU_SAMPLES=1`. Every channel start is recorded in `spu_starts.csv`;
each start increments that channel's generation. The observer copies FIFO
words after the existing memory read and decoded samples after the existing
decoder step. It never issues another emulated read or changes the audio path.

Binary format version 1 uses four little-endian unsigned 32-bit words per
record (16 bytes). Per-channel files contain:

| File | Word 0 | Word 1 | Word 2 | Word 3 |
|---|---|---|---|---|
| `spu_fifo_N.bin` | start generation | mix index | source address | fetched word |
| `spu_samples_N.bin` | start generation | mix index | signed sample position bits | format in bits 16–31, signed-16 decoded sample bits in 0–15 |
| `spu_output_N.bin` | start generation | mix index | signed channel output bits before panning | pan |
| `spu_mixed.bin` | video frame | mix index | signed-16 left bits | signed-16 right bits |

Source fetches and decoded steps cover the full replay. Set
`NDS_REPLAY_SPU_OUTPUT_FRAMES=100:200,300:400` for bounded per-channel and mixed
output capture; intervals are disjoint and end-exclusive. Without intervals,
those output files are empty. Mixed output is observed after final clamping and
bit-depth handling, before the existing resampler. Summary CSVs give record
counts and capture intervals. All data remains private.

`compare_spu_samples.py CONTROL_DIRECTORY CANDIDATE_DIRECTORY --output REPORT`
compares source/decoded events by channel, start generation and ordinal. It
reports differing lengths and unmatched tails explicitly, including when a
note stops or the replay ends. Channel/mixed output is compared at identical
mix indices in the recorded windows; it does not estimate or remove lag.
Matching source addresses alone are insufficient: actual fetched words and
decoded values must be checked too. Revalidate the complete unpatched outputs
whenever instrumentation changes.

`explain_spu_output.py CONTROL_DIRECTORY CANDIDATE_DIRECTORY --output REPORT`
checks captured channel output against the observed last decoded sample and
recorded volume/shift/pan/enable writes, using the existing SPU arithmetic.
It supports interpolation disabled only. Writes observed after mix callback
`k` affect later callbacks; they must not be applied retroactively to `k`.
The tool processes one channel pair at a time to bound working memory for
full-replay captures. It reports unexplained records and separates selected
sample values from control-state differences. A selected-sample difference
can come from changed source data as well as phase; consult the FIFO/decoder
comparison before claiming a timing-only cause. It does not synthesize a
replacement soundtrack, remove lag or establish audibility/native equivalence.

`build_replay_oracle.py --trace-ram-bus` adds observations after the six
ARM9/ARM7 main-RAM bus stores in a private `NDS.cpp` copy. Exact source-site
guards reject changed or duplicate sites. Set `NDS_REPLAY_RAM_BUS` to a file
of hexadecimal `first end_exclusive` physical main-RAM ranges. The frontend
rejects empty, overlapping, reversed, out-of-range or malformed ranges before
boot. Builds without this observer reject the request rather than silently
recording nothing. This supports normal NDS with JIT disabled, not DSi or
arbitrary host/state-loader writes.

`--trace-itcm-writes` additionally instruments the four ARM9 interpreter ITCM
store paths in a private `CP15.cpp` copy and implies `--trace-ram-bus`.
`instrument_itcm_trace.py` guards the source sites and canonicalizes physical
32 KiB aliases to `01ff8000..01ffffff`. Watch ranges must remain wholly within
main RAM or this ITCM space; a build without the ITCM observer rejects ITCM
watches. The trace excludes reset-time host memset, debug/state loading, JIT
and DSi host writes. A zero-filled region is not an unused-memory proof:
record the whole replay, distinguish boot initialization from later writes,
and qualify observer outputs against the unchanged reference first.

With the existing SPU sample observer enabled, `ram_bus.csv` interleaves stores,
actual sound FIFO reads and sound-control writes. It retains event order,
both raw CPU timestamps, canonical addresses, values, widths, CPU context and
executing-DMA masks. CPU registers alongside a sound read are context, not
the source of that read. `last_profile_pc` is available only after instruction
profiling starts; it is not a DMA writer PC. DMA source/destination/count
fields identify one executing channel only when the mask has a single bit.
No extra emulated memory reads are used to create this trace.

`audit_ram_bus.py TRACE --output REPORT` reconstructs observed little-endian
byte stores and checks each sound fetch against its preceding writes. Unknown
bytes and inconsistent reads stay explicit; an empty trace cannot pass.
This establishes consistency of captured events, not unrestricted write-watch
coverage or permission to accept a changed soundtrack.

`NDS_REPLAY_MEMORY_WATCH=SPEC` extends the same instruction observer with
bounded snapshots of registers or host-backed DS memory. Each row is:

```text
CPU PC_HEX arm|thumb OPCODE_HEX ADDRESS_REG SIGNED_OFFSET BYTE_COUNT GUARD_REG GUARD_VALUE_HEX [main|dtcm|regs]
```

All fields except those marked hex are decimal. Rows for the same CPU/PC
form one event with ordered spans; at most 16 sites and 64 spans are allowed.
Each memory span is 1–4096 bytes, with a register-relative offset within ±65536.
The exact opcode, CPU mode and register guard must match. Address registers
and guards may name R0–R15. R15 is the callback's pipeline PC; a PC-relative
code snapshot must account for that pipeline offset and guard the expected PC.
The default `main` space rejects noncanonical aliases, MMIO, ARM9 ITCM/DTCM
overlap, overflow and non-4-MiB RAM mapping. Explicit `dtcm` spans require
ARM9, a currently mapped 16-KiB DTCM range and the correct local backing;
they reject ITCM overlap, unmapped bytes and ARM7 aliases. No fallback from
one space to the other is permitted. Explicit `regs` rows require all three
address/offset/length fields to be zero. They retain CPU, opcode, mode and
register guards, emit all registers/CPSR, and neither inspect an address nor
require RAM backing. Their CSV memory fields are `0,0,,regs`; an empty memory
span without this explicit space still fails. This supports ARM7 register
censuses without pretending its WRAM stack is main RAM. It copies backing bytes directly, with no emulated memory reads or
guest writes. Legacy `watches.csv` is unchanged. Capture is at instruction
entry, before its condition is evaluated; use an appropriate unconditional
site or account for this in the fixture. Profiling must cover every required
entry/exit. Every declared site must be hit, or the run fails.
Optional `NDS_REPLAY_MEMORY_WATCH_FRAMES=FIRST:LAST` limits snapshots to a
half-open frame window within the profiled replay. The golden comparison
still covers the entire replay. `memory_watch_window.csv` records actual
bounds; do not label a bounded capture as full-route recurrence.

`memory_watch.csv` retains complete bytes, address spaces, addresses, registers and mode;
`memory_watch_summary.csv` records site counts. A new observer build must pass
an unpatched golden replay before its snapshots support an optimization claim.
`test_replay_memory_watch.cpp` exercises mapping, guard and output integrity.

`analyze_memory_recurrence.py TRACE FIXTURE --status STATUS --output REPORT`
requires a passed unpatched replay and its retained trace digest. The fixture
declares entry/exit sites, register deltas, output pointers, input/output spans,
key registers and selected frames. It can include returned registers and
verify saved entry registers in captured stack bytes. Multiple conditional
ARM return sites are supported with explicit CPSR condition evaluation;
an unexecuted conditional POP does not finish an invocation. A fixture's
`capture_frames` selects a bounded-window report. It rejects incomplete, nested or mismatched
invocations. A complete call may cross an emulator frame boundary; saved
register and stack guards still apply. Calls cut by the capture boundaries
are rejected rather than silently discarded. Keys contain actual bytes, sizes and declared register values;
source-pointer equality alone is insufficient. Reports include exact recurrence,
output conflicts, reuse distances and hypothetical LRU hit counts. Constant
tables and other dependencies still need independent proof. Payload storage
omits metadata and alignment; hit counts omit lookup, copy, invalidation and
timing costs. This diagnostic does not allocate guest scratch or implement a cache.
For a register-only fixture, use empty input/output span lists, explicit key/
output registers and `source_span: null`. Source-content/address counts are then
zero, not a fabricated empty-memory source. This numerical recurrence does not
prove all CPU side effects, safe cache storage or lookup-table invariance.

`audit_transfer_calls.py TRACE FIXTURE --output REPORT` streams the same
guarded memory-watch output to census leaf transfer arguments. It binds the
trace to a fixture and a passing six-file golden comparison, verifies CPU,
mode, opcode, pipeline PC, ordered entry/return pairing, declared preserved
registers, source/counter effects, final flags and unchanged stack bytes.
One stack span per event is supported. Calls crossing frames are paired and
reported; incomplete boundary calls fail. The fixture declares code sites,
address regions and either indexed halfword-copy or fixed-destination word-
stream ABI effects; it contains all game addresses.

For callers with different stack mappings, a fixture may instead set
`snapshot_kind: "code"`. Each function supplies a `code_context` with a main-RAM
`address` and exact original `expect` bytes covering both entry and return.
One code span at each site must match that complete context, including the
declared opcodes. The same register/counter/flag and pairing checks apply.
This verifies loaded code identity rather than stack contents; reports state
that stack bytes were not observed. It does not authorize memory-effect or
payload-equivalence claims. The default stack mode remains unchanged.

This census admits only observed nonnegative lengths at most 1 MiB, divisible
by the declared 2/4-byte unit. It is not general synthetic equivalence or a
data-payload recurrence audit. Zero-length calls have no access region, even
when their destination argument names MMIO. Source advancement does not imply
destination advancement. Seven tests cover pairing across frames and reject
mode/opcode changes, changed preserved registers/stack, reused golden evidence,
event/window errors and incomplete calls. Neither a passing census nor
estimated removed instruction entries establishes native speed or safety.

`check_halfword_copy_patch.py MANIFEST --patch ID --output REPORT` compares
synthetic machine states and ordered data accesses using Unicorn. The generic
`check_guest_block_patch.py MANIFEST FIXTURE --output REPORT` reuses that
runner for a bounded ARM or Thumb block and declarative register/data cases.
The mode must agree with CPSR.T and entry alignment. `instruction_limit`
defaults to 20,000 and is bounded at one million. By default all ordered data
accesses must match. An optional `elidable_read_ranges` list admits only removal
of reads within the primary modeled ordinary-memory page. Required reads and
all writes must retain address, size, value and order; registers, flags and
all mapped memory still match exactly. This models no asynchronous writer:
capacity stability, IRQ/DMA interactions and the actual address-space mapping
need separate runtime evidence. Mapped MMIO pages model ordinary memory only,
not hardware side effects, and cannot be declared as elidable ranges.

For a separately established synchronous ordinary-memory contract, a fixture
may instead declare `ordinary_memory_effect_ranges`. These must fit existing
modeled DS RAM pages; MMIO, unmapped, overlapping and crossing-page ranges are
rejected. Access order may differ only inside these ranges, while every final
mapped byte, register and CPSR must still match. Outside accesses retain their
exact order, size and value. `code_literal_read_ranges` additionally permits
changed read counts/order for literals whose bytes are identical in both code
versions; any write to those literals fails. These policies cannot be combined
with `elidable_read_ranges`. This is an explicit stronger assumption about
concurrent observers, not a relaxed full-replay RAM or audio gate.

Each case may seed existing `extra_pages` using `extra_memory_overrides` rows
with hexadecimal `address` and `hex` bytes. Empty, unmapped and crossing-page
overrides fail. Omitting `stop` runs to the case's original LR return target,
retaining ARM/Thumb interworking checks. Runtime cache-key coherence, IRQ/DMA
readers, stack ownership and native timing still require independent evidence.

`summarize_guest_pair.py CONTROL CANDIDATE INPUT --output REPORT` reuses the
guarded replay status and manifest to report screen, audio, RAM and instruction
differences. Only the declared instruction extent is normalized. For a new
overlay patch on top of retained patches, both records explicitly pin the same
`base_patch_ids` and manifest. Their admission selections must be the baseline
IDs and those IDs plus the candidate respectively. The overlay comparison
context additionally pins `original_path`, `original_sha256` and the retained
IDs for that overlay. `overlay_comparison_body` reconstructs the baseline from
the original full overlay and exact, disjoint retained replacements, then
checks the complete context file. Only the candidate bytes are normalized;
retained patches and unknown runtime mutations remain visible. No context can
substitute for loader admission or source-image/lifecycle qualification.

If the patch
declares data guards, the corresponding RAM-bus traces remain required for
table/literal write analysis. With no data guards, that section is empty;
an unrelated table observer is not required. The report never accepts a patch
or treats instruction reduction as native speed.

`boolean_cache_lookup_armv5.S` is a synthetic ARMv5 complete-key boolean-cache
component for cost screening. It has fixed test addresses, 512 direct-mapped
32-byte slots, two eight-byte input spans and a validity word. It returns
0/1 on hit, -1 on miss and -2 on unsupported alignment. It is not a loader,
native hook or allocated game scratch. Assemble its text without relocations
before passing the raw bytes to `check_boolean_cache_lookup.py CODE --output
REPORT`, which reuses the existing Unicorn runner. The contract deliberately
does not promise full volatile-register/flag equivalence or miss insertion.

`estimate_boolean_cache_trace.py TRACE FIXTURE --status STATUS --synthetic
REPORT --code CODE --output RESULT` verifies an exact unpatched replay and
the component's pinned checks, then simulates its real hash and collisions.
The fixture supplies original entry counts per return site and explicit
prologue/tail credits. Results include an optimistic integrated entry count
and a perfect-aligned-hit bound. Free restoration/insertion/invalidation are
identified as omitted costs, not working implementation. No native cycles,
storage availability, interrupt behavior or accepted patch follows from this.

`scan_guest_patterns.py ROM --output REPORT` detects branch-heavy copy,
redundant shifts, nibble arithmetic, dispatch, mask walks and zero multiplies
in ARM main/autoload sections. `--include-thumb` adds narrow header-read and
exact empty-tail compaction detectors. Repeat `--arm9-overlay ID` to scan
specific stored/compressed overlays through the existing `read_overlay` path;
output pins each original stored and decoded body plus ID/file mapping.
Optional `--arm9-profile` and `--arm7-profile` CSVs add sample counts. Flat PC
samples cannot distinguish overlays sharing an address, so overlay attribution
explicitly requires executed-content evidence. Matches never establish SDK
identity, writer/IRQ safety, a safe replacement or native gain.

`package_private_beta.py` builds a separate launcher/support-folder package from
a pinned base archive, a tested renderer and a declarative packaging definition.
It includes corresponding source and compiler profiles, checks package hashes
and excludes top-level ROM/save/settings files. Native scene qualification and
a clean archive-install smoke test are still required; packaging alone does
not establish performance or correctness.


## Configured native captures

`native_session.py CONFIG launch|stop LABEL`, `native_rig.py ACTION LABEL`, and
`native_capture.py CONFIG SEQUENCE LABEL` promote the existing private rig into
configuration-driven tools. `native_rig.py` reads `NDS_RIG_CONFIG`; the wrapper
and recorder set it explicitly. Game identities, original/disposable paths,
patch IDs, expected staged cartridge bytes and input sequences live in the
private configuration. The existing supervisor, loader, bounded-input library
and OBS connector remain in use; these scripts add no HPS service or RTL.

The configuration pins the runtime kit, helper libraries, seed and protected
files, supplies the SSH argv and evidence/state paths, and declares the allowed
individual guest selections. Launch requires MENU, no existing host/helper,
the admitted seed and ROM identity. Every live action checks the owned lease,
PID epochs, exact executables, sole save descriptor and selection environment.
Staged-byte checks prove loader delivery, not direct ARM RAM/cache visibility.
When virtual delivery changes the header, pin `source_cartridge_identity`
separately from `loaded_cartridge_identity`; omission keeps the legacy shared
identity check. `staged_cartridge_bytes` may explicitly extend the old128 MiB
inspection bound up to the supported252 MiB contiguous cartridge window.
Every inspected byte must remain within that pinned extent; this does not
authorize an arbitrary physical-memory read or a larger banking layout.
Keep the owned disposable save out of the protected *other files* collection.
Preserve full hashes at experiment entry and final audit; inode-only changes
must be hash-verified before using their receipts to refresh a future config.

A capture sequence contains named `input` or `measure` sections and bounded
`[seconds, [Linux key codes]]` steps. Each step is at most 30 seconds; the total
section is at most 60 seconds. A measurement ends with `[0.1, []]` outside its
window. Endpoint screen-publication/source-frame counters and process CPU ticks
are distinct from unique visual frames, game-clock cadence and gameplay speed.
Check screenshots and actual input outcomes before naming a workload. Legacy
benchmark boundaries require explicit scene admission.

The recorder owns only recordings it starts, retains OBS drop counters and
checks the same session before and after. Inspect audio tracks: some OBS
profiles put silence on the default track. `make_review_mp4.py SOURCE OUTPUT
--copy-audio-track N` copies the selected zero-based audio track and video
packets unchanged, verifying both packet digests. It does not normalize volume,
resample audio or change playback speed. The existing default mode still makes
an AAC convenience copy of a lossless reference-replay MOV.

## Existing geometry-trace observation

`NDS_REPLAY_GEOMETRY_FRAMES=FIRST:LAST` attaches a filtered observer to the
existing `NDS4MiSTer_2DTrace` sink for that end-exclusive replay-frame window.
It must lie within the profiled window. The normal renderer, FPGA and HPS
services are unchanged. First qualify the observer with an unchanged replay,
including every retained golden file, before interpreting its census.

`geometry.csv` contains normalized geometry command parameter packets, frame
records and register writes. Decimal columns are ordinal, frame indices,
timestamp and PC-valid flag; payload/context words are hexadecimal. Payload
`a,b,c` means command/parameter/zero for `command`, vertices/polygons/flush
attributes for `frame`, and address/value/width for `register`. Raw ARM9 PC,
CPSR, LR, R0–R3, last sampled instruction and an active-DMA mask are context,
not a reconstructed call stack. DMA commands must not be attributed to the
interrupted CPU instruction. `geometry_window.csv` records bounds and totals.

The sink consumes fragmented existing trace records; it does not assume every
callback starts at a packet boundary. Invalid/truncated geometry records,
empty observations and failed output writes fail the job. The capture retains
full normalized parameter order. It does not read extra guest memory or change
emulated timestamps. Native timing and complete rendering dependencies are
outside this observer's scope.

`summarize_geometry_trace.py TRACE --window WINDOW --qualification RECEIPT
--output REPORT` requires a `passed_full_unchanged_replay` receipt with SHA-256
pins for both capture files. It verifies ordinals/window/timestamps, separates
CPU/DMA contexts, counts parameter packets, and hashes complete intervals
between observed swap commands. It excludes partial leading/trailing intervals.
Repeated assignment values and identical command streams are only leads:
textures, palettes, external state, pipeline side effects and timing must also
be proven. The report never authorizes skipping a draw or a geometry query.


### Staged source-buffer census

`audit_staged_buffers.py TRACE FIXTURE --neutrality RECEIPT --output REPORT`
reuses `analyze_memory_recurrence.read_events` to join declared phases by
instance and frame. The fixture supplies guarded PC/mode/opcode/code snapshots,
header/payload spans, expected instances, and explicitly addressed strided
fields. It reports per-field recurrence and changes between phases, retaining
raw header distributions. Incomplete or reordered groups, altered code,
unknown instances and out-of-bounds fields fail closed.

The neutrality receipt must identify the trace SHA-256 and exact agreement of
all declared raw baseline files from the same virtual image. This supports a
retained-patch baseline without treating known differences against the original
game as observer effects. This is a source-buffer census, not destination
readback, cache invalidation, writer/reader lifetime or patch acceptance.

### Read-only model shape inspection

`inspect_model_shapes.py INPUT --input-sha256 SHA --offset OFFSET --output JSON`
reads a raw NNS model inside a pinned memory/resource snapshot. It validates
section, dictionary and display-list bounds, decodes packed commands and reports
per-shape signed FX12 vertex bounds and primitive counts. `--include-vertices`
retains the decoded coordinates. Unknown opcodes/truncation fail; inherited
coordinates, local matrix changes or vertices outside primitives suppress the
complete-bounds result. Command arities are tested against the existing core.

`model_visibility_math.py` supplies bounded offline matrix calculations for an
authenticated caller. It requires self-contained projection/position loads,
rejects unsupported stack operations/overflow and reports conservative XY-plane
leads with a rounding margin. It does not simulate the renderer, interpret model
SBC/node animation or prove material, camera, resource lifetime or removability.
Game fixtures must authenticate those dependencies before proposing any patch.

## Regional direct-flow correspondence

`audit_regional_direct_flow.py PLAN.json RECEIPT.json` compares paired ARM/Thumb
entries in authenticated captured ARM9 images. The plan supplies the capture path,
reference game code/revision, and candidate code/revision/entry pairs; game
addresses and identities do not live in the tool. It requires Capstone and ndspy,
as used by the existing private analysis environment.

The capture uses one JSON object per line with game code, revision and an ARM9
object containing base address, SHA-256 and base64 bytes. Each candidate supplies
`roots` with `reference`, `candidate` (hex addresses) and `mode` (`arm` or `thumb`).
An optional `instruction_limit` bounds the traversal. The receipt retains every
reached instruction, direct edge, literal, unresolved transfer and conflicting
mapping. BSS-relative correspondence is a location check, not a runtime-state
proof. No patch is generated or enabled. Run the focused synthetic checks with
`python3 -m unittest test_regional_direct_flow` from this directory.

## Retained replay timing diagnostics

`diagnose_replay_timing.py PLAN.json SPEC.json` reads existing replay outputs
without running the game or modifying captures. The plan supplies `directory`
and `prefix`; the tool reads `PREFIX_DELIVERY_V1` and `PREFIX_CANDIDATE_V1`
using the existing `frames.csv`, `audio.s16le` and `thumbs.rgb` formats.

The specification supplies `windows` (exclusive end), `frame_radii`,
`audio_radius_samples`, `audio_window_samples`, `audio_starts`,
`thumbnail_frames` and a fresh `output_suffix`. NumPy and Pillow are required.
Outputs report nearby screen-pair matches, unmatched frames, bounded audio
offsets and residuals, plus labeled thumbnails. Audio offset estimation uses
one channel; residual measurements cover both. The tool does not enable a patch
or declare visual, audio or gameplay equivalence. Preserve the raw comparison
and review unexplained differences under the explicitly chosen test budget.

### Compressed ARM9 ITCM boot payloads

Explicit `recompress-arm9-autoload-v1` delivery in `guest_byte_patch.py` reuses
`MainCodeFile` and `VirtualRom`. It admits pinned ITCM autoload sections only,
with code-settings offset, full stored/decoded identities, expected instruction
bytes, mode/alignment and data guards. Unchanged recompression must reproduce
the original stored image exactly. A selected patch must retain the original
compressed extent and every decoded byte outside its declared replacement;
header, copy table, other sections and cartridge layout stay unchanged.
Normal boot performs the copy into ITCM, with no live instruction-cache write,
new allocation in guest memory, hardware hook or HPS runtime service. Each
selection falls back atomically on mismatch. This mode is not release-enabled
by discovery. Recompression cost and native cold/reset behavior still require
per-game qualification. `test_arm9_autoload_patch.py` covers synthetic byte
preservation, identical controls, admission failures, overlap and size changes.

### Deterministic private cold-boot storage

The reference core leaves some initial hardware data registers indeterminate.
A virtual cartridge can reuse memory filled with ROM padding, producing a
repeatable but different control run. Mario Kart exposed this first in saved
DIV/SQRT thread context; initializing those registers alone still left a later
entropy difference. The oracle now zeroes its NDS object storage before normal
construction and pins math data registers after reset. This is an explicit
software fixture, not a claim about all hardware power-on values or a change
to the released core. Requalify unchanged controls after changing fixtures.
Mario Kart's 3,300-frame direct and identical virtual controls now match the
previous direct golden in frames, state, audio, save and both PC profiles.
