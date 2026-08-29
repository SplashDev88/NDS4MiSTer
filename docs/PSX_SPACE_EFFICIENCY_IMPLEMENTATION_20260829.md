# PSX-derived space-efficiency implementation

Date: 2026-08-29

Branch: `experiment/psx-space-efficiency-20260829`

This is an isolated first-pass experiment based on the exact cumulative-release
source snapshot `f159a0de10e9bbbc99cf250db1b30f7f9d30922e`. It does not change the
134.055928 MHz clock family, LG-safe HDMI path, ARM-assisted 3D path, FPGA sound,
touch, saves, video layouts, default 8-pixel gap, or direct-load lifecycle.

## Isolation and safety

The cumulative worktree had tracked changes and intended untracked source while
its Quartus fit was active. A temporary Git index was used to stage an exact
snapshot without changing that worktree. `git diff --cached --check` and
`python3 tools/audit_public_repo.py --self-test --staged` passed before the tree
was committed with `git commit-tree`. The experimental branch and worktree were
then created from that synthetic commit. Nothing was pushed.

The active cumulative Quartus process was not interrupted, and no second
Quartus job was launched. Its Analysis & Synthesis report is the current A-side
reference: 40,368 estimated ALMs, 43,702 registers, 3,460,096 block-memory bits,
3,968 MLAB bits, 69 DSPs, and 6 synthesis-visible PLLs. A mapper-only B-side run
remains pending until that full fit exits.

## Implemented commits

### `7917112` — ARM7 shared barrel shifter

`third_party/Nitro_DarkSide/d2dabe/rtl/gba_cpu.vhd` now uses the same one-rotator,
mask, fill, and carry-selection architecture already proven in ARM9. It removes
the parallel LSL, LSR, ASR, ROR, and RRX datapaths without adding an execution
cycle.

`tools/test_arm7_shared_shifter.py` compares the retired and shared datapaths
for all shift modes, immediate amounts 0..31, register amounts 0..255, carry
inputs, zero/all-one/one-hot/inverted/alternating operands, and RRX: 158,976
exhaustive basis cases pass.

Expected result: approximately 200–350 fewer ALMs. This remains an estimate
until the B-side map.

### `d59c72c` — exact compressed save-profile ROM

The former 4096x36 direct-mapped ROM was replaced with two exact tables:

- 512x36 prefix storage rows: a zero pad plus the exact 35-bit game-code
  prefix, entry start, and entry count payload
- 4096x20 sorted entries: low game-code half and exact save type

There are 368 occupied prefixes, 4,057 oracle entries, and a largest bucket of
72 entries. Explicit no-save and EEPROM/FRAM/Flash selections remain distinct;
the default remains type 1. The lookup runs only when a ROM identity is selected,
not in the emulation hot path.

`tools/test_save_profile_compression.py` reconstructs the full oracle dictionary
and proves no missing, extra, or changed entry. The SystemVerilog lookup test and
all EEPROM/FRAM/Flash AUXSPI and host persistence tests pass.

Expected physical result: approximately 18 to 12 M10Ks, a saving of 6. This is
derived from Cyclone V width/depth granularity, not yet a measured mapper delta.

### `88435fb` — packed sound fetch state

`third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd` combines the per-channel
25-bit fetch pointer and 24-bit remaining count into one 52-bit true-dual-port
RAM. CPU start writes and fetch-side updates remain atomic; the one-shot clear
retains the pointer explicitly. Assertions require pointer/count addresses and
write-enables to remain paired.

`tools/test_sound_fetch_state_packing.py` proves 100,049 boundary and deterministic
state transitions equivalent to the retired two-RAM implementation. The actual
production VHDL also passes nvc analysis against the portable MEM boundary.

Expected physical result: four to three true-dual-port M10Ks, a saving of 1.

### `51e5c98` — packed ARM9 cache tag depth

Each ARM9 cache way formerly used one shallow I-tag RAM and one shallow D-tag
RAM. `third_party/Nitro_DarkSide/d2dabe/rtl/nds_cache9.vhd` now packs both address
spaces into one 128-row RAM per way: I sets use rows 0..63 and D sets use rows
64..95.

Both ports remain active: port A reads I tags and port B reads D tags every
cycle. This preserves simultaneous speculative lookups, the existing one-cycle
synchronous RAM behavior, associativity, hit latency, and maintenance timing.
Each cache borrows its own port only on the completed-fill tag-write edge, when
no tag result is consumed.

`tools/test_cache_tag_packing.py` checks 1,600,384 lane reads, every legal row and
way, rapid I/D transitions, and 3,517 same-row read/write cycles against the
retired banks. Production VHDL passes nvc analysis.

Expected physical result: sixteen to eight true-dual-port tag M10Ks, a saving
of 8. Valid, dirty, and replacement metadata deliberately remain flops. Folding
them would either make invalidate-all non-atomic, add sweep cycles, or require
generation-wrap machinery, so it did not meet the exact-semantics rule.

### `feb7ff7` — explicit IPC MLAB mapping

The two architectural 16x32 IPC payload FIFOs now carry explicit `MLAB`
attributes. Their asynchronous head-read and synchronous write behavior is a
native small-memory shape. `no_rw_check` is deliberately absent so Quartus must
preserve simultaneous pop/push collision behavior.

The A-side mapper inferred three replicated 16x32 simple-dual-port block RAMs
(one FIFO needs a second read copy). Expected physical result: three fewer M10Ks
and 1,536 additional MLAB memory bits. Production VHDL analysis passes. Exact
mapping and any bypass-logic delta require the B-side mapper.

## Verification completed

- Full `tools/test_nitro_console_island_host.sh`: PASS after all first-pass changes.
- ARM7 shifter exhaustive comparison: PASS, 158,976 cases.
- Save-profile exact reconstruction: PASS, all 4,057 oracle entries.
- Save lookup, EEPROM, FRAM, Flash, loader, and persistence simulations: PASS.
- Sound packed-state comparison: PASS, 100,049 cases.
- Cache tag comparison: PASS, 1,600,384 lane reads.
- Production sound/cache/IPC VHDL nvc analysis: PASS.
- Public repository safety audit on every staged commit: PASS.
- Worktree is isolated from the active cumulative fit and nothing was pushed.

Compiler warnings emitted by the broad host suite are pre-existing iverilog
limitations and testbench synthesis warnings; all test gates finished PASS.

## Resource expectation before mapper confirmation

| Change | Expected ALM delta | Expected M10K delta | Confidence |
| --- | ---: | ---: | --- |
| ARM7 shared shifter | -200 to -350 | 0 | Medium; based on analogous architecture |
| Save-profile compression | small lookup overhead | -6 | High from exact RAM geometry |
| Sound fetch packing | near neutral | -1 | High from true-dual-port width geometry |
| ARM9 cache tag packing | small mux overhead | -8 | High from true-dual-port depth/width geometry |
| IPC FIFO MLAB mapping | near neutral; possible bypass logic | -3, +1,536 MLAB bits | Medium until mapper |
| **Total** | **approximately -200 to -350 plus small overheads** | **approximately -18** | **Mapper pending** |

These are predictions, not reported as measured deltas. The B-side mapper must
confirm RAM block selection and hierarchy before any release decision.

## Validation still required

1. Wait for the cumulative full fit to exit, then run only an experimental map.
2. Compare total and per-entity ALMs, registers, M10Ks/MLABs, DSPs, PLLs, inferred
   RAM modes, replication, and warnings against the exact A-side snapshot.
3. If the map is favorable, run a full isolated fit only when no other Quartus
   process is active. Treat timing as diagnostic rather than a deployment gate.
4. Direct-load TV testing: LG C3/C4 and TCL; all layouts/order/gap/FPS settings;
   default 8-pixel gap; touch; sound; all save types; reset/reload.
5. Game testing: NSMB intro, map, big castle and long play; verify no 3D speed,
   sound-sync, save, HDMA/BG2, or stability regression.

## Deferred stages

The first pass intentionally did not attempt sound migration to ARM, FPGA sound
serialization, Engine A arithmetic sharing, HPS timestamp/record narrowing,
CPU register-file conversion, or LG-safe video/scaler changes. These have larger
potential savings but materially higher timing, ordering, or compatibility risk.

The next architectural candidates, after measured headroom is known, are:

1. ARM7-only replicated MLAB register-file prototype with complete bank/exception
   and forwarding tests.
2. Exact HPS record-width audit using measured queue occupancy and wrap-safe time
   reconstruction.
3. Event/deadline-based FPGA sound serialization A/B against the current sound,
   keeping the working FPGA implementation as the release default.

Do not copy PSX's global aggressive-performance settings, blanket don't-care
power-up state, or video/scaler choices into this near-full design without
isolated A/B maps and hardware tests.
