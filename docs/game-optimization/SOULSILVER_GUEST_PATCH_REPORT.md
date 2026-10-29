# SoulSilver guest-code optimization — 29 October 2026

Status: active by explicit user advance from HeartGold. Cumulative SoulSilver
Beta1 is qualified and separately installed; HeartGold Beta2 remains available
for rollback. The guarded terrain transfer has the bounded field/house evidence
below. Starter transfer and broader coverage are next under the existing
functional/perceptual budget.

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
| Terrain visibility, overlay 1 | 48 target bytes, all data guards and six caller/helper spans match; nine differences elsewhere in the overlay | Bounded native qualification, default disabled |

Each port must use SoulSilver's own full ROM/header/overlay identity. Related
titles and matching addresses are insufficient. A code match does not validate
resources, progression, scene timing or native gain.

Private evidence: `OWNED_IDENTITY_V1.json`, `OWNED_INPUT_TRANSFER_V1.json`,
`HEARTGOLD_TRANSFER_AUDIT_V1.json`, `TRANSFER_DEPENDENCIES_V1.json` in
`evidence/soulsilver-optimization-20261029`.

## Independent baseline

The independent 18,000-frame first-save route repeats with all 193 output files
identical, including both screens, RAM checkpoints, audio and save. Inspected
frames show Oak's introduction, the bedroom, mother's tutorial and the ordinary
Save confirmation at frame 16080. The save remains stable for the final 2073
frames. Two 3600-frame cold boots match all 64 files, preserve that save exactly
and visibly return to the downstairs room with Save/Bag/Options available.
Seed SHA-256: `8eaebf214d4314cd910b32f2b92399df97ccc6433f02521f8eeb80013529253f`.
This establishes the unpatched reference baseline. Subsequent bounded native and
soft-reset checks are recorded below; battle coverage remains pending.

Private disabled transfer and unchanged-code delivery manifests now use the
SoulSilver identities. The existing loader admits the separately selected
terrain/starter and combined streams. Applying the HeartGold manifest to
SoulSilver instead fails its identity guard and returns the exact original
stream. No patched ROM file was written. Candidate installation is confined to the
isolated native trial described below.

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
| Native throughput | See matched native comparison below | See matched native comparison below |

The real bounding-box query rejects 729 terrain draws. Its constants receive no
nonmatching writes after complete overlay identity at frame 938 and no writes
in the target window. This uses existing stack space; there is no unused-memory
claim or new service. Nine paired outdoor snapshots preserve terrain, objects,
movement and menus. Bottom frame 3188 differs; the existing thumbnail samples localize ten changed
pixels to a Save-menu redraw. Full-resolution/perceptual equivalence is not claimed.
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
candidate remains default-disabled. Native qualification is recorded below;
actual private beta qualification is recorded below; the starter transfer remains next.

Evidence in `evidence/soulsilver-optimization-20261029`:
`OUTDOOR_BASELINE_QUALIFICATION_V1.json`, `OUTDOOR_HOTSPOT_CLASSIFICATION_V1.json`,
`TERRAIN_REFERENCE_FINDINGS_V1.json`, `TERRAIN_INDOOR_FINDINGS_V1.json`,
`TERRAIN_REFERENCE_REVIEW_V1.json`, `TERRAIN_BEFORE_AFTER_V1.csv`, and
`NATIVE_TERRAIN_WORKER_QUALIFICATION_V1.json`.

## Native terrain qualification

Manifest: `soulsilver-ipge-r0.json`. One 48-byte Thumb patch in overlay1; unchanged
rc12-derived host, renderer and FPGA, stock 1 GHz, no scratch or HPS service.
The independent SoulSilver native Save/reload produces the plaza fixture
`1284f9a7f87b2fd255ddf7b806593f5dc4444a84a4e5508d82849a1e630689d5`.
No HeartGold save is imported. Original, decoded delivery and patched cold loads
all return to the same camera/tile with the expected staged bytes and header.

An initial comparison crossed 18:00 on the guest clock. Warmer field colors and
a faster warm-reset result made those trials unsuitable for the final comparison.
They remain exploratory in `NATIVE_CLOCK_CONFOUND_V1.json`. The existing per-kit
`NDS_rtc.cfg` v2 calendar setting then seeded each cold run at 2026-10-29 Thursday
12:00:00; host logs verify that exact seed. Guest time advances normally. This
uses the existing host clock feature; no system clock, runtime or accepted kit
changes. The temporary private setting was restored and must not enter a beta.

| Fixed noon plaza | Window 1 pairs/s | Window 2 pairs/s | Weighted pairs/s |
| --- | ---: | ---: | ---: |
| Original | 18.8404 | 18.7837 | 18.8120 |
| Decoded delivery, original instructions | 18.7589 | 18.7208 | 18.7398 |
| Terrain visibility patch | 20.0952 | 19.9618 | 20.0285 |

The patch improves complete screen-pair publications **6.4663% over original**
and **6.8766% over matched delivery**. These are two 45-second windows within one
cold session per arm, not independent repeated cold starts, confidence intervals,
unique animation FPS or whole-game speed. HPS process CPU use, in percent of one
core, is host 3.39 / renderer 160.87 for original versus 3.34 / 162.50 patched (two cores
available). No new offload competes with the renderer. Existing counters do not
provide per-frame guest cycles, missed VBlanks, DMA bytes or p95 frame times.

Matched noon house windows measure 59.6090 original and 59.5851 patched pairs/s
(−0.0402%, effectively at the same ceiling). Both native Bag PNGs match exactly.
The candidate enters and exits the house, opens/closes Bag, performs normal Save,
and soft-resets/reloads the new house-entrance save. Its saved bytes are preserved
separately as `dd2098e4b104cc366deed35f7d5c9c0b735673305a13fc2b4344adade66e8cac`;
the private comparison save was restored from its pinned initial fixture. The
first Bag-close/exit attempt remained in menu focus; an explicit extra cancel
then completed the transition. This was retained rather than marked as a pass.

All three clock-controlled OBS captures have zero added render/output drops.
Four sampled frames per arm retain the same scene, objects, menu and noon colors.
Review copies retain original encoded video, game-audio packets and timestamps;
the silent first audio track is excluded. This is sampled inspection and signal
presence, not full-motion human approval or an inaudibility verdict. Thin transient
diagonal geometry lines also occur in unpatched native SoulSilver and remain a
baseline issue. Core save states remain unsupported. Native measurements and
functional checks are bounded to New Bark Town and the house, not the whole game.

The public manifest passes the actual worker's original/candidate stream checks
and produces the identical native-tested candidate stream. Evidence:
`NATIVE_TERRAIN_CLOCKED_FINDINGS_V1.json`, `NATIVE_TERRAIN_BEFORE_AFTER_V1.csv`,
`NATIVE_TERRAIN_VISUAL_REVIEW_V1.json`, `NATIVE_CANDIDATE_SAVE_RESTORE_V1.json`,
`NATIVE_CLOCK_RESTORED_V1.json`, `PUBLIC_TERRAIN_WORKER_QUALIFICATION_V1.json`.
Review clips: `SoulSilver_Original_Clocked_V2.mp4`,
`SoulSilver_Delivery_Control_Clocked_V2.mp4`, and
`SoulSilver_Terrain_Candidate_Clocked_V2.mp4` in the private SoulSilver evidence folder.

## Cumulative private Beta1

`NDS4MiSTer_SoulSilver_Beta1_20261029.zip` is qualified at SHA-256
`2b1bd9c0d76f6dc7e1d75d0cbde8738be4f2547b72ebb6ba419c3aa258d19967`
(55,530,017 bytes). The packaged source is
`9ba2e280cd38a0b0226a7fcceb7c4b17a18dd857`. This report's later packaging record
does not change that immutable archive. Run `Scripts/NDS_SoulSilver_Beta1.sh`;
the separate kit is `Scripts/.NDS_SoulSilver_Beta1_20261029`.

The existing pinned catalog adds only SoulSilver's terrain selection. Host,
renderer, FPGA and loader bytes remain identical to cumulative HeartGold Beta2;
all earlier catalog entries are unchanged. Actual ZIP worker tests reproduce the
measured SoulSilver virtual image and the eight retained HeartGold, Platinum,
Portrait, Ni no Kuni, NSMB, Dawn, Mario Kart and FFT control images. These are
packaged stream checks, not new native gameplay coverage for those other games.
ROMs, saves, user settings, captures and the test RTC fixture are excluded.

All 201 installed files including the launcher are verified. The actual launcher
cold-loads the candidate-written house-entrance save and selects the expected
48-byte patch. A short recorded plaza walk, house entry, Bag and house exit pass.
Normal Save at a different plaza position, soft reset and Continue pass; after
full process exit and save readback, a second actual-launcher cold boot restores
that position. Its 512 KiB save remains
`32f8ab642da1541467c10877875728d1f7f8ae414b1dfa385bf84cc286a43060`.
Stock 1 GHz and ordinary guest clock seeding with zero offset are verified.
Six sampled walk frames preserve the scene; source video/game-audio packets and
timestamps are unchanged in the review copy, with zero added capture drops.
No human full-motion/listening approval is inferred.

The final audit verifies 4509 protected files, 85 runtime pins, all 200 kit files,
the launcher and six immutable local archives. MiSTer returns to MENU, OBS stays
idle with its original scene/video settings, and no test clock file remains.
Qualification and coverage: `BETA1_INSTALLATION_QUALIFICATION_V1.json`,
`BETA1_NATIVE_FUNCTIONAL_REVIEW_V1.json`, `BETA1_COVERAGE_V1.json`,
`BETA1_STREAM_VALIDATION.json`, `BETA1_FINAL_PRESERVATION_V1.json`.
The separate review clip is `SoulSilver_Beta1_Installed_Walk_V1.mp4`.

## Next work

Admit an independent SoulSilver Elm-lab/starter-picker save through normal
progression, then compare Beta1 terrain against terrain plus the identical
starter overlay 61 transfer. Qualify active selection, light cycles, saves and
native benefit before including it. The other two investigations are broader
field/camera and active battle coverage, and loading/repeated-resource work.
HeartGold remains user-parked at Beta2. The existing 08:00 Central handoff and
autonomous continuation remain active; no playtest reply is required.
