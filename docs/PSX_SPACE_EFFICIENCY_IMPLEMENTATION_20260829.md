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

The cumulative A-side Analysis & Synthesis report contains 40,368 estimated
ALMs, 43,702 registers, and 3,460,096 block-memory bits. The first experimental
map contained 40,707 estimated ALMs, 45,134 registers, and 3,414,016 block-
memory bits. Its fit required 4,210 LABs on a 4,191-LAB device. The hierarchy
comparison identified one failed mapping experiment, documented below. After
removing it, the corrected map completed with 40,227 estimated ALMs, 43,725
total registers, and 3,415,552 block-memory bits.

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

Measured result: 90 fewer combinational ALUTs in `gba_cpu:icpu7`, with no
register or block-memory change.

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

Measured result: 47 more ALUTs and 20 more registers, while the ROM shrank from
147,456 to 99,840 logical block-memory bits. Quartus implements the two compact
tables in 12 M10Ks versus 18 for the original table, saving 6 M10Ks.

### `88435fb` — packed sound fetch state

`third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd` combines the per-channel
25-bit fetch pointer and 24-bit remaining count into one exact 49-bit
true-dual-port RAM. A dedicated full-word interface with disconnected byte
enables replaces the rejected four-by-13-bit prototype; this is the legal
`WIDTH_BYTEENA=1` form because every functional update already writes both
fields atomically. The one-shot clear retains the pointer explicitly.
Assertions require pointer/count addresses and write-enables to remain paired.

`tools/test_sound_fetch_state_packing.py` proves 103,185 boundary, transition-
class, and deterministic randomized cases equivalent to the retired two-RAM
implementation. The product VHDL analysis harness includes portable boundaries
for both the generic MEM RAM and this dedicated packed RAM.

Measured result: 32 more ALUTs and one fewer register in the sound hierarchy.
Quartus implements the exact 16x49 packed state in three M10Ks; the retired
pair required four, saving one M10K.

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

Measured result: 31 fewer ALUTs, with the logical block-memory bit count rising
3,072 because the combined rows use one padded 32-bit word. Physical geometry
still falls from sixteen to eight true-dual-port tag M10Ks, saving eight. Valid,
dirty, and replacement metadata deliberately remain flops. Folding
them would either make invalidate-all non-atomic, add sweep cycles, or require
generation-wrap machinery, so it did not meet the exact-semantics rule.

### `feb7ff7` — rejected IPC MLAB mapping

The explicit `MLAB` attributes on the two architectural 16x32 IPC payload
FIFOs were rejected after the real Quartus 17 map. Their required read-during-
write behavior is not supported by that forced geometry, so Quartus reported
all three replicated RAMs as uninferred and expanded them into logic.

Measured IPC hierarchy impact versus the cumulative source was 120 to 615
combinational ALUTs, 241 to 1,654 registers, and 1,536 to zero block-memory
bits: a regression of +495 ALUTs and +1,413 registers for only 1,536 bits
saved. The attributes and their mapping-only test were therefore removed. The
original inferred block-RAM implementation and collision behavior are restored
exactly; no IPC functional RTL changed.

## Verification completed

- Full `tools/test_nitro_console_island_host.sh`: PASS after the first-pass changes.
- ARM7 shifter exhaustive comparison: PASS, 158,976 cases.
- Save-profile exact reconstruction: PASS, all 4,057 oracle entries.
- Save lookup, EEPROM, FRAM, Flash, loader, and persistence simulations: PASS.
- Sound packed-state comparison: PASS, 103,185 cases.
- Cache tag comparison: PASS, 1,600,384 lane reads.
- Production cache VHDL nvc analysis: PASS. The sound analysis/elaboration
  harness was updated for its dedicated vendor RAM boundary.
- ARM hybrid-3D service cross-build and built-in self-test: PASS.
- Public repository safety audit on every staged commit: PASS.
- Worktree is isolated from the active cumulative fit and nothing was pushed.

Compiler warnings emitted by the broad host suite are pre-existing iverilog
limitations and testbench synthesis warnings; all test gates finished PASS.

## Measured mapper result and corrective action

| Change | Measured hierarchy direction | Block-memory delta | Disposition |
| --- | ---: | ---: | --- |
| ARM7 shared shifter | -90 ALUTs in `gba_cpu:icpu7` | 0 bits | Retained |
| Save-profile compression | +47 ALUTs, +20 registers | -47,616 bits | Retained |
| Sound fetch packing | +32 ALUTs, -1 register | included in total | Retained |
| ARM9 cache tag packing | -31 ALUTs | +3,072 bits | Retained pending memory-mode review |
| IPC FIFO MLAB mapping | **+495 ALUTs, +1,413 registers** | -1,536 bits | **Removed** |

Before the IPC correction, the entire experiment was +339 estimated ALMs and
+1,432 registers while saving 46,080 block-memory bits. Removing the dominant
IPC regression restored three proven 16x32 inferred RAMs. The corrected map is
141 estimated ALMs below the cumulative baseline and uses 44,544 fewer logical
block-memory bits. Quartus completed placement, routing, assembly, and timing
analysis successfully. The final fit uses 41,299 of 41,910 ALMs (99%), 44,947
registers, 3,415,552 block-memory bits, 468 of 553 M10Ks (85%), 69 DSPs, four
PLLs, and 145 pins. This is six more fitted ALMs but 13 fewer M10Ks than the
preceding Public Touch Beta. Router interconnect use is 42% average and 67%
peak. Assembly checksum is 0x0FD41911.

TimeQuest completed with the expected experimental timing violations. Its
worst-case setup slack is -14.454 ns and worst-case hold slack is -0.405 ns.
Per project policy these are diagnostic measurements, not a deployment gate;
the exact RBF still requires real-TV and gameplay testing.

Artifact identities:

- FPGA RBF SHA-256:
  `d459b7805309d01807854be6a19d241ea3bc0572b46df1176d3843abb1b82740`
- ARM service SHA-256:
  `e2e6770dfed93b4b30885c2707329534d88f87072adebc51d5e64c186244ee14`
- Hardware-source commit used by Quartus: `56511bc`

## Validation still required

1. Direct-load TV testing: LG C3/C4 and TCL; all layouts/order/gap/FPS settings;
   default 8-pixel gap; touch; sound; all save types; reset/reload.
2. Game testing: NSMB intro, map, big castle and long play; verify no 3D speed,
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
