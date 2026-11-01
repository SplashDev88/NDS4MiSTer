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

All six owned non-USA SoulSilver revision-0 starter ports and German/French
HeartGold IPKD/IPKF revision 0 are qualified within the bounded scope below. The remaining
HeartGold starter regions are next; regional terrain and other-game ports remain
pending. No unowned revision or quarantined identity is admitted by these results.

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
