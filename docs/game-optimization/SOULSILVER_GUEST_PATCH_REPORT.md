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

The independent 18,000-frame first-save route repeats with all 193 output files
identical, including both screens, RAM checkpoints, audio and save. Inspected
frames show Oak's introduction, the bedroom, mother's tutorial and the ordinary
Save confirmation at frame 16080. The save remains stable for the final 2073
frames. Two 3600-frame cold boots match all 64 files, preserve that save exactly
and visibly return to the downstairs room with Save/Bag/Options available.
Seed SHA-256: `8eaebf214d4314cd910b32f2b92399df97ccc6433f02521f8eeb80013529253f`.
This is unpatched reference qualification; native/soft-reset/battle checks remain.

Private disabled transfer and unchanged-code delivery manifests now use the
SoulSilver identities. The existing loader admits the separately selected
terrain/starter and combined streams. Applying the HeartGold manifest to
SoulSilver instead fails its identity guard and returns the exact original
stream. No patched ROM file was written or candidate installed.

## Terrain transfer reference results

The 9600-frame independent outdoor route is qualified by an unchanged repeat:
all 154 baseline files match. Its read-only contract trace observes 1158 terrain
calls with the expected caller bytes, identity rotation and unit scale. Graphics
FIFO submission, IRQ/scheduler handling and math context dominate the ARM9
profile; these are instruction samples, not native cycle shares.

| Bounded measurement | Decoded delivery control | Terrain candidate |
| --- | ---: | ---: |
| ARM9 instructions, outdoor frames 6000–9599 | 702,381,026 | 671,801,437 (−4.3537%) |
| Terrain draws, observed frames 6000–6599 | 1,158 | 429 |
| Top-screen hashes differing from control | — | 0 / 9,600 |
| Bottom-screen hashes differing from control | — | 1 / 9,600 |
| Save bytes | Independent seed | Exact |
| Indoor ARM9 instructions, recorded window | 270,532,896 | 271,110,642 (+0.2136%) |
| Native throughput | Pending | Pending |

The real bounding-box query rejects 729 terrain draws. Its constants receive no
nonmatching writes after complete overlay identity at frame 938 and no writes
in the target window. This uses existing stack space; there is no unused-memory
claim or new service. Nine paired outdoor snapshots preserve terrain, objects,
movement and menus. Bottom frame 3188 differs and remains unclassified visually.
The separate 3600-frame indoor replay matches both screens on every frame and
preserves the save; three paired snapshots show the expected room/menu.

Timing/RAM/audio drift is retained under the authorized functional budget.
Outdoor same-index PCM differs in 593,989 / 7,702,322 stereo samples (RMS 71.33,
maximum signed16 delta 8600); indoor differs in 2682 samples (RMS 0.158, max178).
These statistics do not establish audibility. Unchanged decoded delivery also
changes timing versus compressed original; the matched delivery control keeps
that effect separate. Reference work reduction does not prove native speedup.

The existing native worker passes all three stream identity cases: original,
unchanged decoded delivery and terrain candidate. No ROM is rewritten. The
candidate remains default-disabled and unpromoted pending independent native
cold boot, scene/save/reset checks, paired throughput and audiovisual captures.
Starter transfer and active battle/loading remain subsequent work.

Evidence in `evidence/soulsilver-optimization-20261029`:
`OUTDOOR_BASELINE_QUALIFICATION_V1.json`, `OUTDOOR_HOTSPOT_CLASSIFICATION_V1.json`,
`TERRAIN_REFERENCE_FINDINGS_V1.json`, `TERRAIN_INDOOR_FINDINGS_V1.json`,
`TERRAIN_REFERENCE_REVIEW_V1.json`, `TERRAIN_BEFORE_AFTER_V1.csv`, and
`NATIVE_TERRAIN_WORKER_QUALIFICATION_V1.json`.
