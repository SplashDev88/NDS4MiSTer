# RC13 regional ports

Regional work branches from the unpublished RC13 candidate, source
`2fb28bd437834cb76300d1fca5aa14dbf58cf711`. The packaged candidate and accepted
betas are preserved. German SoulSilver's starter gate is qualified for explicit
private catalog inclusion. Source manifests remain disabled by default.

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
code are included in this repository. French SoulSilver is next; remaining
regional candidates and German terrain remain unqualified.

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
