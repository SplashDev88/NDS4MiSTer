# Mario Kart DS in-memory optimization investigation

Status: private Course Beta 2 adds Yoshi Falls (15.70% native stationary
screen-publication gain) and retains the Figure-8 Circuit optimization (13.55%).
Both figures use pooled opening/closing controls and are scene-specific.
The beta remains experimental: raw reference timing, RAM, framebuffer and
audio differences require perceptual review. Earlier FIFO, ARM7 and OAM-only
trials remain disabled. No public release, FPGA, renderer, clock, save-state
format or HPS runtime service changed. The Scaler menu experiment is separate.

## Baseline and existing architecture

Released rc13 (`8cbbc353b112be6168a8aacc265fd076ce7f5fdb`) retains the accepted
rc12 improvements. Tools branch parent `4f8faad81e9c983b56bec8cef77d85e8d29de6ef`
adds only prior investigation tools/docs, with the same product runtime.
The FPGA executes ARM9/ARM7, memory, DMA and audio; HPS receives ordered H3D
shared-memory geometry packets and publishes screens. Released hardware does
not expose native PC profiling. Reference instruction samples are not cycles;
native screen publication rates are not unique gameplay FPS.

The existing `guest_byte_patch.py`/`VirtualRom` path prepares a temporary stream
and normal boot/overlay loading installs the bytes. No ROM file is modified.
The existing oracle, scanner, geometry/memory observers, comparison and native
rig are reused. Prior Mario Kart work optimized the renderer; there was no
accepted per-game byte patch.

## Inputs and scope

Owned USA AMCE revision 0, header SHA1
`a804fde97be47f0d7ac06bbf966d342b07daecbb`; ROM SHA256
`0ea8a91a0ae3e9db26337c25a6a8568f6737fa36c1e0761988c0fa0ecbf210ed`.
The original 262,144-byte save remains protected; tests use isolated copies.
ARM9 is compressed and copies a 32,672-byte section to ITCM at `01ff8000`.
Four compressed ARM9 overlays have additional flags and are not admitted by
blind address or the existing ordinary overlay adapter.

The qualified software Grand Prix route reaches Figure-8 Circuit, not Luigi
Circuit. Its clean opening is frames 2900–3299 within a 3,300-frame boot replay.
A second 3,300-frame Time Trials route removes racing AI from the comparison.
Earlier menu, steering/barrier attempts remain excluded from clean moving
benchmarks. These bounded scenes do not qualify other courses, multiplayer,
all regions, save/load, soft reset or full-game progression for a candidate.

## User-supplied decompilation

[ai-tdd-labs/mkds-decomp](https://github.com/ai-tdd-labs/mkds-decomp), pinned at
`c6e18fa4b346643b74c402b605a84b43cba16c01`, is a partial European matching
decompilation. Its README reports 551/7,693 functions and 2.1% of ARM9 code
bytes translated as of July 16, 2026; remaining code is carried as binary gaps.
We use its symbols, function boundaries and relocation relationships as leads,
without executing its setup/build scripts. The hot functions below do not yet
have C implementations in that snapshot. XorTroll/mkds-re supplies additional
SDK naming leads.

Owned EU/USA comparisons confirm exact complete bodies for the sampled audio
routine and `MIi_CpuSend32`. Material setup and DMA dispatch differ by three
and five bytes respectively, in their referenced data addresses. Their region
addresses must not be interchanged or treated as regional patch admission.
All current patch identity and original-byte guards are USA-specific.

## Profile and candidate

| Routine/lead | ARM9 instruction sample share | Finding |
| --- | ---: | --- |
| Audio processing `0212f3f8` | 5.69% | Signed stereo/history/saturation work; no safe removal established |
| `MIi_CpuSend32`, `0214d044` | 4.83% | Fixed geometry FIFO writes, not ordinary memcpy |
| Material setup `01ff8738` | 4.45% | Builds material results and submits state; existing cache paths warrant dependency analysis |
| OAM setup `020224e0` | 4.27% | Actual sprite preparation, not proven dead work |
| Large routine `01ffdee4` | 3.95% | Vector/triangle-style processing; semantics not fully established |
| Command queue `01ff9048` | 3.15% | Queue/CPU submission plus existing synchronization |

Two static redundant-shift matches have zero samples in the target race and
were not patched. The 60-frame geometry trace has 3,032–3,422 vertices and
1,119–1,270 polygons per frame. All 59 complete command intervals differ;
there is no evidence for whole-frame display-list reuse. Repeated lighting,
material and viewport values alone do not justify dropping their commands.

`mario-kart-amce-r0.json` lowers the existing CPU/DMA dispatch threshold at
ARM9 ITCM `01ff9154` from 256 to 128 bytes. The original compare and following
branch are guarded; there is no scratch, trampoline, new channel or service.
A qualified 400-frame census captures 2,396 eligible calls from one model-list
caller. Native usefulness and broad buffer-lifetime/lifecycle safety remain
gates, not assumptions.

The new explicit compressed-ITCM adapter reuses `MainCodeFile`/`VirtualRom`.
The identical-byte control is byte-identical, and selected output retains the
same stored extent, metadata and every undeclared decoded byte. Eighty-one new
and existing loader tests pass. Recompression time is a separate native
loading cost; a candidate that saves no useful gameplay time is rejected.

## Reference results

| Check | Unpatched | DMA 128 candidate |
| --- | --- | --- |
| Time Trials screen pairs | 3,300 | All 3,300 exact |
| Time Trials save | Original seed | Exact |
| Time Trials ARM9 instruction samples | 165,614 | 165,956 (+0.2065%) |
| Time Trials ARM7 instruction samples | 58,946 | 58,943 (-0.0051%) |
| Time Trials audio channel samples | 5,295,342 | 705,560 differ; max absolute 14,676, RMS 105.90 |
| Grand Prix ARM9 instruction samples | 294,815 | 292,098 (-0.9216%); changed AI trajectory, not matched-workload gain |
| Native speed | Baseline only | Unmeasured: preparation timed out before game start |

Raw RAM/audio/timing differences are retained. Exact screenshots do not prove
inaudibility. The patch is individually selectable for private testing and
remains disabled by default.

An identical virtual control initially diverged before racing because the
reference left initial hardware data registers indeterminate. Narrow DIV/SQRT
initialization fixed the first saved-context difference but not later entropy.
Zero-initializing the private NDS object storage before normal construction
resolved the control: direct and virtual runs now reproduce all six golden
outputs exactly across 3,300 frames. No product reset behavior changed.

## First-pass leads (subsequently investigated below)

1. Check whether static model display lists can use fewer vertex-command words
   without changing coordinates. Prove exact representability first; any
   quantization requires separate visual approval. This could reduce packet
   traffic as well as guest work.
2. Investigate the existing material-result cache for static track materials,
   including animation callbacks, shared material globals and invalidation.
3. Census the fixed-FIFO streaming routine's callers and ABI for a smaller
   branch/load loop while preserving every ordered geometry write.

Private evidence: `evidence/mario-kart-optimization-20261104` in the test
workspace, including source review, full identities, replay receipts, raw
comparisons and native records. ROMs, saves and extracted code remain private.

## Native outcome and exclusions

Both private delivery attempts failed before the game started. The initial
adapter recompressed twice; the revised adapter avoids the redundant pass
and reproduces the exact previously tested candidate stream, but still hits
the host's existing no-file-progress watchdog on HPS. Preserve both failures.
These are preparation failures, not observed game crashes or candidate
performance measurements. No watchdog limit, FPGA or host binary was changed.
The actual candidate was never qualified in native gameplay.

Native baseline runs confirm normal cold load, Time Trials selection, pause
and restart. The 12-second and six-second accelerating test setups reached the
first barrier and are excluded from a clean moving comparison. No native
before/after gain can be calculated from them, and no fixed-view candidate
pair completed. Extending lifecycle or regional validation is not justified
while delivery and benefit remain unqualified. Software audio/RAM differences
and buffer-lifetime questions also remain open.

The final device audit verifies the protected originals/settings and all 83
released runtime files. The released private baseline is restored for use.
One game patch manifest is recorded, individually selectable and disabled.
No source from the decompilation, ROM, save or extracted asset is included in
these source commits.

## Second pass: exact geometry and material-cache screening

The bounded packed-list detector parses 75 source spans that match at five
race checkpoints. Weighted by the existing 30,467-call census, these contain
1,341,786 VTX16 commands. None can use exact VTX10, preserved-axis or signed
10-bit-delta replacement. Existing shorter commands and redundant-state
elimination already cover the straightforward reductions. No coordinates
were rounded and no geometry was removed. The weighted totals are leads
derived from checkpoint snapshots, not a full lifetime/write-watch proof.

A qualified Time Trials memory observer captures 12,000 material computations
over 400 frames, with all six unchanged-replay artifacts identical to the
control. Every allocated material-result-cache pointer is null at the selection branch.
The apparent repeats of material indices 0 and 1 belong to different model
material pointers; each material occurs once per sampled draw. Enabling the
existing shared per-draw cache would not avoid these computations. A cache
across frames would require separate storage and dependency/invalidation
proof and was not added.

Evidence: `DISPLAY_LIST_CENSUS_V1.json`,
`REDUNDANT_COMMAND_CONDITIONAL_CENSUS_V1.json`,
`MATERIAL_CENSUS_SUMMARY_V2.json`. The reusable packed-list detector has five
synthetic parsing/state tests and agrees with all 75 observed source spans.

## Second pass: inline FIFO trial

`mario-kart-amce-r0-inline-fifo.json` replaces the seven-instruction tail at
ARM9 ITCM `01ff911c` within its original 28-byte extent. It writes the same
command and ordered parameter words directly instead of converting the count,
moving arguments and calling `MIi_CpuSend32`. It uses no scratch, new service,
DMA change or command removal. The adjacent literal pool is guarded.

The first variant used a post-indexed LDR; the recorded second variant retains
the original helper's LDM instruction class. Both variants have identical
screen, save and audio artifacts in the two reference routes below. Both were
deployed privately on MiSTer. The latest LDM variant completed the controlled
native comparison below, but did not meet the performance acceptance gate.

The full helper body is identical in owned USA/Europe code. Its new generic
scanner signature is a profiling lead; only USA is admitted by this manifest.
146 instruction-level cases preserve every FIFO store, empty sends,
callee-saved state, stack and ARM/Thumb returns. They save ten instructions
per nonempty call and six per empty call; they do not establish FPGA cycles.

| Matched decoded-delivery replay | Control | Inline FIFO |
| --- | ---: | ---: |
| Time Trials ARM9 instruction samples | 165,613 | 163,264 (-1.4184%) |
| Time Trials ARM7 instruction samples | 58,943 | 58,943 |
| GP ARM9 instruction samples | 293,436 | 288,976 (-1.5199%) |
| GP ARM7 instruction samples | 69,870 | 69,873 |
| Screen pairs | 3,300 per route | Every pair exact in both routes |
| Save | Original seed | Exact in both routes |

Raw RAM/audio differ. Time Trials changes 892,972 of 5,295,342 channel samples
(max absolute 9,695, RMS 252.48); GP changes 1,080,311 (max 21,113, RMS 845.65).
These are unaligned signed-16 comparisons, with no inaudibility verdict.

To avoid the previous HPS compression timeout, the existing `MainCodeFile` /
`VirtualRom` preparation now admits an explicit decoded boot relocation.
The complete output must equal the original decoded image plus selected
instructions and the cleared compressed-static-end word. Only documented
header offset/length, capacity/used-size and CRC metadata also change. It
requires no extra guest memory. The 84 loader tests pass. Both native control
and candidate cold-start and their staged bytes/header identities are verified.
Native preparation takes about 25 seconds in the observed candidate launch.

This delivery is not an identical-stream control: boot/menu screens and raw
audio/RAM differ from the original compressed boot. All 900 frames 2400–3299
of the Time Trials racing scene are exact, and its instruction count differs
by one sample. Candidate comparisons above use their matched decoded control.

Earlier LDR observations are not a trusted paired result. Three initial Time Trials
control windows average 21.1747 completed screen publications/second. Three
first-variant windows average 18.6150 after a GP/quit transition. Different
initialization histories prevent attributing that difference to the patch;
no native gain/regression percentage is assigned. Other automated routes
selected GP/VS or entered attract mode and are excluded. Navigation was also
inconsistent under the unpatched control; it is not a confirmed patch defect.
See `INLINE_NATIVE_RESULT_V1.json` and `INLINE_NATIVE_EXCLUSIONS_V1.json`.

### Latest LDM native control/candidate/control comparison

Short button edges and an image check after each menu transition reached the
same Time Trials/Mario/B Dasher/Figure-8 Circuit start-line view in three fresh
ROM/host/helper launches. The private route stops on an unexpected screen;
its templates reject all 90 wrong-menu pairings. No product input fix was
made and no underlying input defect is inferred. Every menu and post-window
scene check passed, with the driver stationary and all three mushrooms unused.
The staged original/candidate bytes, private save, stock FPGA/host/renderer
and 1 GHz CPU clock were checked. All launches share the same board boot;
these are fresh game launches, not physical power cycles.

Each row is the mean of three 20-second windows, with three seconds after
resuming before measurement. The controls use the same decoded delivery as
the candidate, with identical original/replacement instruction bytes.

| Fresh launch | Screen publications/second | Host CPU | Renderer CPU |
| --- | ---: | ---: | ---: |
| A: unchanged control | 20.9498 | 3.36% | 145.92% |
| B: inline LDM candidate | 21.1555 | 3.41% | 146.47% |
| C: unchanged control repeated | 21.2297 | 3.35% | 146.79% |

The candidate is 0.9820% above the first control but 0.3491% below the closing
control; the unchanged control means differ by 1.3357%. This does not establish
a causal speedup or regression. The initial apparent gain is smaller than
observed variation between control launches. Keep the patch disabled and do
not spend further lifecycle/regional validation on it without a new performance
lead. Evidence: `INLINE_NATIVE_RESULT_V2.json`, `FIFO2_A/B/C_*`,
`NATIVE_CHECKED_ROUTE_RECEIPT_V1.json` and `NATIVE_ROUTE_NEGATIVE_CHECK_V1.json`.

These counts are not unique animation/game FPS. Native frame-time percentiles,
dropped-game-frame results, moving-race speed, full lifecycle, other
courses/regions and audiovisual review remain unqualified. No video or beta
is presented as demonstrating a gain. The released rc13 baseline is restored;
`INLINE_FINAL_PROTECTED_AUDIT_V2.json` records the original-input/runtime audit.

## Next three ideas not implemented

1. Profile the game's course/object visibility tests and identify geometry
   submitted despite being provably outside the view. Any omission needs a
   conservative visibility proof across camera changes; no lower detail level.
2. Prove static-material dependencies across draws before considering an
   existing allocator/cache API. The per-draw cache alone does not help here.
3. Investigate exact arithmetic/loop improvements in the sampled audio
   processing routine. Do not remove filtering or assume CPU savings solve
   the native rendering bottleneck.

## ARM7 channel scan: no native benefit

The `audio-channel-inline-scan` candidate retains sixteen ordered slot reads
and active-channel callbacks, removing repeated lookup calls and bounds checks
in one loop. The 400-frame census records 68,160 lookups at this caller and
45,438 empty slots. It uses existing ARM7 autoload delivery, retains compressed
ARM9/header bytes and uses no scratch. 1,344 instruction-model cases cover slot
values, callback mutations, unaligned contexts and ARM/Thumb returns, preserving
reads, callback arguments and final registers.

| Comparison | Control | Candidate |
| --- | ---: | ---: |
| TT ARM7 instruction samples | 58,946 | 55,947 (-5.0877%) |
| GP ARM7 instruction samples | 68,969 | 63,688 (-7.6571%) |
| Native screen publications/s | 21.1887 | 21.1332 (-0.2620%) |

Each native variant has three scene-qualified twenty-second windows at 1 GHz
in the same stationary Time Trials view. No useful native gain was established;
the patch stays disabled. Racing screen pairs and saves match in both reference
routes. Boot frame 96 differs, as do RAM and raw audio (408 TT / 283 GP channel
samples, maximum difference 30). No inaudibility claim, lifecycle or regional
admission follows. Evidence: `CHANNEL_INLINE_ABI_V1.json`,
`CHANNEL_INLINE_REFERENCE_V1.json`, `CHANNEL_INLINE_NATIVE_RESULT_V1.json`.

The existing loader now preserves compressed ARM9 when selecting only ARM7
autoload patches. Explicit decoded-main-section delivery also reuses VirtualRom
without extra guest memory. Identity and original bytes remain mandatory; main
secure-area/settings overlaps fail closed. Ninety synthetic loader tests pass.

## Compact sprite transforms: no native benefit

A read-only census records 11,642 OAM-function calls and 25,642 coordinate
extractions over 400 TT frames. The routine copies OAM attributes, extracts
signed coordinates, applies affine/position transforms and updates attributes.
It is actual HUD work, not debug code. The same-extent `oam-compact-transform`
candidate replaces 916 bytes at ARM9 main 020224e0 with 680 bytes of equivalent
code and unreachable padding. It uses the existing stack and no new storage.

The authored implementation removes redundant shifts/spills and has an exact
identity-matrix path. 1,800 isolated cases preserve non-stack test RAM, callee-
saved registers, return count and ARM/Thumb returns. They cover valid sprite
shapes, size/flip/affine fields, full-range matrices/positions, doubled mode and
zero/clipped counts. Aggregate instructions in these cases fall 36.52%; these
are function tests, not game speed. No freed code space is assigned as scratch.

| Matched decoded-delivery check | Control | Compact V2 |
| --- | ---: | ---: |
| TT ARM9 samples | 165,613 | 161,654 (-2.3905%) |
| TT screen pairs | 3,300 | All exact |
| Native screen publications/s | 21.2532 | 21.2281 (-0.1181%) |

The native means each cover three scene-qualified 20-second stationary Time
Trials windows at 1 GHz. There is no useful gain, so the patch stays disabled.
The smaller coordinate-only trial (0.7868% fewer TT ARM9 samples) was superseded
without further native testing. GP differs in 884 screen pairs from frame 2165;
its lower counts are not a matched-workload result. Both saves match. Raw audio
differences remain: 490,482 TT and 1,224,133 GP channel samples, maximum 21,545 and
58,732 respectively. No perceptual or whole-game qualification is claimed.

The original released private baseline was restored after this trial. Evidence:
`OAM_COMPACT_ABI_V2.json`, `OAM_COMPACT_TT_REFERENCE_V2.json`,
`OAM_COMPACT_GP_REFERENCE_V2.json`, `OAM_COMPACT_NATIVE_RESULT_V1.json`,
`OAM_CLOSED_BASELINE_STATUS_V1.json`. Authored source and build artifacts are
`oam_compact_v2.c/.o/.bin` in private evidence; clang ARMv5TE ARM/O2, wrapping
signed arithmetic, no strict aliasing, freestanding. No public default changed.

## Conservative course visibility: private beta gain

The candidate precomputes independent primitive spans in the verified Figure-8
course model, then skips a whole span only when its bounds are strictly outside
one homogeneous clip plane. Rendered vertex coordinates are unchanged. Explicit
starting color/texture coordinates and a full first vertex preserve state across
skips; the final primitive is always sent to preserve outgoing state. The course
resource is prepared through VirtualRom and loaded into its normal game-owned
allocation. The original ROM is untouched. The model allocation grows 41,564
bytes; broader memory-pressure cases remain unqualified.

A matrix-prefix observer from reset confirms the helper's camera/projection
composition in all 17,928 Time Trials and 26,784 Grand Prix course calls, including
intro cameras. Guest RAM, screens, audio and save remain exact under that observer;
only the profile-counter start differs. The existing matrix-concat routine passes
500 arithmetic cases. The helper passes 2,113 matrix cases / 19,017 span tests,
including 11,653 conservatively rejected boxes and out-of-range fallbacks.

The 376-byte Thumb helper shares an existing 916-byte OAM function extent with
an equivalent smaller OAM implementation and multiplication stub. This is existing
code space, not a guessed zero-filled allocation. The OAM replacement passes
1,800 ABI/behavior cases. A static screen finds 170 external direct branch entries
at the original function start, with no interior branch or pointer candidates.
Full TT/GP RAM write watches see only boot writes in the helper, literal/table and
concat ranges, with all six replay outputs equal to their unobserved candidates.
The ITCM call changes via ordinary boot loading; the RAM observer does not cover
ITCM writes. Checkpoints and native cartridge guards retain the expected code.

The shared loader's explicit `append-decoded-arm9-gx-spans-v1` mode requires all
code components together. A missing component, wrong original bytes, wrong ROM,
resource/member identity or transformed-asset hash returns the complete original
stream. It uses the existing VirtualRom mechanism, with no new runtime service.
The refactored shared GX parser has 12 model tests; 96 loader tests and 21 pattern
tests pass. Authored generic C sources and a reproducible build recipe regenerate
the exact qualified 916-byte helper, SHA256
`72d659f4ee14a6b3c2a768f433ee153c893db38a259c4f1f4e53d817d14058dd`.

| Native fixed Time Trials view, 1 GHz | Mean screen publications/s |
| --- | ---: |
| Opening rc13 control, three 20-second windows | 21.1360 |
| Course-span candidate, three 20-second windows | 23.9488 |
| Closing rc13 control, three 20-second windows | 21.0467 |
| Gain versus pooled controls | **13.55%** |

All nine windows pass scene/camera checks. The gain is 13.31% versus the opening
control and 13.79% versus the closing control. It is a Figure-8 Circuit stationary
view result, not whole-game FPS or unique animation frames. Renderer CPU usage
is approximately 149.2% of one HPS core for the candidate versus 146.1–146.4%
for controls; host usage stays near 3.35%. No native CPU-cycle, p50/p95 frame-time
or dropped-game-frame claim is made.

The tradeoff is more guest CPU work. TT ARM9 samples rise from 165,613 to 272,908
(+64.79%); GP counts also rise but are not a matched-workload comparison. In a
60-frame prediction using captured reference matrices, course vertices fall from
146,760 to 85,108 and command bytes from 2,023,920 to 1,196,616; send calls rise
from 1,440 to 6,087. These are selection predictions, not native hardware counters.
The native result establishes that the reduced geometry load wins in this view.

Reference saves match in both 3,300-frame routes. TT has 744 differing screen
pairs from frame 2556; GP has 1,106 top and 1,103 bottom differences. Timing,
RAM and audio differ. Raw TT audio has 1,218,111 differing channel samples
(maximum 53,604); GP has 1,803,819 (maximum 65,145). These are not bit-exact or
inaudibility results. Native gameplay videos use identical bounded input sequences
but are not aligned frame-for-frame. Their separate capture-device audio packets
are retained unchanged, with verified exact decoded audio after presentation-only
crop/rotation. Both OBS captures report no added render lag or output skips.

The atomic-loader beta cold-loads normally, reaches Time Trials, responds to
acceleration/steering and restarts into the race. The first restart snapshot was
black during transition; a later snapshot confirms normal racing. The course-change path reaches
unmodified Yoshi Falls normally, exercising the original display-list fallback. Full race completion,
progress-save round trips, long sessions, all other modes/courses, multiplayer and
regional releases remain unqualified. Save states remain unsupported by rc13.
The per-game manifest stays disabled in the normal release; only the private beta
selects it. Human audiovisual approval has not been claimed.

Primary private evidence: `COURSE_MATRIX_FULL_VALIDATION_V1.json`,
`COURSE_CULL_HELPER_ABI_V1.json`, `COURSE_CULL_OAM_ABI_V1.json`,
`COURSE_CODE_EXTENT_AUDIT_V1.json`, `COURSE_CULL_WRITEWATCH_RESULT_V1.json`,
`COURSE_CULL_TT_REFERENCE_V1.json`, `COURSE_CULL_GP_REFERENCE_V1.json`,
`COURSE_CULL_NATIVE_RESULT_V1.json`, `COURSE_CULL_ADMITTED_STREAM_V1.json`,
`COURSE_BETA_VIDEO_V1_CAPTURE.json` and `MARIO_REVIEW_VIDEO_AUDIO_PRESERVATION_V1.json`.

## Other screened leads and next three opportunities

The remaining large ITCM hotspot `01ffdee4` reads the live course KCL collision
header: its area origins/masks/shifts match the owned course collision resource.
It is gameplay collision work, not unused debug code. The stereo filter prototype
has more hot-loop instructions than the original and was not deployed. Existing
material caches have no allocated result storage and no repeated material within
a sampled draw; a persistent cache needs storage and invalidation proof.

The original DMA-threshold candidate now passes decoded-delivery TT replay with
all 3,300 screen pairs/save exact, but ARM9 samples rise 0.20% and raw audio differs.
Its native retest is deferred while the proven culling candidate is qualified;
it is neither a measured gain nor an exhausted idea.

1. Extend conservative culling to other course models only after proving each
   model's transforms, attributes, allocation and camera lifetimes.
2. Batch adjacent retained spans to reduce guest send-call overhead. The current
   merged-run prototype needs 448 bytes, exceeding the 376-byte helper budget;
   no extra code space has been assumed or deployed.
3. Measure moving races with more opponents and investigate persistent material
   caching only where native profiles justify its storage/invalidation cost.


## Yoshi Falls extension and private Course Beta 2

The next qualified course is Yoshi Falls, NitroFS file 39 `bank_course.carc`,
member 0 `course_model.nsbmd`. All 11,265 observed draws across its 15 shapes
match the existing scale-64 camera/projection composition. The observer preserves
screens, RAM/state, audio, save and both PC profiles. The 916-byte shared guest
helper and ITCM call bytes are identical to Figure-8; no new runtime service,
code space, hardware or renderer changes are introduced.

The span transformer preserves primitive order, vertices and attributes in all
313 Yoshi Falls spans. Its normal model allocation grows by 48,176 bytes. Full
replay write watches observe 449 boot writes and no later writes in guarded RAM
code/table regions, and ten main/ITCM checkpoint guards retain their bytes.
The existing ITCM write-observer limitation still applies.

| Yoshi Falls fixed Time Trials view, 1 GHz | Mean screen publications/s |
| --- | ---: |
| Opening stock control, three 20-second windows | 16.9975 |
| Course-span candidate, three 20-second windows | 19.6984 |
| Closing stock control, three 20-second windows | 17.0547 |
| Gain versus pooled controls | **15.70%** |

All nine windows pass the scene checks. This is 15.89% versus the opening control
and 15.50% versus the closing control. Renderer usage is 155.0% of one HPS core
in the candidate versus 150.7% and 150.8% in controls. These rates
measure completed screen publications, not unique animation frames, native CPU
cycles or whole-game FPS. Moving-race speed is not quantified.

The 3,300-frame reference changes 748 top-screen and 477 bottom-screen hashes;
save bytes match. It changes 1,224,616 raw audio channel samples (maximum 58,330).
The extended 6,000-frame acceleration, steering and fence/waterfall-edge replay
also finishes with matching save bytes. Its screens/timing differ, and 5,556,934
of 9,627,900 raw audio channel samples differ (maximum 65,535). These are unaligned
raw comparisons and do not establish inaudibility. Selected image pairs show the
same scenery with slightly different timing/positions; full race completion,
new progression saves, multiplayer and long sessions remain unqualified.

Native clips use the same bounded acceleration/steering input sequence. Both
capture-quality checks pass with no added rendering lag or output skips. Their
presentation-only crop/rotation retains the exact decoded device audio; the clips
are not aligned frame-for-frame. Human audiovisual approval remains pending.

`mario-kart-amce-r0-two-course-spans.json` admits both resources through the
existing virtual-cartridge loader. The original Figure-8-only manifest remains
available. All components stay disabled in the normal release; the private beta
catalog selects the complete combined manifest. A failure in either resource
rolls back the entire stream and report. The 99 loader tests include second-asset
failure, duplicate/ambiguous selection, both FAT entries and source preservation.

The combined stream reproduces each individual candidate's screen, audio, save
and PC-profile outputs in both 3,300-frame replays. RAM differs because the live
FAT entries, cartridge used-size and header-CRC copies change: 19 bytes for
Figure-8 and 23 for Yoshi at both racing checkpoints inspected. Those fields
match the generated cartridge metadata. Yoshi also has 11 early-frame DTCM hash
differences; DTCM matches at the racing checkpoints. No RAM-bit-exact claim is made.

The archive census screens 59 main model resources, including missions, awards,
battle and unused content: 45 pass the span transform; 21 have one node and the
current scale. These are leads, not additional admissions. Unsupported state
commands or layout fail closed. Other revisions and regions remain unqualified.

Primary private evidence: `YOSHI_MATRIX_VALIDATION_V1.json`,
`YOSHI_WRITEWATCH_RESULT_V1.json`, `YOSHI_REFERENCE_RESULT_V1.json`,
`YOSHI_MOVING_RESULT_V1.json`, `YOSHI_NATIVE_RESULT_V1.json`,
`TWO_COURSE_REPLAY_EQUIVALENCE_V1.json`,
`TWO_COURSE_METADATA_RAM_VALIDATION_V1.json`, `GX_MULTI_ASSET_TESTS_V2.log`,
`YOSHI_BASE_VIDEO_V1_CAPTURE.json` and `YOSHI_CANDIDATE_VIDEO_V1_CAPTURE.json`.

Next three opportunities:

1. Qualify Cheep Cheep Beach's scale-64 model and camera lifetime, then measure it.
2. Test grouping adjacent retained spans to reduce guest submission overhead
   without assuming more code space or rounding rendered vertices.
3. Measure moving races with opponents and complete progression/save tests before
   broadening claims beyond the fixed views.
