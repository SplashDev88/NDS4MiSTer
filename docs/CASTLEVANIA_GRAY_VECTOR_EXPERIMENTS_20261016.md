# Castlevania gray-vector experiments — no promotion

Two ARM renderer prototypes were compared against Castlevania Beta8 using the same saved cave, combat, NSMB castle and Mario Kart frames. Neither met the predeclared 1% native target improvement threshold; neither was built into a service or installed on the MiSTer. Public runtime source remains unchanged.

| Prototype | Cave CPU time | Combat CPU time | NSMB castle | NSMB left | Mario Kart |
| --- | ---: | ---: | ---: | ---: | ---: |
| Four-lane NEON gray blend | +0.364% | -0.157% | +0.906% | +0.899% | -0.403% |
| Prepare row shades before four-lane blend | -0.522% | -0.795% | +0.490% | +0.429% | -0.593% |

Negative values indicate less CPU time. Each result is the median of six stock-1-GHz samples per build, collected in baseline/candidate/candidate/baseline order. Complete color/depth/attribute hashes matched between the benchmark builds. These isolated saved-frame measurements do not establish live gameplay speed or animation FPS.

The four-lane blend retained the scalar path for depth ties, failed depth tests, antialiased edges, repeated translucent IDs and tails. Independent tests checked 12,713,984 blend lanes and 524,288 attribute lanes. The complete isolated renderer matched 5,900 full-buffer cases, including 5,644 independent uncached-reference cases; 48 sequential snapshots and 160 serial, split, queued and delayed-worker frames also matched Beta8.

The row-shading refinement retained the exact existing interpolation recurrence and moved its computation before pixel plotting to reduce register pressure. All 512 targeted full-buffer gray cases matched Beta8 and the uncached reference. Broader qualification and live trials were not run after its native performance result failed the improvement threshold.

The failed packet-buffer candidate is documented separately in [Packet-buffer reuse](CASTLEVANIA_PACKET_REUSE_PERFORMANCE_20261016.md). The best accepted package remains Castlevania Beta8; 60 fps has not been achieved.
