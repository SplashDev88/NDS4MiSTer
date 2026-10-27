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
The latter supports only same-size uncompressed ARM9 main-code patches and
rejects overlays, autoloads, scratch and HLE requests.

The native host supports explicit private experiments through its existing
disposable loader. Set `NDS_GUEST_PATCH_MANIFEST` to the manifest path,
`NDS_GUEST_PATCH_SHA256` to its exact SHA-256 and `NDS_GUEST_PATCH_IDS` to a
comma-separated list. Clear all three for the ordinary control. This explicitly
selects diagnostic candidates even if `enabled` is false; it changes no release
defaults. A partial selection, wrong pin, unknown ID or failed identity/byte
guard logs a skip and streams the original image atomically. No disk cache or
movie preparation is composed with this selection. The loader exits before
gameplay; there is no per-call HPS service or additional guest round trip.

The normal host download holds reset through stream completion, uploads the
staged cartridge and retains the original path/save identity. Initial code
loads therefore see the replacement bytes; this is not a hot patch into a
running instruction cache. Native reset, ROM-switch and gameplay lifecycle
checks still qualify each candidate. `verify_guest_native_stream.py` compares
the actual worker's complete output to previously pinned virtual-image hashes
without creating a ROM file. This is a load-path check, not a native speed test.

Each patch may declare `data_guards: [{"addr": "0x...", "expect": "..."}]`
for literal pools or tables used by its proof. Each range must contain 1–4096
bytes within initially loaded main code/data. Admission checks both original
bytes and the combined virtual image, so another selected patch cannot change
a protected invariant. This does not enforce invariants after loading; replay
write watches and entry-contract checks remain necessary where relevant.

`NDS_REPLAY_CODE_COMPARISON` optionally names a file of `hex_address
original_hex replacement_hex` rows. The oracle checks the exact code variant
each frame and writes a separate `code_normalized_state.csv`, restoring only
those declared instruction bytes in a local comparison copy. Raw hashes and
game memory are untouched. This does not grant permission to mask other RAM
differences or accept a non-bit-exact candidate.

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
bounded snapshots of host-backed DS memory. Each row is:

```text
CPU PC_HEX arm|thumb OPCODE_HEX ADDRESS_REG SIGNED_OFFSET BYTE_COUNT GUARD_REG GUARD_VALUE_HEX [main|dtcm]
```

All fields except those marked hex are decimal. Rows for the same CPU/PC
form one event with ordered spans; at most 16 sites and 64 spans are allowed.
Each span is 1–4096 bytes, with a register-relative offset within ±4096.
The exact opcode, CPU mode and register guard must match. Address registers
are R0–R14; a guard may also name R15 to check the callback's pipeline PC.
The default `main` space rejects noncanonical aliases, MMIO, ARM9 ITCM/DTCM
overlap, overflow and non-4-MiB RAM mapping. Explicit `dtcm` spans require
ARM9, a currently mapped 16-KiB DTCM range and the correct local backing;
they reject ITCM overlap, unmapped bytes and ARM7 aliases. No fallback from
one space to the other is permitted. It copies backing bytes directly, with no emulated memory reads or
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

`check_halfword_copy_patch.py MANIFEST --patch ID --output REPORT` compares
synthetic machine states and ordered data accesses using Unicorn. The generic
`check_guest_block_patch.py MANIFEST FIXTURE --output REPORT` reuses that
runner for a bounded ARM block and declarative register/data cases. Mapped
MMIO pages model ordinary memory only, not hardware side effects.

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
redundant bitfield shifts and scaled nibble-step arithmetic in ARM main/autoload
sections; optional `--arm9-profile` and
`--arm7-profile` CSVs add execution sample counts. It does not scan Thumb or
overlays and cannot establish SDK identity, timing safety or native gain.

`package_private_beta.py` builds a separate launcher/support-folder package from
a pinned base archive, a tested renderer and a declarative packaging definition.
It includes corresponding source and compiler profiles, checks package hashes
and excludes top-level ROM/save/settings files. Native scene qualification and
a clean archive-install smoke test are still required; packaging alone does
not establish performance or correctness.
