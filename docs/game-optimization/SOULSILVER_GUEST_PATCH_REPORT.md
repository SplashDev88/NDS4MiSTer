# SoulSilver guest-code optimization — 29 October 2026

Status: active by explicit user advance from HeartGold. Cumulative SoulSilver
Beta1 is qualified and separately installed; HeartGold Beta2 remains available
for rollback. The guarded terrain transfer has the bounded field/house evidence
below. The starter transfer now also has independent bounded native qualification;
a separate cumulative Beta2 and broader coverage are next under the existing
functional/perceptual budget. Accepted Beta1 is unchanged.

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
| Starter idle draw, overlay 61 | Entire stored and decoded overlay identical; 88 target bytes match | Bounded native qualification, default disabled |
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
actual private beta qualification and the subsequent starter transfer are recorded below.

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

## Starter transfer: independent scene and reference qualification

Normal progression on accepted SoulSilver Beta1 reaches Elm's lab and writes a
new disposable save beside the starter machine, before choosing a Pokémon.
Both mirrored main/PC save chunks pass CRC checks; the newer bank has count 5
and Location `(61,-1,8,5,0)`. A full cold launch restores that position, opens
the three-ball picker and stops cleanly with the save unchanged. Seed SHA-256:
`7c1c54f2b663a0f324a788b9afcaa4d6e52c47b714bf5d5425cb2597f47f7b67`.
No HeartGold save or edited save data is used.

The full starter asset archive `a/0/8/2` (all 18 members), its 104-frame animation
and the map/event archive match the owned HeartGold image exactly. Together
with identical overlay61 and target/replacement bytes, this supports reusing
the existing 4,680-case bounded synthetic ABI/animation contract. Those cases
were not rerun or represented as new SoulSilver runtime validation.

The independent 3600-frame original picker replay repeats with all 80 files
identical. A separate 8400-frame original lifecycle repeats all 208 files and
covers all three species, both rotation directions, zoom, cancellation, choice
and return to the lab/nickname prompt. The retained terrain plus unchanged
overlay61 delivery control separates the new starter gate from existing
terrain/boot timing differences.

| Starter idle, reference frames 1800–3599 | ARM9 instructions |
| --- | ---: |
| Original SoulSilver | 87,223,533 |
| Accepted Beta1 terrain | 87,223,589 |
| Terrain plus unchanged overlay61 delivery | 87,223,589 |
| Terrain plus starter idle gate | 43,100,107 (−50.5866%) |

The candidate matches both screens on all 3,600 frames and preserves the save.
The retained final main-RAM image also matches after exact patch-byte
normalization. Intermediate RAM/timing and audio differences remain: 16,711
same-index stereo samples differ out of 2,888,368 (RMS 7.12 signed16 units,
maximum 3,653). This is not an inaudibility judgment. The legacy strict mismatch
label remains in the raw receipt under the authorized functional budget.
Instruction reduction is not native cycles or speed; independent native evidence
is recorded below. The starter patch remains default-disabled and absent from
accepted SoulSilver Beta1 pending a separately qualified cumulative Beta2.

The candidate also matches both screens on every frame of the 8400-frame
selection lifecycle, including all 16 paired screen checkpoints, and preserves
the save. ARM9 instructions in frames 1800–8399 fall from 504,652,367 to 467,508,667
(−7.3603%). All three species, rotation, zoom, both cancellations, Chikorita
choice and return to the lab/nickname prompt remain covered. The final main-RAM
checkpoint matches after code normalization. Intermediate state/audio drift
remains; this route does not write a new normal save after choosing.

A separate 3600-frame downstairs-house route never opens the starter picker.
Its cumulative control and candidate match all 65 output files, including raw
screens, RAM, audio, save and instruction profiles. This distinguishes the new
starter gate from existing terrain/layout differences against the old baseline.

Evidence: `STARTER_ASSET_TRANSFER_AUDIT_V1.json`,
`STARTER_NATIVE_SCENE_ADMISSION_V1.json`, `STARTER_REFERENCE_ADMISSION_V1.json`,
`STARTER_LIFECYCLE_ADMISSION_V1.json`, `STARTER_DRAW_CONTRACT_REUSE_V1.json`,
`STARTER_DRAW_IDLE_COMPARISON_V1.json`,
`STARTER_DRAW_LIFECYCLE_FUNCTIONAL_REVIEW_V1.json`,
`STARTER_DRAW_OFF_TARGET_REVIEW_V1.json`,
`STARTER_DRAW_REFERENCE_BEFORE_AFTER_V1.csv` in the private evidence folder.

## Starter transfer: native qualification

One 88-byte ARM9 Thumb patch at `0x021e5ef8` in overlay61 uses no scratch memory.
It preserves animation updates and the 104-phase light cycle, retaining phases
0 and 7 modulo 8 while avoiding 78 duplicate idle draws. The gate applies only
to application state 5/selection state 0; active selection, rotation, zoom and transitions retain
their work. Explicit zero return, literal pool and incoming branch are preserved.
Full SoulSilver ROM/header/stored/decoded overlay identity and original bytes
guard application through the existing virtual-cartridge/normal-overlay path.

All three arms retain the accepted terrain patch and use the same independent
pre-starter save. They cold-start separately at stock 1 GHz with identical host,
renderer, FPGA and renderer settings, with frame skipping off. The only runtime
data difference from accepted Beta1 is the private trial manifest. Two 30-second
windows per arm measure:

| Starter idle | Window 1 pairs/s | Window 2 pairs/s | Weighted pairs/s | Renderer CPU, % one core |
| --- | ---: | ---: | ---: | ---: |
| Accepted Beta1 terrain | 14.2190 | 14.2430 | 14.2310 | 162.22 |
| Terrain + unchanged overlay61 delivery | 14.2038 | 14.2237 | 14.2138 | 162.02 |
| Terrain + starter gate | 44.2226 | 43.6662 | 43.9443 | 109.91 |

Complete screen-pair publications improve **208.7928% over Beta1 (3.0879×)**
and **209.1670% over matched delivery**, with **32.2445% less renderer CPU use**.
Host CPU is 3.00% before and 3.40% after, in percent of one core. These are
within-session windows, not independently repeated cold starts, confidence
intervals, unique animation FPS, native guest cycles or whole-game speed.
Existing counters do not supply per-frame guest cycles, p95 frame times,
missed VBlanks or DMA bytes. Active selection does not inherit the idle gain.

The same four fixed lamp regions give a dominant light period of 3.4833 seconds
for Beta1 and 3.4667 seconds for delivery and candidate; the difference is one
60 Hz capture sample. The candidate retains the expected 104/30-second cycle.
All four captures (three idle arms and candidate selection) have zero added
render/output drops. Sampled native frames show all three species, rotation in
both directions, zoom, confirmation, two cancellations and successful Chikorita
choice. Review MP4s preserve encoded video, the game-audio track and packet
timestamps. Audio signal presence/statistics and sampled inspection do not
establish inaudibility or full-motion human approval.

The candidate completes nickname decline/Elm dialogue, writes a normal Save,
soft-resets and reloads the lab with Chikorita. The resulting save is preserved
as `61e22264c88bd776a19db92bde916fc6da6bf08d2614dd5e48d04904b3517e24`.
Both mirrored main/PC banks pass CRC checks; the newer bank is count 6 at
Location `(61,-1,4,7,0)`. A fresh host/renderer process then cold-loads the same
save, opens a party screen showing level 5 Chikorita with 19/19 HP, and exits the
lab through the normal Potion tutorial into New Bark Town/Lyra dialogue.
The final stop preserves the new save exactly. The owned Draw1 disposable save
remains at that hash; no original save was edited or replaced. Later dialogue,
battles and whole-game progression are outside this bounded check.

The source manifest adds only this default-disabled patch. Original, retained
terrain-only and cumulative streams are verified by the existing actual loader;
removing the unchanged delivery-control pseudo-patch preserves the exact native
candidate image. No runtime binary or core save-state format changes. Accepted
SoulSilver Beta1, HeartGold Beta2 and rc12 remain unchanged; trial qualification
does not substitute for testing a newly packaged beta.

Evidence: `STARTER_DRAW_NATIVE_QUALIFICATION_V1.json`,
`STARTER_DRAW_NATIVE_MEASUREMENTS_V1.json`,
`STARTER_DRAW_NATIVE_BEFORE_AFTER_V1.csv`,
`STARTER_NATIVE_CANDIDATE_MEDIA_REVIEW_V1.json`,
`STARTER_NATIVE_SELECTION_VISUAL_REVIEW_V1.json`,
`STARTER_NATIVE_COLD_VISUAL_REVIEW_V1.json`,
`NATIVE_DRAW_POST_STARTER_ADMISSION_V1.json`,
`PUBLIC_STARTER_WORKER_QUALIFICATION_V1.json` and
`STARTER_DRAW_FINAL_PRESERVATION_V1.json` in the private evidence folder.

## Next work and HeartGold backports

Build and qualify the actual cumulative SoulSilver Beta2 archive and installed
launcher with terrain plus starter, preserving accepted Beta1. Broader field/camera
and active battle profiling, then measured loading/repeated-resource work,
remain the other leads. Do not repeat completed unchanged suites without a new
reason or treat this starter-idle improvement as a field/battle speedup.

The user now authorizes checking genuinely new, useful SoulSilver gains for a
HeartGold backport. Verify HeartGold's exact code/assets and independently test
functionality and native benefit against retained HeartGold Beta2 before
packaging. The terrain and starter transfers originated in HeartGold and are
not new backport opportunities. Unrelated parked HeartGold, FFT and Ecclesia
research remains parked. The existing 08:00 Central handoff and autonomous
continuation remain active; no playtest reply is required.
