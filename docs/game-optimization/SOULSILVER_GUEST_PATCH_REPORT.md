# SoulSilver guest-code optimization — 29 October 2026

Status: active by explicit user advance from HeartGold. HeartGold Beta2 remains
the cumulative private baseline and rollback. SoulSilver has no qualified patch,
native improvement or beta yet. Use the existing functional/perceptual budget.

## Existing workflow reused

The existing `tools/standalone_host/fmv/prepare.py`, `hook_guard.py` and
`guest_byte_patch.py` identify the ROM/header and stored/decoded overlays, check
original bytes and serve a virtual cartridge while reset is held. Normal boot
and overlay reloads load the replacement bytes; original ROM files stay
read-only. Compressed-main-code patching is not admitted by this adapter.

`tools/game_optimization/replay_oracle.cpp` supplies deterministic input/RTC,
both-screen/RAM/audio/save comparisons, ARM9/ARM7 instruction sampling and the
existing optional memory/geometry observers. Native session and capture tools
measure screen-pair publications and bounded functionality at stock 1 GHz.
Instruction counts are not native cycles, and publications are not necessarily
unique animation frames. Persistent core save states remain unsupported.

Both guest CPUs, memory, timing, DMA and sound are FPGA-owned. The HPS performs
rendering/composition using the existing shared-DDR graphics packet/mailbox
interface. No new HPS service, live-PC HLE mechanism or RTL changes are proposed.
Reuse the accepted HeartGold work and shared pattern tools; prior SoulSilver
experiments returning zero clip/visibility results removed visible objects and
are not safe substitutes for the actual query.

## Owned revision and transfer audit

The owned USA image is IPGE revision 0, 134,217,728 bytes, SHA-256
`51d0f94a16af7d77c067b4cb7d821ba890a13203a2e2c76049623332c0582e20`.
The 352-byte header SHA-1 is `a91340f00feab7b2e4ba9299b22517e0f2bb85e2`;
header CRC32 is `3a631784`. Remote hashes before/after the read-only copy agree.
No HeartGold save is imported; a separate blank seed starts the SoulSilver run.

114 of 129 decoded ARM9 overlays match HeartGold byte for byte. All loaded ARM7
sections and ARM9 ITCM/DTCM autoload sections match. The main ARM9 section has
158 differing bytes after its 0x800-byte secure area; whole-program equivalence
is not claimed.

| HeartGold accepted patch | SoulSilver code evidence | Status |
| --- | --- | --- |
| Starter idle draw, overlay 61 | Entire stored and decoded overlay identical; 88 target bytes match | Transfer candidate, disabled |
| Terrain visibility, overlay 1 | 48 target bytes, all data guards and six caller/helper spans match; nine differences elsewhere in the overlay | Transfer candidate, disabled |

Each port must use SoulSilver's own full ROM/header/overlay identity. Related
titles and matching addresses are insufficient. A code match does not validate
resources, progression, scene timing or native gain.

Private evidence: `OWNED_IDENTITY_V1.json`, `OWNED_INPUT_TRANSFER_V1.json`,
`HEARTGOLD_TRANSFER_AUDIT_V1.json`, `TRANSFER_DEPENDENCIES_V1.json` in
`evidence/soulsilver-optimization-20261029`.

## Qualification next

Establish and repeat an unpatched first-save route and cold reload. Reusing
HeartGold's input timings is an exploratory navigation aid until the SoulSilver
screens and saved progress are inspected. Then qualify terrain and starter
ports separately, including unchanged-code delivery controls, scene transitions,
normal save/reset/reload and native paired measurements. Preserve raw output
drift; accept only functioning gameplay and useful native benefit.

No SoulSilver before/after table is available yet: both candidate throughput
and baseline native scene measurements are pending. Three subsequent leads are
terrain/visibility work informed by the parked shape census, active battle and
loading profiles, and recurring model/resource work specific to SoulSilver.
