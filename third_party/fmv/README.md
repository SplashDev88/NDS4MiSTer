# Private FMV dependency

This dependency is used only when the experimental FMV CMake options are enabled.
The normal build does not link it. It contains no ROM, movie, soundtrack, BIOS,
or extracted game routine.

`PROVENANCE.json` pins FFmpeg 7.1.1 and the Librempeg VX decoder to exact source
hashes. The patch adds the VX decoder, exposes its internal YUV planes without
an intermediate RGB conversion, adapts its DSP call to FFmpeg 7.1.1, and records
decoder-consumption metadata for differential tests. The MobiClip extension
accepts an optional bounded 4,096-byte guest clamp window; an access outside
that window fails decoding. This reproduces the observed Ni no Kuni decoder
behavior without including its tables in the helper.

The combined build is GPL-3.0-or-later. Upstream copyright notices are retained
in the patch. License texts and FFmpeg's licensing notes are in
`licenses/fmv`. A binary distribution must include the corresponding modified
source, patch, build instructions and applicable notices.

Build in a new directory:

```sh
python3 tools/build_fmv_ffmpeg.py --target armhf --output /tmp/nds-fmv-dependency
```

This requires the `arm-linux-gnueabihf-` toolchain, Make and patch. The pinned
archive is downloaded and hash-checked, or can be supplied with `--archive`.
Use `--target native` for software comparison builds. Configure the core with
`NDS4MISTER_FFMPEG_ROOT` pointing to the generated `install` directory and all
three `NDS4MISTER_EXPERIMENTAL_FMV_{PACKED_COLOR,VIDEO_DECODE,VX_DECODE}` options
enabled. Preserve the established ARM helper's LTO and `NO_AUDIO_MIX` settings.

For the qualified helper O configuration, with the ARM toolchain installed:

```sh
cmake -S . -B build-fmv-arm -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-linux-gnueabihf.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS='-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard' \
  -DCMAKE_EXE_LINKER_FLAGS=-static \
  -DNDS4MISTER_ENABLE_LTO_RELEASE=ON \
  -DNDS4MISTER_NO_AUDIO_MIX=ON \
  -DNDS4MISTER_EXPERIMENTAL_FMV_PACKED_COLOR=ON \
  -DNDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE=ON \
  -DNDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE=ON \
  -DNDS4MISTER_FFMPEG_ROOT=/tmp/nds-fmv-dependency/install
cmake --build build-fmv-arm --target nds_hybrid_3d_service
```

Run `nds_hybrid_3d_service --self-test` using a compatible ARM Linux runner.
The full fixture suite was run under Docker/binfmt; running that suite alongside
a game on the memory-constrained MiSTer is not part of the qualification.
The native game tests use the matching retained host and FPGA, identified by
hash in the private kit manifest. Compiler and build-path differences can change
binary hashes; a new binary must be qualified before replacing the tested one.

This is an experiment, not a transparent general DS video decoder. Its guest
protocol changes the physical contents of selected VRAM banks and relies on
verified movie routines, stream identities, ordering and unused memory. The
private ROM fixtures and hardware qualification remain separate from this
dependency build. See `docs/FMV_OFFLOAD_EXPERIMENT_20261022.md` for scope and
limitations.
