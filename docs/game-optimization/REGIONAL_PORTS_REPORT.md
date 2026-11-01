# RC13 regional ports

Regional work branches from the unpublished RC13 candidate, source
`2fb28bd437834cb76300d1fca5aa14dbf58cf711`. The packaged candidate and accepted
betas are preserved. The qualified regional starter ports described below are
eligible for explicit private catalog inclusion. Source manifests remain disabled
by default.

## HGSS starter candidates, 2026-10-31

The owned inventory contains 15 files: the two accepted USA controls, twelve
German/French/Italian/Japanese/Korean/Spanish HGSS identities, and a
Europe-labelled HeartGold file reporting IPKE revision 10. The last file is
quarantined; its official revision provenance is not established.

All twelve regional starter candidates match the original 88 patch bytes at
overlay 61 offset `0x5f8`. All eighteen starter-archive members match the USA
control, including the 104-frame turntable animation. Overlay bases occupy six
distinct regional layouts. The unchanged replacement's two relative calls and
the Main function's incoming branch resolve correctly in each layout.

Four bounded draw spans have matching instruction layouts and identical
non-call instruction bytes across the twelve identities. External callees and
literal values are retained in the private audit, including their differences;
64-byte callee-prefix matches are identification evidence, not whole-function
semantic proof. Whole overlay hashes differ and must remain identity-specific.

| Check | Result | What it establishes |
| --- | --- | --- |
| Owned identity and expected-byte audit | 12 disabled candidates | Exact inputs and patch locations |
| Relocated CPU contract | 28,080 cases passed across six layouts | Bounded registers, memory and call contract |
| German virtual delivery | Original/control/candidate streams checked | Existing loader admits exact identity |
| Wrong USA identity on German input | Unchanged fallback | No accidental cross-region application |
| German independent first save | Generated from blank save | Regional new-game progression |
| German cold-load repeat | Two identical 3,600-frame runs; save unchanged | Repeatable first-room baseline |
| German starter idle | 3,600 screen pairs exact | Regional target-scene replay |
| German native lifecycle | Selection, Save, soft reset and cold party passed | Bounded functional qualification |

The CPU harness now permits a modeled callee in the tested code's mapped page
when it does not overlap the tested extent. This supports relocated Thumb
layouts without remapping executable pages. Target overlap and invalid mappings
remain rejected. The meaningful harness regression tests pass; runtime binaries
are unchanged.

German SoulSilver IPGD revision 0 is the first qualified starter port. The first
two exploratory input recordings missed the bedroom exit because of dialogue
timing; neither is a qualified save route. The third recording maintains intro
confirmation pulses and delays movement, reaches a successful normal Save, and
cold-loads the downstairs room. This is first-room coverage only.

Private receipts and disabled manifests are under
`evidence/regional-ports-20261031` in the orchestration workspace:
`STARTER_PORT_STATIC_AUDIT_V1.json`, `STARTER_REGIONAL_SYNTHETIC_V1.json`,
`STARTER_SYNTHETIC_HARNESS_PROVENANCE_V1.json`,
`STARTER_REGIONAL_DEPENDENCIES_V1.json`, `IPGD_STARTER_VARIANTS_V1.json`, and
`IPGD_FIRST_SAVE_ADMISSION_V1.json`. The per-identity directories contain exact
guarded `STARTER_CANDIDATE_MANIFEST_V1.json` files, all disabled. No ROM, save,
extracted code context or private resource is added to this source repository.

## Qualification and remaining work

All twelve owned non-USA HGSS revision-0 starter ports are qualified and packaged
in immutable Regional Beta4 R2. All six owned German, French, Italian, Spanish,
Japanese and Korean SoulSilver revision-0 terrain ports are qualified separately
and queued for a new cumulative private package. HeartGold terrain, Platinum
and FFT A2 regional ports remain pending. No unowned revision or quarantined identity is admitted.

Use regional starter inputs, unchanged decoded delivery controls,
active selections and transitions, normal save/cold reload, soft reset,
unrelated scenes and paired native measurements. Preserve the authorized raw
timing/RAM/audio differences. Do not transfer the USA speed percentages or
human approval to a region. Confirm visible animation cadence separately from
screen-pair publication throughput.

### German SoulSilver starter qualification

`soulsilver-ipgd-r0.json` authenticates the owned IPGD revision 0 ROM and overlay
61. The tested single-patch release stream exactly matches the native trial
stream. It remains default-disabled until explicit private catalog selection.

| Metric, bounded starter idle | Original/control | Candidate |
| --- | ---: | ---: |
| Reference ARM9 instructions, frames 1800–3599 | 87,222,620 | 43,105,090 (−50.58%) |
| Native completed screen pairs/s, stock 1 GHz | 14.3012 | 43.9687 (3.0745×) |
| Renderer CPU, percent of one core | 161.97% | 110.29% |
| Measured light cycle | 3.4667 s | 3.4833 s |

One verified 30-second native window per arm suffices for this large effect;
no variance estimate or whole-game FPS claim is made. The light-period difference
is one captured 60 Hz frame. Capture quality and game-audio signal checks pass;
they do not establish human audibility approval. Native CPU-cycle, DMA/cart-byte
and frame-time percentile counters are unavailable in this run.

All 3,600 reference screen pairs match both original and unchanged decoded
delivery. Raw RAM/timing/audio differences are retained under the authorized
functional budget. Native inspection covers all three localized species,
rotation both ways, inspect/cancel/confirm, final Endivie choice and return to
the lab. Normal Save, soft-reset Continue and a fresh-process cold Continue/party
check pass; the selected Pokémon remains intact and the cold session leaves the
newly written save unchanged. The target scene uses a documented imported USA
checkpoint; it is not independent German new-game progression.

An unrelated 3,600-frame first-room candidate replay reuses the already captured
German baseline. Both screens, full audio, save and instruction traces match.
There are 36 persistent main-RAM differences: 28 exactly match changed virtual
header/FAT bytes, with eight additional startup-area bytes retained raw. One
frame has a DTCM hash difference. These are not claimed bit-exact or hidden by
normalization. The target overlay is absent, as intended; the target-scene
runner's absent-overlay assertion is recorded separately from the completed
output comparison, avoiding an unnecessary rerun.

Private qualification: `IPGD_STARTER_QUALIFICATION_V1.json`. Videos:
`SoulSilver_German_Starter_Original_V1.mp4`,
`SoulSilver_German_Starter_Candidate_V1.mp4`, and
`SoulSilver_German_Starter_Selection_V1.mp4`. No ROMs, saves or captured private
code are included in this repository. Remaining regional starter candidates and
all regional terrain ports remain unqualified.

### French SoulSilver starter qualification

`soulsilver-ipgf-r0.json` authenticates IPGF revision 0 and its distinct overlay
61 hash/base. The shared asset/dependency audit and six-layout CPU contract are
reused. Its own 3,600-frame original/delivery/candidate comparison preserves every
screen pair and save. ARM9 instructions fall from 87,221,604 to 43,098,689
(50.5871%) in frames 1800–3599. Raw RAM/timing/audio differences are retained.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.2359 | 42.7749 (3.0047×) |
| Renderer CPU, percent of one core | 161.72% | 110.30% |
| Measured light cycle | 3.4667 s | 3.4833 s |

The difference in measured light period is one captured frame. Video capture
quality and game-audio signal checks pass; human audibility approval is not
claimed. Native inspection covers Germignon, Héricendre and Kaiminus, both
rotation directions, inspect/cancel/confirm and final Germignon choice. Normal
Save writes a changed 512 KiB file; soft-reset Continue restores the lab and
follower. A fresh-process cold Continue/party check restores Germignon at level 5,
20/20 HP, and leaves the saved file unchanged.

This final cold input replay supplies unrelated lab/menu coverage without
entering the starter scene. The common delivery proof and German unrelated
software replay are reused; a separate French software collateral comparison
is not claimed. The target checkpoint is imported from USA and is not independent
French new-game progression. Native cycle/frame-time percentile/DMA/cart counters
remain unavailable, and publications are not unique animation or whole-game FPS.

Private receipts: `IPGF_STARTER_QUALIFICATION_V1.json` and
`IPGF_STARTER_BEFORE_AFTER_V1.csv`. Review videos use the prefix
`SoulSilver_French_Starter_`. Actual cumulative archive/launcher qualification
remains a separate packaging gate.

### Italian SoulSilver starter qualification

`soulsilver-ipgi-r0.json` authenticates IPGI revision 0 and its own overlay 61
identity. The existing loader, shared asset/dependency audit and six-layout CPU
contract are reused. Its original/delivery/candidate replay preserves all 3,600
top/bottom screen pairs and the save. Sampled ARM9 instructions fall from
87,222,076 to 43,099,161 (50.5869%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.2831 | 44.8013 (3.1367×) |
| Renderer CPU, percent of one core | 162.03% | 110.04% |
| Measured light cycle | 3.4833 s | 3.4833 s |

Capture quality and game-audio signal checks pass. Native selection exercises
the Italian Chikorita, Cyndaquil and Totodile previews, both rotation directions,
inspect/cancel/confirm and final Chikorita choice. Normal Save changes the 512 KiB
save, soft-reset Continue restores the lab and follower, and a fresh-process
cold Continue/party check restores male Chikorita at level 5 with 20/20 HP.
The cold run leaves the saved file unchanged and does not enter the target scene.

The imported USA checkpoint and common German unrelated software evidence are
reused; independent Italian new-game progression, a separate Italian software
collateral comparison and human listening approval are not claimed. Raw
timing/RAM/audio differences remain within the existing functional test budget.
Publications are not unique animation FPS or whole-game speed. Native cycle,
frame-time percentile, DMA and cartridge counters remain unavailable.

Private receipts: `IPGI_STARTER_QUALIFICATION_V1.json` and
`IPGI_STARTER_BEFORE_AFTER_V1.csv`; videos use the prefix
`SoulSilver_Italian_Starter_`. Actual archive/launcher validation remains a
separate packaging gate. The manifest is default-disabled and contains only
the starter patch; Italian terrain remains unqualified.

### Spanish SoulSilver starter qualification

`soulsilver-ipgs-r0.json` authenticates IPGS revision 0 and its distinct overlay
61 identity. Shared asset/dependency checks and the existing six-layout CPU
contract are reused. Its original/delivery/candidate replay preserves all 3,600
screen pairs and the save. ARM9 instructions fall from 87,221,604 to 43,098,689
(50.5871%) in frames 1800–3599. Raw RAM/timing/audio differences are retained.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.1723 | 43.2025 (3.0484×) |
| Renderer CPU, percent of one core | 161.78% | 110.59% |
| Measured light cycle | 3.4833 s | 3.4667 s |

The measured light-period difference is one captured frame. Capture quality and
game-audio signal checks pass; human listening approval is not claimed. Native
selection exercises Chikorita, Cyndaquil and Totodile with Spanish prompts,
both rotation directions, inspect/cancel/confirm and final Chikorita selection.
Normal Save writes a changed 512 KiB file, soft-reset Continue restores the lab
and follower, and a fresh-process cold Continue/party run restores female
Chikorita at level 5 with 20/20 HP. The cold run leaves the save unchanged.

The cold lab/party input replay supplies unrelated-scene coverage without loading
the starter scene. Shared German software collateral evidence is reused; there
is no separate Spanish software collateral pair or independent Spanish new-game
playthrough. The target checkpoint is imported from USA. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable; publications are not unique
animation FPS or whole-game speed.

Private receipts: `IPGS_STARTER_QUALIFICATION_V1.json` and
`IPGS_STARTER_BEFORE_AFTER_V1.csv`. Videos use the prefix
`SoulSilver_Spanish_Starter_`. The source manifest is default-disabled and queued
for a later cumulative private beta; the immutable Regional Beta2 does not include
this Spanish port. Spanish terrain remains unqualified.

### Terrain dependency locating, read-only

The direct-flow locator finds unique candidates for six bounded dependency spans
in each of the six SoulSilver regions. For the bounding-box query, 118 reached
Thumb instruction layouts and both internal call edges match the USA reference.
The earlier Japanese/Korean misses came from stopping at embedded literal data
and comparing unreached code in the supplied extent. The revised locator excludes
unreached bytes explicitly, records external call targets and literal values, and
does not claim their equivalence. External callee/data checks and regional runtime
qualification remain necessary; no terrain patch has been generated or enabled.
See `SOULSILVER_BBOX_FLOW_LAYOUT_V1.json` and
`SOULSILVER_TERRAIN_FLOW_MASKED_CANDIDATES_V3.json` for private evidence.

### Pokemon SoulSilver (Japan) starter qualification

`soulsilver-ipgj-r0.json` authenticates IPGJ revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,456,282 to 43,334,237 (50.4504%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.2626 | 43.7589 (3.0681×) |
| Renderer CPU, percent of one core | 161.68% | 110.86% |
| Measured light cycle | 3.4667 s | 3.4667 s |

Japanese Chikorita, Cyndaquil and Totodile previews, both rotation directions,
inspect/cancel/confirm and final Chikorita choice were exercised. Sampled
images and the direct framebuffer endpoint show intact models/text and return
to the lab. The selection recording lost one OBS encoded frame (zero render
drops, continuous decoded timestamps); it is used only for visual checkpoints,
not selection cadence or audio equivalence. Separate idle captures passed
recording quality and establish unchanged measured light cadence.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Japanese neutral lab and Chikorita
follower. Party shows male Chikorita at level 5 with 19/19 HP and localized
selection/exit text, with no obvious visual corruption. The cold run leaves
the saved file unchanged and does not enter the starter scene.

The measured light period remains within one captured frame of control. Quality
checks passed for both idle recordings and the game audio signal; human listening
approval is not claimed. Raw timing/RAM/audio differences remain under the existing
functional budget. Target checkpoints are imported from USA, not independent
regional new-game playthroughs. Shared software collateral proof and this
region’s native cold lab/party replay are reused; a separate regional software
collateral pair is not claimed. Publications are not unique animation FPS or
whole-game speed. Native cycle/frame-time percentile/DMA/cartridge counters
remain unavailable.

Private receipts: `IPGJ_STARTER_QUALIFICATION_V1.json` and
`IPGJ_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual archive and launcher
verification. Regional terrain remains unqualified.

### Pokemon SoulSilver (Korea) starter qualification

`soulsilver-ipgk-r0.json` authenticates IPGK revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 86,762,900 to 42,642,671 (50.8515%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.3142 | 43.8674 (3.0646×) |
| Renderer CPU, percent of one core | 161.85% | 110.35% |
| Measured light cycle | 3.4833 s | 3.4667 s |

Korean Chikorita, Cyndaquil and Totodile previews, both rotation directions,
inspect/cancel/confirm and final Chikorita choice were exercised. Clean
selection recording and independent framebuffer endpoint show intact localized
models/text and return to the lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Korean neutral lab and Chikorita follower.
Party shows male Chikorita at level 5 with 20/20 HP and localized
selection/exit text, without obvious visual corruption. The cold run leaves
the saved file unchanged and does not enter the starter scene.

Verified USA native pre-starter checkpoint imported through a disposable
Korean save-footer magic conversion (12 changed bytes, payload/CRCs
untouched); not independent Korean new-game progression.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPGK_STARTER_QUALIFICATION_V1.json` and
`IPGK_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (Germany) starter qualification

`heartgold-ipkd-r0.json` authenticates IPKD revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,225,014 to 43,101,630 (50.5857%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.2164 | 43.5805 (3.0655×) |
| Renderer CPU, percent of one core | 161.74% | 110.78% |
| Measured light cycle | 3.4667 s | 3.4667 s |

German HeartGold Endivie, Feurigel and Karnimani previews, both rotations,
inspect/cancel/confirm and final Endivie choice were exercised. Clean
recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the German HeartGold neutral lab and Endivie
follower. Party shows male Endivie at level 5 with 20/20 HP and intact
localized selection/exit text. The cold run leaves the saved file unchanged
and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported unchanged for
German target-scene compatibility/A-B; not independent German new-game
progression. Uses HeartGold approach/input route and game index 4.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPKD_STARTER_QUALIFICATION_V1.json` and
`IPKD_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (France) starter qualification

`heartgold-ipkf-r0.json` authenticates IPKF revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,223,806 to 43,100,688 (50.5861%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.1514 | 43.1606 (3.0499×) |
| Renderer CPU, percent of one core | 162.06% | 110.13% |
| Measured light cycle | 3.4667 s | 3.4667 s |

French HeartGold Germignon, Hericendre and Kaiminus previews, both rotation
directions, inspect/cancel/confirm and final Germignon choice were exercised.
Clean recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the French HeartGold neutral lab and Germignon
follower. Party shows male Germignon at level5 with20/20HP and intact
localized selection/exit text. The cold run leaves the saved file unchanged
and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported unchanged for
France target-scene compatibility/A-B; not independent regional new-game
progression. Uses HeartGold approach/input route and game index 4.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPKF_STARTER_QUALIFICATION_V1.json` and
`IPKF_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (Italy) starter qualification

`heartgold-ipki-r0.json` authenticates IPKI revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,220,281 to 43,097,605 (50.5876%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.1340 | 44.3702 (3.1393×) |
| Renderer CPU, percent of one core | 161.59% | 110.43% |
| Measured light cycle | 3.4833 s | 3.4667 s |

Italian HeartGold Chikorita, Cyndaquil and Totodile previews, both rotation
directions, inspect/cancel/confirm and final Chikorita choice were exercised.
Clean recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Italian HeartGold neutral lab and
Chikorita follower. Party shows male Chikorita at level5 with20/20HP and
intact localized selection/exit text. The cold run leaves the saved file
unchanged and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported unchanged for
Italy target-scene compatibility/A-B; not independent regional new-game
progression. Uses HeartGold approach/input route and game index 4.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPKI_STARTER_QUALIFICATION_V1.json` and
`IPKI_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (Spain) starter qualification

`heartgold-ipks-r0.json` authenticates IPKS revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,456,700 to 43,334,223 (50.4507%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.1091 | 44.4842 (3.1529×) |
| Renderer CPU, percent of one core | 162.11% | 110.61% |
| Measured light cycle | 3.4667 s | 3.4667 s |

Spanish HeartGold Chikorita, Cyndaquil and Totodile previews, both rotation
directions, inspect/cancel/confirm and final Chikorita choice were exercised.
Clean recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Spanish HeartGold neutral lab and
Chikorita follower. Party shows male Chikorita at level5 with20/20HP and
intact localized selection/exit text. The cold run leaves the saved file
unchanged and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported unchanged for
Spain target-scene compatibility/A-B; not independent regional new-game
progression. Uses HeartGold approach/input route and game index 4.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPKS_STARTER_QUALIFICATION_V1.json` and
`IPKS_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (Japan) starter qualification

`heartgold-ipkj-r0.json` authenticates IPKJ revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 87,455,193 to 43,333,303 (50.4509%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.3280 | 44.6189 (3.1141×) |
| Renderer CPU, percent of one core | 162.48% | 110.05% |
| Measured light cycle | 3.4833 s | 3.4667 s |

Japanese HeartGold Chikorita, Cyndaquil and Totodile previews, both rotation
directions, inspect/cancel/confirm and final Chikorita choice were exercised.
Clean recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Japanese HeartGold neutral lab and
Chikorita follower. Party shows male Chikorita at level5 with20/20HP and
intact localized name, selection and exit text. The cold run leaves the saved
file unchanged and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported unchanged for
Japan target-scene compatibility/A-B; not independent regional new-game
progression. Uses HeartGold approach/input route and game index 4.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

Private receipts: `IPKJ_STARTER_QUALIFICATION_V1.json` and
`IPKJ_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

### Pokemon HeartGold (Korea) starter qualification

`heartgold-ipkk-r0.json` authenticates IPKK revision 0 with its own
ROM/header/ARM9/overlay identities and expected bytes. Shared code/asset and
relocated CPU-contract evidence is reused. Its original/delivery/candidate
replay preserves all 3,600 screen pairs and the save. ARM9 instructions fall
from 86,975,841 to 42,848,968 (50.7346%) in frames 1800–3599.

| Native starter idle, one 30-second window per arm at 1 GHz | Original | Candidate |
| --- | ---: | ---: |
| Completed screen pairs/s | 14.1669 | 43.8340 (3.0941×) |
| Renderer CPU, percent of one core | 161.72% | 110.02% |
| Measured light cycle | 3.4833 s | 3.4833 s |

Korean HeartGold Chikorita, Cyndaquil and Totodile previews, both rotation
directions, inspect/cancel/confirm and final Chikorita choice were exercised.
Clean recording and independent framebuffer endpoint show intact localized
models/text and return to lab.

Normal Save, soft-reset Continue and fresh-process cold Continue/party passed.
Fresh-process Continue restores the Korean HeartGold neutral lab and Chikorita
follower. Party shows male Chikorita at level5 with20/20HP and intact
localized name, selection and exit text. The cold run leaves the saved file
unchanged and does not enter the starter scene.

Verified USA HeartGold native pre-starter checkpoint imported through a
disposable Korean save-footer conversion (12 changed bytes, payload/CRCs
untouched). Own HeartGold input/approach route; not independent Korean
new-game progression.

The measured light period remains within one captured frame of control.
Quality checks passed for both idle recordings and the game audio signal;
human listening approval is not claimed. Raw timing/RAM/audio differences
remain under the existing functional budget. Target checkpoints are imported
from USA, not independent regional new-game playthroughs. Shared software
collateral proof and this region’s native cold lab/party replay are reused; a
separate regional software collateral pair is not claimed. Publications are
not unique animation FPS or whole-game speed. Native cycle/frame-time
percentile/DMA/cartridge counters remain unavailable.

The converted fixture passes both unpatched reference and native cold-load
checks. The normal game-written save retains all four Korean footer markers
and valid payload CRCs; see `IPKK_NATIVE_SAVE_FOOTERS_V1.json`. The converter
is used only to prepare the disposable test fixture.

Private receipts: `IPKK_STARTER_QUALIFICATION_V1.json` and
`IPKK_STARTER_BEFORE_AFTER_V1.csv`. The default-disabled source manifest is
eligible for explicit private catalog inclusion only after separate actual
archive and launcher verification. Regional terrain remains unqualified.

The next three porting areas after the starter qualification are:

1. Relocate the HGSS terrain caller and its data/call dependencies; twelve
   regional expected-byte spans differ, so a base-address adjustment is insufficient.
2. Qualify the available Platinum revisions and regions against their own exact
   identities and reproducible scenes.
3. Audit FFTA2 renderer identity admission and qualify its regional workloads
   independently; this accepted optimization is renderer work, not the HGSS
   guest byte patch.

Missing or quarantined versions keep unchanged fallback. Broader game coverage
and unmeasured native counters must remain explicitly unqualified or unavailable.

### German SoulSilver terrain qualification, 2026-11-01

The accepted 48-byte terrain visibility gate now applies to owned IPGD revision 0
through `soulsilver-ipgd-r0.json`, alongside its unchanged qualified starter gate.
Both patches remain disabled in source and require explicit private catalog
selection. Removing the trial-only no-op delivery entry produces exactly the
same virtual cartridge bytes as the native candidate. Regional Beta4 R2 remains
immutable and contains only the regional starter port; this terrain addition
requires a new package and actual archive verification.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 instruction entries, frames 6000–9599 | 702,350,657 | 671,789,121 | −4.3513% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.7714 | 19.9476 | +6.2662% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 430 | 728 omitted |
| Added visibility queries in that window | 0 | 1,158 | 728 false, 430 true |

Native values are one verified 30-second window per separately cold-started arm,
not unique animation FPS, native CPU cycles, whole-game speed or a confidence
interval. The reference comparison includes original, unchanged decoded delivery
and cumulative candidate; native measurements compare original and cumulative
candidate only. No redundant native control or repeat was needed for this bounded
6.27% effect, consistent with the earlier USA result.

All 9,600 top-screen hashes, all 3,600 target-window screen pairs, the initial
1,800 home/boot screen pairs and the save match the decoded control. One bottom
hash differs at frame 3187 during menu brightening before the target window.
Stored thumbnails retain that event; its full-resolution framebuffer was not
saved. Raw RAM/timing differences and 305,257 differing same-index stereo samples
remain recorded. Sample lengths match; this is not an inaudibility claim.

The original compressed and cumulative decoded delivery routes already differ
in camera/input timing before the measured window. Keep that control difference
separate from the terrain patch. Native A/B therefore uses the same documented
own-title native plaza save and verified fixed tile/camera. The noon RTC is a
disposable test fixture only; no clock adjustment is part of the patch/package.
The imported save establishes regional compatibility and this test route, not
independent German new-game progression.

Native house entry, German Bag, return outdoors, normal Save, soft-reset Continue
and fresh-process cold field/Bag checks pass. The cold session preserves the new
save, and both banks' general/storage payload CRCs validate. Both captures have
zero added render/output drops and preserve game-audio packets and timestamps in
the review copies. Sampled views match the scene; transient thin diagonal lines
also occur in baseline captures. No frequency or human audiovisual approval is
claimed. The board returns to MENU with OBS stopped and settings preserved.

The shared dependency audit follows the existing visibility query through all
reachable direct callees: 281 instructions and 51 branch/call edges match across
all six SoulSilver regions, modulo authenticated targets and corresponding
BSS-relative state pointers. Expected replacement bytes and immutable transforms
are separately guarded. No scratch or native service is introduced. This shared
static evidence does not qualify the five still-disabled terrain candidates.

Private evidence: `IPGD_TERRAIN_QUALIFICATION_V1.json`,
`IPGD_TERRAIN_REFERENCE_FINDINGS_V1.json`,
`IPGD_TERRAIN_NATIVE_IDLE_MEASUREMENTS_V1.json`,
`IPGD_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json`, and
`IPGD_TERRAIN_COLD_VISUAL_REVIEW_V1.json`. Review videos are
`SoulSilver_German_Terrain_Original_V1.mp4` and
`SoulSilver_German_Terrain_Candidate_V1.mp4`.

Next: qualify the five remaining SoulSilver terrain regions; reuse the dependency
method for HeartGold; then port the owned Platinum and FFT A2 identities. Later
areas, battles and human listening remain outside this bounded qualification.

### French SoulSilver terrain qualification, 2026-11-01

`soulsilver-ipgf-r0.json` now includes the accepted 48-byte terrain visibility
gate alongside the unchanged French starter gate. Both remain disabled by
default. The two-patch release stream exactly matches the tested cumulative
native image, with the trial-only no-op entry removed. This addition is queued
for the next private package; immutable Regional Beta4 R2 remains starter-only
for this regional identity.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 instruction entries, frames 6000–9599 | 702,309,826 | 671,751,984 | −4.3510% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.7584 | 19.8049 | +5.5788% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 430 | 728 omitted |

The shared six-region dependency audit is reused: 281 reached instructions,
51 direct edges, authenticated calls, corresponding state-pointer offsets and
guarded immutable transforms. This region's reference and native runs remain
independent. No new detector, scratch memory, service or RTL change is needed.

All 9,600 top-screen hashes, all 3,600 target-window screen pairs, the initial
1,800 home/boot screen pairs and the save match cumulative decoded delivery.
One earlier bottom-screen frame differs during menu brightening at frame 3187.
Raw RAM/timing differences and 264,472 differing same-index stereo samples are
retained: equal sample lengths, maximum signed-16 delta 2,684 and RMS delta
20.5608. These figures do not establish inaudibility. Original compressed versus
decoded delivery has its own camera/input timing shift, recorded separately.

Native measurements use the same documented own-title plaza save, fixed tile
and camera, with one 30-second window per separately cold-started arm. Both
captures have zero added render/output drops; review copies preserve encoded
game-audio packets and timestamps. Publications are not unique animation FPS,
native CPU cycles or whole-game speed; no confidence interval is claimed.

House entry, the French Bag, return outdoors, normal Save, soft-reset Continue
and fresh-process cold field/Bag checks pass. The cold session preserves the
new save, and all four general/storage block payload CRCs validate. Both source
and candidate game audio are present. Sampled visual review is recorded without
claiming human listening approval. Imported checkpoints establish this route's
compatibility, not an independent regional new-game playthrough. The board is
back at MENU, all owned jobs are clear and OBS is stopped with settings preserved.

Private evidence: `IPGF_TERRAIN_QUALIFICATION_V1.json`,
`IPGF_TERRAIN_BEFORE_AFTER_V1.csv`, `IPGF_TERRAIN_REFERENCE_FINDINGS_V1.json`,
`IPGF_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json` and
`IPGF_TERRAIN_COLD_VISUAL_REVIEW_V1.json`. Review videos:
`SoulSilver_French_Terrain_Original_V1.mp4` and
`SoulSilver_French_Terrain_Candidate_V1.mp4`.

Next three porting areas: qualify the remaining Italian, Spanish, Japanese and
Korean SoulSilver terrain identities; transfer the dependency method to
HeartGold terrain; then qualify the owned Platinum and FFT A2 identities.

### Italian SoulSilver terrain qualification, 2026-11-01

The guarded 48-byte terrain gate in `soulsilver-ipgi-r0.json` is qualified under
the existing functional/perceptual budget, alongside its unchanged starter gate.
Both remain default-disabled and await explicit private catalog selection.
The exported two-patch stream exactly equals the tested cumulative native image.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 entries, frames 6000–9599 | 702,347,452 | 671,810,303 | −4.3479% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.8814 | 19.8948 | +5.3670% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 429 | 729 omitted |

Each native arm has one separately cold-started 30-second window at the same
saved tile/camera. These are publication rates, not unique animation FPS,
native cycle counts or whole-game speed. Renderer CPU was 161.56% versus
161.19% of one core; host CPU was 3.324% versus 3.294%. Both recordings have
zero added render/output drops and retain encoded game-audio packets/timestamps.

This port is **not framebuffer bit-exact**. Relative to cumulative decoded
delivery, 4,482 of 9,600 top hashes and eight bottom hashes differ. All 1,800
initial home/boot screen pairs match. In the 3,600-frame target window, 2,495
top hashes differ and all bottom hashes match. Early scene-transition differences
match the next control frame; one earlier menu-brightening frame remains unmatched.
During the target walk, 1,394 pairs remain unmatched even within eight control
frames. Sampled full-resolution views retain the town geometry, player and NPCs,
with animation-phase differences. Do not describe the whole difference as a
proven uniform frame shift. Other callers' draw/query counts also vary slightly.

Save bytes match the reference control. Raw RAM/timing drift and 5,928,601
differing same-index stereo samples remain recorded. Equal-length audio windows
after the transition show a roughly 750-sample offset, with residual differences
after alignment; this does not establish inaudibility. Temporal diagnostics
explain part of the divergence without changing any captured output or its hashes.

Native house entry, Italian Bag, return outdoors, normal Save, soft-reset Continue
and fresh-process cold field/Bag checks pass. The cold load preserves the new
save and all four general/storage payload CRCs validate. Sampled plaza frames
retain terrain and moving windmill poses. No human audiovisual approval or
independent regional new-game/battle coverage is claimed. The board returns to
MENU, all jobs clear, with OBS stopped and settings unchanged.

The existing six-region direct-flow and constant-guard proof is reused. The
new read-only timing diagnostic is generic and takes its scene windows from
data. Its results and thumbnails match the original retained-data calculation;
no gameplay replay was repeated to check the extracted tool.

Evidence: `IPGI_TERRAIN_QUALIFICATION_V1.json`,
`IPGI_TERRAIN_REFERENCE_REVIEW_V1.json`, `IPGI_TERRAIN_TIMING_DIAGNOSTIC_V1.json`,
`IPGI_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json`,
`IPGI_TERRAIN_COLD_VISUAL_REVIEW_V1.json` and `IPGI_TERRAIN_BEFORE_AFTER_V1.csv`.
Videos: `SoulSilver_Italian_Terrain_Original_V1.mp4` and
`SoulSilver_Italian_Terrain_Candidate_V1.mp4`.

Next three areas: Spanish/Japanese/Korean SoulSilver terrain qualification;
HeartGold terrain transfer; then the owned Platinum and FFT A2 identities.
Regional Beta4 R2 remains immutable and does not contain this terrain addition.

### Spanish SoulSilver terrain qualification, 2026-11-01

`soulsilver-ipgs-r0.json` now contains the guarded 48-byte terrain gate and the
unchanged qualified starter gate, both default-disabled. The exported two-patch
stream exactly matches the tested cumulative native image. A new separately
verified private package is required; Regional Beta4 R2 remains immutable.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 entries, frames 6000–9599 | 702,350,848 | 671,768,698 | −4.3543% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.6482 | 19.6805 | +5.5358% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 429 | 729 omitted |

All 9,600 top hashes, all 3,600 target screen pairs, the initial 1,800 home/boot
pairs and the save match cumulative decoded delivery. One earlier bottom hash
differs at frame 3188 during menu brightening, retained in thumbnails rather
than a full-resolution capture of that frame. Raw RAM/timing drift and 249,731
differing same-index stereo samples remain recorded; sample lengths match,
maximum signed-16 delta is 8,836 and RMS delta is 62.5006. No inaudibility or
full-run audiovisual equivalence is claimed. Original versus decoded delivery
has a separate camera/input timing shift. Other call counters retain their
observed window-boundary differences.

Native measurements use one 30-second window per separately cold-started arm
at the same documented own-title saved plaza position. Publications are not
unique animation FPS, native CPU cycles or whole-game speed. Host CPU was
3.424% versus 3.324% of one core; renderer CPU was 160.49% versus 161.77%.
Both recordings have zero added render/output drops, and review copies retain
encoded game-audio packets and timestamps.

Home entry, Spanish Bag, return outdoors, normal Save, soft-reset Continue and
fresh-process cold field/Bag checks pass. The cold session preserves the new
save, and all four general/storage payload CRCs validate. Sampled views retain
the scene and moving windmill poses. Imported checkpoints do not establish an
independent regional new-game playthrough; battles and human listening remain
outside this bounded qualification. MENU, stopped OBS, unchanged settings and
cleared owned jobs are verified at completion.

The six-region direct-flow/constant-guard proof is reused without rerunning
the qualified starter or earlier regional tests. Evidence:
`IPGS_TERRAIN_QUALIFICATION_V1.json`, `IPGS_TERRAIN_BEFORE_AFTER_V1.csv`,
`IPGS_TERRAIN_REFERENCE_REVIEW_V1.json`, `IPGS_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json`
and `IPGS_TERRAIN_COLD_VISUAL_REVIEW_V1.json`. Videos:
`SoulSilver_Spanish_Terrain_Original_V1.mp4` and
`SoulSilver_Spanish_Terrain_Candidate_V1.mp4`.

Next three areas: Japanese/Korean SoulSilver terrain qualification; HeartGold
terrain transfer; then owned Platinum and FFT A2 revision/region ports.

### Japanese SoulSilver terrain qualification, 2026-11-01

`soulsilver-ipgj-r0.json` adds the guarded 48-byte terrain visibility gate to
the unchanged qualified starter gate. Both source patches remain disabled by
default. The exported two-patch stream matches the tested cumulative native
image exactly; a separately verified private package is still required.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 entries, frames 6000–9599 | 703,823,938 | 672,998,062 | −4.3798% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.7531 | 19.5478 | +4.2378% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 430 | 728 omitted |

All 3,600 target screen pairs, the initial 1,800 home/boot pairs and save bytes
match cumulative decoded delivery. Two earlier top hashes differ at frames
2025/2031 during scene brightening; one bottom hash differs at 3187 during
menu brightening. None of these three pairs matches within eight neighboring
control frames. Retained thumbnails cover the differences; their individual
full-resolution frames were not captured. Seven full-resolution checkpoints
retain the home, town, player, NPCs, buildings, water and Japanese menus.
Other sampled draw/query counts are unchanged.

Raw RAM/timing differences and 199,211 differing same-index stereo samples
remain recorded. Both streams contain 7,702,322 stereo samples; maximum
signed-16 delta is 9,954 and RMS delta is 55.9352. No inaudibility, whole-run
bit-exactness or human audiovisual approval is claimed. The original versus
decoded delivery control separately changes camera/input timing. Native A/B
uses the same saved plaza anchor rather than relying on that input route.

One clean 30-second window per cold-started arm was measured at stock 1 GHz.
Publications are not unique animation FPS, native cycle counts or whole-game
speed; no confidence interval or native decoded-control window is claimed.
Host CPU was 3.325% versus 3.358% of one core; renderer CPU was 160.30% versus
161.54%. Review videos retain the game-audio packets and timestamps. Sampled
windmill poses change, while the fixed camera and town scene remain intact.

Home entry, Japanese Bag, return outdoors, normal Save, soft-reset Continue,
and fresh-process cold field/Bag checks pass. The cold launch preserves the
new save, and all four general/storage payload CRCs validate. The imported
own-title checkpoint does not establish independent Japanese new-game
progression. Battles, later areas and human listening remain outside this
bounded qualification. MENU, stopped OBS, preserved settings and clear owned
jobs are verified at completion.

The shared six-region dependency proof is reused: 281 reached instructions,
51 direct edges, exact non-branch bytes and guarded constants, with changed
globals at matching BSS-relative offsets. No new runtime service, scratch
memory, RTL change or repeated starter test is needed. Evidence:
`IPGJ_TERRAIN_QUALIFICATION_V1.json`, `IPGJ_TERRAIN_BEFORE_AFTER_V1.csv`,
`IPGJ_TERRAIN_REFERENCE_REVIEW_V1.json`, `IPGJ_TERRAIN_TIMING_DIAGNOSTIC_V2.json`,
`IPGJ_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json` and
`IPGJ_TERRAIN_COLD_VISUAL_REVIEW_V1.json`. Review videos:
`SoulSilver_Japanese_Terrain_Original_V1.mp4` and
`SoulSilver_Japanese_Terrain_Candidate_V1.mp4`.

Next three areas: Korean SoulSilver terrain qualification; HeartGold terrain
transfer; then owned Platinum and FFT A2 revision/region ports. Regional Beta4
R2 stays immutable and does not contain this new terrain addition.

### Korean SoulSilver terrain qualification, 2026-11-01

`soulsilver-ipgk-r0.json` retains the qualified starter gate and adds the guarded
48-byte terrain visibility gate. Both remain disabled by default. The exported
two-patch stream equals the tested cumulative native image; it is eligible for
a new separately verified private package. Regional Beta4 R2 stays immutable.

| Metric and scope | Original/control | Candidate | Change |
| --- | ---: | ---: | ---: |
| Reference ARM9 entries, frames 6000–9599 | 703,609,149 | 672,891,217 | −4.3658% |
| Native completed screen pairs/s, fixed plaza at 1 GHz | 18.7223 | 19.5991 | +4.6829% |
| Terrain draws, reference frames 6000–6599 | 1,158 | 430 | 728 omitted |

All 9,600 top hashes, all 3,600 target screen pairs, the initial 1,800 home/boot
pairs and save bytes match cumulative decoded delivery. One bottom hash differs
at frame 3187 during earlier menu brightening. Retained thumbnails cover that
transition; the individual full-resolution frame was not captured. Seven paired
full-resolution checkpoints preserve the expected home, town, player, NPCs,
buildings, water and Korean menus. Other sampled query/draw counts are unchanged.

Raw RAM/timing drift and 287,971 differing same-index stereo samples remain
recorded. Both audio streams contain 7,702,322 stereo samples; maximum signed-16
delta is 1,861 and RMS delta is 30.4018. This is not whole-run audiovisual
bit-exactness or a listening verdict. Original versus decoded delivery has its
own camera/input timing shift; native A/B uses the same fixed saved anchor.

The native measurement is one clean 30-second window per separately cold-started
arm at stock 1 GHz. Publications are not unique animation FPS, cycle counts or
whole-game speed; no confidence interval or native decoded-control window is
claimed. Host CPU was 3.359% versus 3.328% of one core; renderer CPU was 160.59%
versus 161.88%. Review copies preserve game-audio packets and timestamps.
Sampled views retain terrain and changing windmill poses.

Home entry, Korean Bag, return outdoors, normal Save, soft-reset Continue and
fresh-process cold field/Bag checks pass. The cold launch preserves the new
save. All four general/storage blocks have valid payload CRCs and Korean footer
magic `0x20070903`. MENU, stopped OBS, preserved settings and clear owned jobs
are verified at completion.

The private home/plaza fixtures are copies of documented own-title USA saves.
Only initialized footer markers were converted: two in the home fixture and
four in the plaza fixture. Payload bytes and CRCs were unchanged; erased banks
were preserved. Unpatched Korean reference and native cold scene admission
precede optimized testing. These fixtures are neither distributed nor a runtime
save converter, and do not establish independent regional new-game progression.
Battles, later areas and human audiovisual approval remain outside this scope.

Reuse the six-region direct-flow proof, constant guards and existing loader.
No new signature, runtime service, scratch memory, RTL change or repeated starter
test is needed. Evidence: `IPGK_TERRAIN_QUALIFICATION_V1.json`,
`IPGK_TERRAIN_BEFORE_AFTER_V1.csv`, `IPGK_TERRAIN_REFERENCE_REVIEW_V1.json`,
`IPGK_TERRAIN_NATIVE_VISUAL_REVIEW_V1.json`, `IPGK_TERRAIN_COLD_VISUAL_REVIEW_V1.json`
and `IPGK_TERRAIN_SEED_CONVERSIONS_V1.json`. Review videos:
`SoulSilver_Korean_Terrain_Original_V1.mp4` and
`SoulSilver_Korean_Terrain_Candidate_V1.mp4`.

All six owned non-USA SoulSilver revision-0 terrain identities are now qualified
for this bounded route. Package and verify their cumulative images before the
morning handoff. The next three porting areas are HeartGold terrain, Platinum
regions/revisions and FFT A2 regions/revisions. Unknown or unowned identities
remain unsupported.
