# Strange Journey exploration investigation

Status: word-stream and checked-index candidates both rejected for no repeatable native benefit. Early Antlia walking/turning route, profiling and reusable save are qualified; released baseline restored. No new optimization accepted or beta promoted.

The user prioritized dungeon exploration on 2026-11-02 after a report that the intro movie now works but gameplay remains uneven. The baseline is released rc13, revision `8cbbc353b112be6168a8aacc265fd076ce7f5fdb`, retaining accepted rc12-derived improvements. The separate Scaler menu experiment is parked. The FPGA, host, renderer and clocks are unchanged.

## Existing mechanisms

`tools/standalone_host/fmv/prepare.py` reconstructs a temporary cartridge stream; `guest_byte_patch.py` supplies guarded main/overlay/ARM7 byte patches for admitted layouts. Normal game code and overlay loading make these bytes executable. This is not an address-only live-memory hook. The disposable worker exits before gameplay. ROM files remain unchanged.

The existing `SJ` movie profile already admits this exact USA ROM and reconstructs its compressed ARM9 image, retaining movie conversion and queue handling. The generic guest-byte adapter does not admit this compressed main image. A private candidate profile now reuses this exact reconstruction, retaining every movie, stub, prior code patch and layout extent. Only the guarded 40-byte word-stream span differs. The reconstructed image was independently regenerated and hashed. This is preparation, not native qualification.

The FPGA owns guest ARM9/ARM7 execution, memory, DMA, sound and timing. HPS consumes ordered graphics packets from the H3D shared-memory mailbox and publishes complete screen pairs. No new per-call HPS service or RTL change is authorized.

Use the existing software replay oracle, structural pattern scanner, instruction-block comparator, native rig and capture tools. Software ARM9/ARM7 instruction samples are not FPGA cycles. The released core does not expose the optional native ARM9 PC tags; there is no native ARM7 profiler. Native frame publication rates alone are not gameplay FPS.

## Inputs and baseline coverage

Owned USA `BMTE` revision 0, header SHA1 `029a372ec97d02fca4ab8cbc6529c8aca89112cf`; ROM SHA256 `f4709745c10fca7024bd34dec4c0c6251a29088037aad596c8d52b63409a49ab`. Both ARM9 overlays are compressed and share a load address; any overlay patch must retain ID and content identity.

The existing production save offered New Game only. Normal progression through the opening, two rescue fights, the M3 briefing and field-controls tutorial produced an isolated exploration seed. It was saved through the game's menu, read twice identically, retained across clean exit, and cold-loaded in software and on MiSTer. SHA256: `22cdc9e97d7f680450fcd3c81263426c341d11a2cb29e916288b8ae92d8cf7a9`. The original save remains unchanged. The private native kit has 83 verified runtime files.

`ANTLIA_EXPLORATION_CONTROL_V3` is the qualified 9,000-frame reference: cold load, enter Antlia, then repeated one-tile walking and reversible turns between frames 6200 and 8999. Screenshots confirm actual dungeon views and map heading/position changes. Earlier routes that reached Talk, a tutorial, or the entry confirmation are retained as failed setup coverage, not benchmarks. The software route and native real-time input sequence are separate fixtures; do not equate their frame boundaries.

The shipped packed movie stream is not a valid audiovisual golden input for the ordinary software oracle: movie decoding is handled by Hybrid3DService, which that oracle does not instantiate. Preserve this failed harness attempt. The exact release prepared image successfully cold-loads the saved command-room scene in the oracle; use that path for saved-game comparisons and retain native FMV regression coverage. Do not report the oracle's encoded scanlines as a release bug.

## Candidate ledger

| Candidate | Evidence | Status | Native gain |
| --- | --- | --- | --- |
| Word-stream branch collapse at ARM9 `020086e4` | 1,024 synthetic cases; guarded census of 10,668 paired calls, all to geometry FIFO; exact screens and save on walking route | Rejected and disabled | No repeatable benefit established |
| Repeated table search at `02011810`, caller `02099dcc` | About 5.2% of ARM9 samples in the containing block; 100 calls/frame in captured windows | Investigate a checked shortcut with original-search fallback; no patch | Unmeasured |
| Range-mask generation near `02057f80` | Eight calls/frame in idle census; 64-byte loop repeatedly reads two bounds | Runtime bounds/alias census; no patch | Unmeasured |
| Sample-processing loop near `0207bf00` / `0207c000` | About 8.8% of ARM9 instruction samples in the two blocks | Nibble/coefficient/history shape; exact semantics not established | Unmeasured |
| Halfword copy at ARM9 `0200866c` | Static detector match, absent from idle dungeon sample | Deprioritized | Unmeasured |

The word-stream candidate reduces branch scaffolding while retaining every source load and fixed-destination store. Synthetic instruction-count reductions are not native speed measurements and do not establish MMIO/IRQ/DMA timing equivalence. There is no scratch allocation or new offload.

## Preliminary off-route validation

The exact released prepared image cold-loads the command-room seed successfully. A repeat of this baseline reproduces `frames.csv`, `state.csv`, audio, save and both instruction profiles exactly across 4,800 frames (`COMMAND_ROOM_REPEAT_COMPARISON_V1.json`).

With the disabled word-stream candidate, both screen hashes match on every frame and the final save matches. Audio has equal length; 70 of 7,702,318 channel samples differ, with maximum absolute difference 34 on the signed 16-bit scale. RAM differences remain after normalizing patched code. At the four stored checkpoints, DTCM, ARM7 WRAM and shared WRAM match; main RAM contains the expected eight changed code words, one persistent unclassified word at `0239df94`, and two additional changed words at `0215f044` / `0215f054` at frame 1200 only. Other frames have transient DTCM/ARM7 differences. These are reproducible candidate effects, not accepted benign differences. See `WORD_STREAM_OFFROUTE_COMPARISON_V1.json` and `WORD_STREAM_CHECKPOINT_DIFFS_V1.json`.

Static direct callers load destination `04000400` (geometry FIFO). The idle census now authenticates all 10,668 entry/exit pairs with full loaded-code bytes, register arguments and source advancement; all destinations are `04000400`. Instrumentation reproduces the reference frame/state/audio/save/profile files exactly. The existing transfer-call auditor passes (`ANTLIA_WORD_CENSUS_AUDIT_V1.json`). No stores are removed by this candidate; the census does not prove MMIO timing equivalence.

The walking candidate preserves both screen hashes on all 9,000 frames and final save bytes. The 2,800-frame target window executes 501,439,673 versus 496,818,437 ARM9 instructions: **0.9216% fewer** in the software reference. ARM7 instruction work changes by +0.0035%. These are not native cycle or speed gains. Audio has equal length: 70 of 14,441,852 channel samples differ, maximum delta 34; all differing indices precede the target window. Main RAM/DTCM differences remain at target checkpoints; none are silently excluded. All stored ITCM, ARM7 WRAM and shared-WRAM checkpoints match. See `ANTLIA_EXPLORATION_WORD_STREAM_COMPARISON_V1.json` and `ANTLIA_EXPLORATION_CHECKPOINT_DIFFS_V1.json`.

The independent 9,600-frame idle-dungeon trial also has exact screens/save and the same 70 differing audio samples. The earlier command-room baseline repeat is bit-exact. Small waveform differences therefore remain candidate effects, not a claim of harness noise or inaudibility.

The repeated-search payload census covers four target frames, 400 calls. Each frame asks for keys 111 through 210. The 100 records have 16-byte stride and consecutive keys; all 400 captured 1,600-byte tables are identical. The comparator at `02099890` subtracts two unsigned 16-bit keys. This is stronger than pointer recurrence, but does not establish table uniqueness/immutability throughout the game. Do not replace the shared search blindly: other callers, sparse/duplicate keys, missing keys and callback effects need preserving. Receipts: `ANTLIA_SEARCH_PAYLOAD_SUMMARY_V1.json`, `ANTLIA_SEARCH_PAYLOAD_CENSUS_COMPARISON_V1.json`.

The range-mask census covers the complete target window and preserves the unchanged replay outputs. All 22,401 entry/exit pairs use index 1 and bounds 40..49, with exact 48-byte loaded-code context and disjoint bound/output addresses. Of these calls, 116 cross an adjacent frame boundary. Pairing confirms unchanged endpoint bounds, not the absence of temporary intervening writes. `ANTLIA_MASK_CENSUS_SUMMARY_V1.json` retains that distinction; no mask patch has been prepared.

The existing geometry observer also reproduces the full unchanged replay. During frames 6200..6259 it records 214,468 command-parameter packets, 91,194 attributed to DMA, and 60 geometry frames. Median/max counts are 493/575 vertices and 178/216 polygons. All 59 complete swap intervals have different command payloads: whole-frame reuse is not established. Repeated state assignments are present, but recurrence alone does not justify deleting commands or geometry. `ANTLIA_GEOMETRY_SUMMARY_V1.json` preserves the complete distributions and attribution limits.

## Native decision and remaining gates

The predeclared A-B-B-A sequence is complete. Baseline publication rates were 24.7962 and 24.1450/s; candidate rates were 24.6937 and 24.7681/s. Pooled rates are 24.4706 versus 24.7309/s (+1.0636%). The first pair regresses, and the pooled change lies within baseline variation; this does not establish a repeatable useful gain. Keep the patch disabled. All four OBS recordings pass capture-quality checks and retain the same input sequence, seed, output settings, 1 GHz clock and stock core/host/renderer. Mean renderer CPU use was approximately 152.8% versus 153.6% (one core = 100%). This indicates substantial renderer work but is not a causal bottleneck proof.

Publication counts are screen-buffer updates, not whole-game FPS. No native frame-time percentiles, dropped-game-frame counts or ARM9/ARM7 cycle shares are available from these trials. Both private saves retain the original exploration-seed hash. The unpatched rc13 baseline is restored at Antlia. Receipts: `NATIVE_WORD_STREAM_REPEAT_PLAN_V1.json`, `NATIVE_WORD_STREAM_AB_COMPARISON_V1.json`.

The rejected candidate did not proceed to full native movie, new save/reload, soft-reset, overlay-transition or save-state qualification. This saves testing effort without implying those checks passed. Future retained candidates still need appropriate lifecycle coverage; the ordinary software oracle cannot validate the shipped movie decoder. No beta distribution or release is authorized here.

Private evidence: `evidence/strange-journey-optimization-20261102` in the test workspace. ROMs, saves, snapshots and captures are private and excluded from release artifacts.

## Pattern-library and tooling changes

The existing scanner now recognizes the exact fixed-destination word-stream shape with register renaming. Three tests cover the positive shapes and rejection of changed branch targets, flags, memory-access behavior and control-register aliases. The full owned-ROM rescan retains all seven prior matches and adds only `020086e4`. The pattern library records this title's compressed-main delivery and off-route limitations; `KNOWN_ISSUES.md` retains movie-harness and RAM/audio caveats.

## Before/after status

| Metric | Released baseline | Disabled candidate |
| --- | --- | --- |
| Walking-route screen pairs | 9,000 | All 9,000 exact |
| Final save | Reference | Exact |
| Target ARM9 instructions | 501,439,673 | 496,818,437 (-0.9216%) |
| Audio | 14,441,852 channel samples | 70 differ before target; max delta 34 |
| RAM | Reference | Differences retained; roles unresolved |
| Native publications/s, trial 1 | 24.7962 | 24.6937 |
| Native publications/s, trial 2 | 24.1450 | 24.7681 |
| Pooled native publications/s | 24.4706 | 24.7309; +1.0636% within observed baseline variation |

## Next three leads

1. Establish native rendering cost and examine redundant or occluded geometry work. The existing geometry trace rejects whole-frame reuse; recurrence alone does not justify removing draws.
2. Hoist repeated range-mask bounds only after checking aliases and concurrent mutation. Retain clearing and negative-index paths.
3. Identify the sample-processing loop's input/history contract and investigate exact arithmetic reuse, without reducing audio quality or adding an HPS service.

## Checked-index lookup investigation

A second private candidate redirects only the ARM-mode main-code call at
`02099dcc` from `02011810` to a 240-byte guest routine at `01fffc00`. It checks
an indexed candidate and its neighbors, with the original search as fallback.
No persistent cache, scratch buffer, HPS service or RTL change is involved.
The full ROM/header/revision guard, original branch bytes, placement bytes and
replacement routine are in `strange-journey-bmte-r0-checked-index.json`.

The slot belongs to the existing released FMV autoload reservation; it is not
an assumed free RAM address. The unchanged full-replay ITCM observer reproduces
all six reference outputs. It sees 64 zero-word initialization stores to the
256-byte surveyed slot at frame 0, with no later interpreter writes. The
1,600-byte table is written only at frame 38. The complete target census sees
281,400 calls with the same table, count and stride. These are bounded route
proofs, not claims about every scene or host/state-loading write path.

The routine retains the original 40-byte stack layout, return registers and
flags. A 998-case differential suite compares all modeled memory, stack residue,
R0–R12/SP/LR/PC and CPSR, including sparse and duplicate sorted tables, missing
keys, empty/null inputs and guarded fallback cases. The shortcut never assumes
that a failed indexed lookup means the key is absent. Sortedness remains the
original search's required contract; no unsorted or concurrent-mutating-table
claim is made. See `SEARCH_HOOK_SYNTHETIC_V1.json` and
`SEARCH_HOOK_RESERVATION_AUDIT_V1.json`.

The completed 9,000-frame candidate route reduces target ARM9 instructions
from 501,439,673 to 482,752,309 (3.726742%). ARM7 instructions change from
34,158,270 to 34,161,012 (+0.008027%). All 14,441,852 audio channel samples and
final save bytes match exactly. At 12,100 guarded target entries/returns, the
expected pointer, key, restored registers, LR and flags match the contract.
The candidate reservation is still written only at boot; the table only at
frame 38.

This is not a bit-exact full-game patch: 3,798 frame pairs differ, starting at
frame 5202. Captured top-screen differences are confined to HUD rows 2–17;
reviewed dungeon geometry and map-player marker masks match. The animated map
background also differs. Main-RAM/DTCM/ARM7 checkpoint differences are retained
without assuming that every word is benign; before dungeon entry, checkpoints
2400, 4200 and 4800 match after excluding only the declared code bytes. ITCM
outside the declared routine and shared WRAM match at all checkpoints.
`SEARCH_REPLAY_COMPARISON_V1.json`, `SEARCH_TOP_DIFF_BOUNDS_V1.json` and the
contact images retain the raw observations. Visual spot checks do not prove
all-frame visual equivalence or long-play safety.

The first candidate recording reached frame 8999, then failed its recorder's
mandatory-site check because the fallback site was never observed. That output
is retained as incomplete. The repeat removes only that mandatory watch and
finishes normally; the patch and input route are unchanged.

The native A-B-B-A comparison rejects the candidate. Baseline trials are
24.7721 and 24.0924 publications/s; candidate trials are 24.0670 and 24.9175/s.
Pooled rates are 24.4326 versus 24.4940/s (+0.2513%), within the 2.8212% baseline
spread. The first pair regresses and ranges overlap. The reference instruction
saving therefore has no established useful native benefit. Mean renderer CPU
use remains approximately 153% for both; this is not a causal bottleneck proof.

| Checked-index metric | Released baseline | Disabled candidate |
| --- | --- | --- |
| Target ARM9 instructions | 501,439,673 | 482,752,309 (-3.726742%) |
| Audio channel samples | 14,441,852 | All exact |
| Final save | Reference | Exact |
| Frame pairs | 9,000 | 3,798 differ; HUD/map differences retained |
| Native publications/s, first trial | 24.7721 | 24.0670 |
| Native publications/s, second trial | 24.0924 | 24.9175 |
| Pooled native publications/s | 24.4326 | 24.4940 (+0.2513%; within variation) |

The second candidate recording has two OBS render skips. Its separate MiSTer
counter measurement is retained, but that recording is not visual-equivalence
evidence. The other three recordings pass capture-quality checks. Sampled
native videos show the expected walk/turn route, and before/after screenshots
return to the same entrance tile and heading; this does not claim full native
video/audio equivalence. The untouched private seed survives both cold loads
and the candidate exit. Full patched movie/new-save/reset/broader-overlay
qualification stops at this rejection. No new beta or release is promoted.

The released baseline is restored at Antlia. All 11 protected original
settings/firmware/save files pass the final frozen-content audit. The original
ROM was accessed through read-only aliases. Full results:
`NATIVE_SEARCH_AB_COMPARISON_V1.json`, `FINAL_PROTECTED_FILES_AUDIT_V2.json`.
Tooling commit `44b17c3` adds optional ITCM tracing to the existing replay
builder; the observer changes no emulated reads or timing counters.
