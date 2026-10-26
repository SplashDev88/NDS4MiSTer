# RC11 corresponding source and reproduction

NDS4MiSTer-rc11-source.tar.gz contains the release source and packaging recipe, including the exact source for the rc11 host, supervisor, loader, renderer, guest hooks, kernel modules and vendored libraries. The renderer logic is unchanged from e7bb1119ab6b3fc0f2f8f03ffc38f8a0ff474b27. RC11 release metadata and the host version string are the only additions to the tested beta behavior.

## Host

Build with tools/standalone_host/build.sh and the nds4mister-armhf:ubuntu-24.04 image from tools/Dockerfile.mister-armhf. GCC 13.3 targets ARMv7 hard-float Cortex-A9/NEON, static linking, C++17, -O2. HOST_LABEL_VALIDATION.json proves executable sections match the tested Beta4 host; the menu string and linker build ID differ.

## Renderer

Use the included ffmpeg-7.1.1.tar.xz and tools/build_fmv_ffmpeg.py --target armhf --archive /path/to/ffmpeg-7.1.1.tar.xz --output /new/build/path in the ARM cross-toolchain environment. The source pins the FFmpeg patch. Mount its resulting install directory at /evidence/vx-research/combined-arm-install, the source at /work, and the pgo-combo3-data directory from portrait-combo3-pgo.tar.gz at /tmp/nds-portrait-combo3-pgo. Run RC11_RENDERER_BUILD.sh inside that container. Preserve /work/build-armhf: GCC profile filenames encode those paths.

RC11_RENDERER_BUILD.json records compiler options, dependency hashes and container identity. Compiler training counters contain no ROMs or saves. Fixture/oracle reruns require your own legally supplied game images. The helper's NO_AUDIO_MIX build flag applies to its HPS graphics path; DS hardware audio remains active. Run service self-tests only in the ARM build environment, never on a live MiSTer.

## FPGA

side-native-fpga-inputs.tar.gz is the complete frozen input tree for the retained bitstream, including its overlaid RTL and constraints. RC11_FPGA_INPUTS.json hashes all 1,978 files; RC11_FPGA_BUILD.json records results. Build project fpga/mister_nitro_console_island/NDS4MiSTer with Quartus 17.0 using the archived QSF settings, including the recorded four-worker fitter setting. Do not append inherited overrides a second time. Static setup/recovery timing remains unresolved. Project source contains the kernel support source and its build instructions as well.

## Package

From this source's committed Git checkout, run:

    python3 tools/package_rc11_release.py --beta-zip /path/to/NDS4MiSTer_Portrait_FMV_Beta4_20261025.zip --out-dir /path/to/new-output

The recipe requires the exact hash-pinned Beta4 artifact and the built host. It preserves tested binaries and movie hooks, supplies current source/licensing, and verifies the resulting package. Public publication is a separate step. Detailed beta hardware results are retained with their original scope; RC11 package validation is recorded separately.
