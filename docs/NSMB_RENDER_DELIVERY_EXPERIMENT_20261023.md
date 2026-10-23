# NSMB renderer delivery experiments

These ARM-side candidates are independently opt-in and add no FPGA logic:

| Environment flag | Change | Default |
| --- | --- | --- |
| `NDS4MISTER_STANDALONE_QUERY_SHORT_IDLE` | Sleep 25 rather than 100 microseconds after an empty intake, only with fast polling and established fast matrix replies on `/dev/mem`. Publication waits retain their delay. | Off |
| `NDS4MISTER_PARALLEL_FINAL_PASS` | Split final image processing between the existing raster workers after raster completion. Edge-marking boundary rows run after joining. Requires threaded full-frame completion. | Off |
| `NDS_GPU_AFFINE_PACKED_ROWS` | Process complete eight-pixel affine tile rows from a packed load, preserving palette/window/transparency rules and scalar boundary handling. No persistent pixel cache. | Off |
| `NDS4MISTER_PARALLEL_CLEAR` | Overlap clear and polygon setup. Included for experimental comparison; disabled in all current native comparisons. | Off |

## Correctness and provenance

- Synthetic parallel-phase oracle: 2,640 full color/depth/attribute buffer
  comparisons, 864 transitions, 192 queued cases, 144 X-partition cases,
  six cancellation cases, three secondary-first cases and three shutdowns.
  Passed with the ARM binary under emulation. The earlier native oracle
  attempt exceeded its harness deadline and is not counted as a pass.
- Service self-tests passed with the final phase disabled and enabled.
- Packed affine rows: 16,384 exact comparisons, 12,940 eligible fast-path
  cases and 8,634 cases that changed the output. Frozen NSMB renderer fixtures
  also remained identical.
- The common helper self-test passed. Its SHA-256 is
  `7a9962fb8bcde14c905e5fc34649e4d18a40f5856ac4abc059ed6d92394b339a`.
  All 977 recorded source/build inputs under `src`, `third_party`, CMakeLists
  and the ARM toolchain match this checkout. The host is built separately.
- Retained helper for controls:
  `5b174c97a2dee7a10da6f3e9d0011ecd08a08760aef8849accbb902c15bee768`.

The phase fixtures are in `tools/parallel_phase_tests`; the affine oracle is
`tools/test_affine_packed_rows.cpp`. Neither fixture contains game assets.
The helper uses the existing Release ARM hard-float toolchain, `-O3`, LTO,
JIT/core timing/audio mixing disabled, 2D/3D enabled, and the three existing
experimental FMV build switches with the corresponding minimal FFmpeg build.

## Development scene comparisons

Stock 1 GHz, isolated save, World 1 castle, repeated jumps for approximately
20 seconds per scored interval. Timing phase varies slightly between boots.
Geometry submissions come from `input_swap` trace events; complete pictures
come from the published paired-buffer counter. Neither is displayed FPS.
The published game-frame ID is a third counter and must not be described as
an exact geometry-submission count.

| Bone patch / renderer | Geometry submissions/sec | Complete pictures/sec |
| --- | ---: | ---: |
| Off / retained helper, local packet lookup enabled | 34.78 | 44.11 |
| Six omissions / retained helper | 55.80 | 35.52 |
| Six omissions / common helper, candidate flags off | 56.11 | 35.41 |
| Six omissions / final pass only | 55.37 | 36.12 |
| Six omissions / packed rows only | 55.59 | 35.99 |
| Six omissions / short idle only | 57.77 | 33.95 |
| Six omissions / all three | 58.14 | 35.50 |
| Six omissions / all three, integrated-menu repeat | 58.01 | 35.26 |

The short idle alone trades away picture throughput. Combining it with the
renderer changes recovered most of that throughput and reduced the 95th
percentile submission gap from about 30.8 to 19.7 ms in the initial comparison.
The final-pass and packed-row individual results are small and not treated as
independently proven game speedups. No transport faults or OBS capture drops
were recorded in these runs. Held-out game checks and the final package
selection are recorded separately in the beta validation document.

## Remaining bottleneck

The integrated-menu candidate's separate 99 Hz CPU-clock profile collected
2,949 helper samples with zero lost records. Polygon scanline drawing was
24.1% of helper leaf samples, kernel work 11.7%, intake polling 5.4%, polygon
submission 4.6%, packet ingestion 4.1%, text backgrounds 4.1% and affine
backgrounds 4.0%. Leaf shares are not inclusive cost or elapsed-frame time.
In the saved scene trace, uploads averaged about 1 ms; fresh picture creation
spanned about 25 ms including waits and scheduling. Rendering remains a more
promising next target than compressing these already short uploads.

The local FPGA matrix engine has not been implemented or proven. The runtime
bone experiment instead reduced readbacks from ten to four per submission
without adding FPGA logic. The prior passive diagnostic bitstream and reply
burst experiment are excluded from this beta; timing closure is still an
existing limitation of the retained FPGA build.
