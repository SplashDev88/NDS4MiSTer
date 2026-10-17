# Castlevania polygon setup experiment — 17 October 2026

This private ARM experiment reuses mathematically identical vertex calculations within a polygon. The candidate was rejected after two slower live cave runs; Beta8 remains the accepted build.

The path uses the existing exact Castlevania Dawn of Sorrow USA revision 0 profile. Equal adjacent Z/W inputs reuse final depth and normalized W. Native-resolution quads reuse viewport components only after proving that the two other corners contain the same X/Y inputs and that all four W inputs agree. Strips, other coordinate patterns and high-resolution viewport transforms retain their ordinary calculation. Separate template specializations keep the reuse checks out of other games' per-vertex loops. Geometry, timing bookkeeping, culling, pixel rendering, frame admission, FPGA and ARM clock are preserved.

## Native results

Six samples per build and scene, 2,000 geometry sets per sample, stock 1 GHz, one pinned CPU, frontend parked and restored. Complete named geometry fields match Beta8.

| Captured scene | Beta8 ms/set | Candidate ms/set | Change |
| --- | ---: | ---: | ---: |
| Cave/bat platform | 1.082315 | 0.935498 | −13.57% |
| Upper combat room | 0.996155 | 0.856830 | −13.99% |
| NSMB castle | 0.674798 | 0.673990 | −0.12% |
| NSMB castle left | 0.673555 | 0.674205 | +0.10% |
| Mario Kart heavy | 1.959893 | 1.962945 | +0.16% |

These measure polygon setup, not full replay or gameplay FPS. An earlier depth-only inline variant reduced Castlevania setup by about 6.5% but slowed controls by 2.9–4.6%, and was rejected.

## Correctness

612 geometry comparisons cover 8,192 synthetic inputs per normal variant and 50 captured geometry sets, profile enabled/disabled and ordinary-W high-resolution enabled/disabled. An independent integer oracle checks depth/W. Six further native-resolution comparisons cover 8,192 large-W boundary inputs each. The full ARM helper self-test passes.

The full self-test initially compared padding in the Vertex structure. A diagnostic found only its three padding bytes differed. The comparison now checks all named fields; negative tests verify that changes to each of 17 scalar fields are detected. Production discard behavior is unchanged.

An existing Beta8 limitation remains: the large-W high-resolution test failed baseline repeatability before the candidate ran. Original W equal to 2^24 truncates to zero and can leave high-resolution coordinates undefined after clipping. The new viewport reuse excludes high-resolution mode. Large-W high-resolution behavior is not claimed as qualified.

## Live decision

Two fresh isolated saves per build, in baseline/candidate/candidate/baseline order. Baseline rates were 19.37697 and 19.37928 completed publication pairs/s; candidate rates were 19.08912 and 18.99235. Means 19.37812 versus 19.04073 show a -1.741% loss. Median intervals were 51.762/51.233 ms for baseline and 52.585/52.511 ms for the candidate; p95 rose from 60.629/60.794 ms to 63.173/63.074 ms. All four cave captures were visually complete, with HP132 and EXP69 unchanged, stock 1 GHz, no protocol faults, no OBS dropped frames, an audio signal and unchanged protected files. These are short source-publication measurements, not distinct displayed animation FPS. Audio presence does not establish quality.

The final Beta8 control reproduced the first baseline. Remaining candidate combat and NSMB trials were cancelled after the repeated target-scene loss. The initial baseline combat and NSMB captures were normal, but supply no candidate comparison. No Beta9 was packaged and no runtime source was integrated. The exact mechanism for the difference between isolated setup and live throughput is not established.

Private evidence: `castlevania-viewport-reuse-performance-20261017`; no game data or captured media are included here.
