# Mario Kart DS in-memory optimization investigation

Status: first investigation pass complete, with no accepted speedup. The DMA
threshold candidate remains disabled after native preparation failed before
game start; no candidate beta was promoted or release changed. The Scaler menu experiment
remains separate; no FPGA, renderer, clock, save-state format or HPS service
changes are part of this experiment.

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

## Next three leads

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
