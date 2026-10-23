# NSMB native ARM9 PC profile — 23 October 2026

Observed on the MiSTer at 1 GHz, with both bookkeeping switches Off, using the owned US A2DE revision-0 cartridge (ARM9 CRC32 `d68a9af0`). No guest code was changed for these captures. This is diagnostic wall-time sampling, not instruction counts or a whole-game FPS benchmark.

## Capture provenance

* Diagnostic RBF SHA-256: `55cc7c93b81bd64440e51e514b01b3cfd9908c6626825864bc1e3489c46844fa`. Its static timing is not closed; restore the retained normal bitstream after profiling.
* Host: `f817d65ac2ef573b0e975c543f507e6ef4be80906ef2b587436eb7747fdf2d35`; renderer: `5b174c97a2dee7a10da6f3e9d0011ecd08a08760aef8849accbb902c15bee768`.
* The first Python polling attempts consumed about 23% of one HPS CPU and are not the primary evidence. The native C sampler buffers observations, then formats them after measurement.

| Scene | Seconds | Observations | Guest frame IDs observed | Missed samples, minimum | Collector CPU seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| W2-5 repeated jumping | 20.001 | 16,532 | 1,197 | 2,803 | 0.751 |
| W2-5 scrolling/jumping | 12.000 | 10,058 | 719 | 1,543 | 0.464 |
| W1 castle entrance, repeated jumping | 20.000 | 15,235 | 1,198 | 4,103 | 0.719 |

Native collector CPU use was about 3.8% of one core during sampling. Zero transport fault bits were observed. Loss is a modulo-256 lower bound; neither missing samples nor observer overhead is corrected away. Histograms retain every observed frame, raw R15, flags and sequence.

## Top 30 PCs: W2-5 repeated jumping

ARM addresses below use R15 minus 8 (Thumb minus 4). Synthetic tests calibrated WFI and stable LDM/STM wait states against the production CPU. At the first memory-request edge, R15 can briefly retain the preceding value, so this is not a precise retired-instruction trace. Raw values remain in the machine-readable captures.

| PC | Samples | Share | Symbol / mapping | State |
| --- | ---: | ---: | --- | --- |
| `0x02066fbc` | 3594 | 21.74% | `MI_Copy64B` | ordinary: 3594 |
| `0x01ffa6b0` | 2951 | 17.85% | `OS_Halt +0x4` | HALT: 2951 |
| `0x01ffa4e8` | 561 | 3.39% | `MIi_DmaSetParams +0x3c` | DMA hold: 559, ordinary: 2 |
| `0x0200b384` | 210 | 1.27% | `_ZN3OAM8fillDataEttP9GXOamAttrm +0x2c` | ordinary: 210 |
| `0x01ffdb80` | 126 | 0.76% | `MIi_DmaSetParams_wait +0x3c` | DMA hold: 126 |
| `0x02065cf8` | 96 | 0.58% | `DC_FlushRange +0x10` | ordinary: 96 |
| `0x020f442c` | 84 | 0.51% | `unmapped / ambiguous overlay` | ordinary: 84 |
| `0x02060930` | 58 | 0.35% | `Nitro::func_020608a0 +0x90` | ordinary: 58 |
| `0x020f4530` | 56 | 0.34% | `unmapped / ambiguous overlay` | ordinary: 56 |
| `0x02060934` | 53 | 0.32% | `Nitro::func_020608a0 +0x94` | ordinary: 53 |
| `0x020e6acc` | 47 | 0.28% | `unmapped / ambiguous overlay` | ordinary: 47 |
| `0x020e6b34` | 45 | 0.27% | `unmapped / ambiguous overlay` | ordinary: 45 |
| `0x02066ed0` | 37 | 0.22% | `MIi_CpuSend32 +0xc` | ordinary: 37 |
| `0x020f4528` | 36 | 0.22% | `unmapped / ambiguous overlay` | ordinary: 36 |
| `0x02021b20` | 33 | 0.20% | `_ZN8Particle13EmitterSystem18destroyAllEmittersEv +0x38` | ordinary: 33 |
| `0x01fffe9c` | 32 | 0.19% | `func_01fffe10 +0x8c` | ordinary: 32 |
| `0x020ae730` | 31 | 0.19% | `func_ov000_020ae700 +0x30` | ordinary: 31 |
| `0x02060954` | 30 | 0.18% | `Nitro::func_020608a0 +0xb4` | ordinary: 30 |
| `0x0200b388` | 29 | 0.18% | `_ZN3OAM8fillDataEttP9GXOamAttrm +0x30` | ordinary: 29 |
| `0x01fffe10` | 29 | 0.18% | `func_01fffe10` | ordinary: 29 |
| `0x02060968` | 28 | 0.17% | `Nitro::func_020608a0 +0xc8` | ordinary: 28 |
| `0x02060960` | 26 | 0.16% | `Nitro::func_020608a0 +0xc0` | ordinary: 26 |
| `0x02066e88` | 26 | 0.16% | `MIi_CpuCopy16 +0xc` | ordinary: 26 |
| `0x020f4434` | 25 | 0.15% | `unmapped / ambiguous overlay` | ordinary: 25 |
| `0x02060998` | 24 | 0.15% | `Nitro::func_020608a0 +0xf8` | ordinary: 24 |
| `0x020e3f2c` | 23 | 0.14% | `unmapped / ambiguous overlay` | ordinary: 23 |
| `0x020e3f88` | 21 | 0.13% | `unmapped / ambiguous overlay` | ordinary: 21 |
| `0x02066ecc` | 21 | 0.13% | `MIi_CpuSend32 +0x8` | ordinary: 21 |
| `0x0201dc44` | 21 | 0.13% | `func_0201dc04 +0x40` | ordinary: 21 |
| `0x0200a044` | 21 | 0.13% | `_ZN2FS5Cache8Internal7getFileEmPNS0_10CacheEntryEmbb +0x24` | ordinary: 21 |

Named mappings use explicit function extents from `NSMB-Decomp/nsmb` (`config/A2DE/arm9`) and names from the supplied `symbols9.x`. An unknown or overlapping overlay is deliberately left unresolved.

## Requested targets in these native windows

These are inclusive samples inside each function extent, excluding callees outside it. Zero means no samples in these windows, not proof that the function is never used.

| Target | Jump samples | Jump share | Scroll samples | Scroll share |
| --- | ---: | ---: | ---: | ---: |
| `OS_Halt` | 2951 | 17.850% | 2542 | 25.273% |
| `OSi_IdleThreadProc` | 0 | 0.000% | 0 | 0.000% |
| `NNS_G3dGeWaitSendDL` | 0 | 0.000% | 0 | 0.000% |
| `MI_WaitDma` | 3 | 0.018% | 2 | 0.020% |
| `FX_DivAsync` | 10 | 0.060% | 4 | 0.040% |
| `FX_GetDivResult` | 27 | 0.163% | 13 | 0.129% |
| `FX_SqrtAsync` | 0 | 0.000% | 0 | 0.000% |
| `FX_GetSqrtResult` | 0 | 0.000% | 0 | 0.000% |
| `NNS_G3dGeSendDL` | 1 | 0.006% | 5 | 0.050% |
| `MI_SendGXCommandAsync` | 2 | 0.012% | 10 | 0.099% |
| `MI_SendGXCommandAsyncFast` | 0 | 0.000% | 0 | 0.000% |
| `NNS_G3dGeBufferOP_N` | 35 | 0.212% | 37 | 0.368% |
| `NNS_G3dGeFlushBuffer` | 16 | 0.097% | 5 | 0.050% |
| `MTX_Concat43` | 102 | 0.617% | 74 | 0.736% |
| `MTX_Concat33` | 0 | 0.000% | 0 | 0.000% |
| `MTX_Concat44` | 0 | 0.000% | 0 | 0.000% |
| `MTX_MultVec43` | 0 | 0.000% | 1 | 0.010% |
| `MTX_Inverse43` | 23 | 0.139% | 4 | 0.040% |
| `FX_Sqrt` | 0 | 0.000% | 0 | 0.000% |
| `FX_Inv` | 0 | 0.000% | 0 | 0.000% |
| `FX_Div` | 4 | 0.024% | 1 | 0.010% |
| `FX_InvSqrt` | 0 | 0.000% | 0 | 0.000% |
| `VEC_Normalize` | 101 | 0.611% | 51 | 0.507% |
| `NNSi_G3dAnmCalcNsBca` | 10 | 0.060% | 9 | 0.089% |
| `NNSi_G3dAnmBlendJnt` | 32 | 0.194% | 18 | 0.179% |
| `DC_FlushAll` | 0 | 0.000% | 0 | 0.000% |
| `DC_StoreAll` | 0 | 0.000% | 0 | 0.000% |

## Interpretation and next priority

1. Investigate the clip-matrix readback round trip first. `MI_Copy64B` accounts for 21.74% of jump samples and 19.90% of scroll samples. Its long residence is consistent with waiting for data, not expensive arithmetic in the copy function. The inspected gameplay image has a caller at `0x020626a8` that copies the clip-matrix registers starting at `0x04000640`. Earlier native bus diagnostics independently identified that same readback address as a stall. This strongly points to synchronization/response latency; it does not justify substituting a stale matrix.
2. Keep HALT intact. HALT flags account for 17.85% / 25.27% of observations. The FPGA has already stopped instruction execution there while other devices run.
3. Keep real DMA completion semantics. DMA-hold flags account for 4.14% / 3.69%. The CPU is actually held; these are not necessarily busy-wait instructions that can be deleted.
4. Deprioritize instant math and native matrix-call HLE until the readback path is measured more closely. `MTX_Concat43` and `VEC_Normalize` each account for roughly 0.5–0.7% in these windows, and `FX_GetDivResult` about 0.13–0.16%. A register/memory round trip to HPS could cost more than the saved execution.
5. Do not treat reference instruction hotspots as hardware-time hotspots. `NNS_G3dGeWaitSendDL` represented about 4% of reference instruction samples, but had no samples in either native window. Requested cache-flush-all/store-all and sqrt routines also had none. Real cache maintenance remains necessary.

Current fast matrix-prefix replies, polling, ordered verification, DMA overlap and cache-generation rules already exist. The next experiment should measure request-to-reply latency and redundant invalidations while preserving ordered geometry, SWAP/VBlank behavior, pending DMA and all matrix values. Removing Wi-Fi-labelled bookkeeping did not establish a native speed gain.

## Castle cross-check

A separate 20-second capture at the W1 castle entrance again placed the same
clip-matrix copy first among non-halted PCs: `MI_Copy64B` was 14.51% of samples.
`OS_Halt` was 37.30%, and DMA-held observations were 2.86%. The collector used
0.719 CPU seconds, with no observed transport fault bits. This supports the
readback investigation across a second location, while showing that the
relative costs vary by scene. It is a short entrance-room sample, not coverage
of the full castle or its boss.
