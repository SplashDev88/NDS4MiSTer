# Deterministic optimization replay tools

These tools reuse the existing software reference and instruction-entry hook.
They do not patch a ROM, modify hardware, install a service, or provide core
save states. ROMs, saves, recordings and RAM/audio dumps stay in private test
storage and must not be packaged with the core.

Build the ordinary `nds_layer_capture` target in a Ninja build, then run:

```sh
python3 tools/game_optimization/build_replay_oracle.py \
  --build /path/to/ninja-build --out /path/to/private-oracle
```

The private build substitutes an instrumented `ARM.cpp` object at link time;
product binaries and source are untouched. Invocation:

```text
replay_oracle ROM SAVE OUTPUT_DIRECTORY FRAME_COUNT INPUT_TSV WATCH_PC_FILE [PROFILE_START_FRAME]
```

At least 2,601 frames are required so both raw RAM checkpoints exist. Input
rows contain first frame, exclusive last frame, and hexadecimal DS key
mask. Watch files contain hexadecimal ARM9 PCs; an empty file disables register
watch logging. The oracle fixes RTC time, disables JIT, uses the existing game
profile selector, and requires complete 3D rendering. It records both screen
hashes, per-frame RAM-region hashes, audio, final saves, selected raw RAM dumps,
and instruction samples. CPU instruction counts are not FPGA cycle counts.

Use the same verified ROM/save/input files for both runs. Enable an experimental
renderer only in its candidate process environment. Compare with:

```sh
python3 tools/game_optimization/compare_replays.py /path/to/control /path/to/candidate \
  --output /path/to/comparison.json
```

Missing evidence fails comparison. The software reference complements native
MiSTer testing; it does not establish native speed, output latency, or all-game
correctness. Native experiments must check actual helper flags and visually
confirm the same scene before counting screen publications. Game-specific
inputs and identities belong in `docs/game-optimization`, not these tools.

`package_private_beta.py` builds a separate launcher/support-folder package from
a pinned base archive, a tested renderer and a declarative packaging definition.
It includes corresponding source and compiler profiles, checks package hashes
and excludes top-level ROM/save/settings files. Native scene qualification and
a clean archive-install smoke test are still required; packaging alone does
not establish performance or correctness.
