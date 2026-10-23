# Parallel phase oracle

These fixtures contain synthetic geometry only. They compare complete color,
depth and attribute buffers with serial rendering, exercise queued frames,
image clears, fog, edge marking, antialiasing, row and X partitions, and hold
the semaphore protocol at selected points to test cancellation and shutdown.
The hooks are test-only; do not link `phase_test_platform.cpp` into the service.

Build against the same `libcore.a` and `libteakra.a` used by the service. Include
`tools`, `src`, `third_party/melonDS/src`, the generated core build directory,
and this directory. Compile `phase_oracle.cpp` and `phase_test_platform.cpp`
with `-fno-access-control`, C++17, `-fwrapv`, and the same CPU, ABI and feature
definitions as the core. The platform fixture supplies HeadlessPlatform, so
do not also link a separate HeadlessPlatform object. A core built with the
experimental FMV paths also requires the corresponding FFmpeg headers and
static libraries (`avcodec`, `avutil`), feature definitions and dependencies.

The ARM qualification used Cortex-A9/NEON/hard-float, `-O3 -DNDEBUG`, LTO,
static linking, and `-pthread -ldl -lrt -lm`. Allow at least 1,200 seconds on
an emulated ARM runner. Successful completion prints:

```text
C58_PHASE_ORACLE_PASS full_buffers=2640 transitions=864 queued=192 x=144 canceled=6 secondary_first=3 shutdowns=3
```

The recorded full run passed under ARM emulation in 362 seconds. An earlier
native attempt exceeded its 480-second harness deadline; it is not counted
as a native correctness pass. Separate real-game checks qualify the selected
renderer configuration on MiSTer. The clear/setup overlap remains disabled
in the private beta comparisons.
