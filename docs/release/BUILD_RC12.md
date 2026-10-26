# RC12 corresponding source and reproduction

NDS4MiSTer-rc12-source.tar.gz contains current source, release packaging, host/supervisor, renderer, loader, movie hooks, kernel support and vendored libraries. The runtime renderer is the accepted e185470c306fee61f4b6aea3c655eeb821c3210f binary; release changes affect version labels, matching component pins and documentation.

## Host and loader

Use tools/standalone_host/build.sh with nds4mister-armhf:ubuntu-24.04 from tools/Dockerfile.mister-armhf (GCC 13.3, Cortex-A9/NEON hard-float, static C++17, O2). Generate hooks with tools/standalone_host/fmv/build_guest.py. The package pins the generated hook hashes. HOST_LABEL_VALIDATION.json records ELF comparison against the tested beta.

## Renderer

Use the included FFmpeg 7.1.1 archive and tools/build_fmv_ffmpeg.py --target armhf. Mount the resulting install at /evidence/vx-research/combined-arm-install, current source at /work, and pgo-combo3-data from portrait-combo3-pgo.tar.gz at /tmp/nds-portrait-combo3-pgo. Run RC12_RENDERER_BUILD.sh. Preserve /work/build-armhf: GCC profile filenames encode paths. The supplied existing Portrait training data uses partial training and changed-function coverage-mismatch fallback. RC12_RUNTIME_INPUTS.json freezes the tested compilation inputs. No JIT or overclock is introduced. Run renderer self-tests only in Docker, never on a live MiSTer.

## FPGA

The retained RBF uses the exact frozen side-native-fpga-inputs.tar.gz tree. RC11_FPGA_INPUTS.json inventories all 1,978 inputs; RC11_FPGA_BUILD.json retains build and unresolved timing results. Build its NDS4MiSTer project using Quartus 17.0 and the archived constraints/fitter settings. Do not duplicate inherited overrides.

## Release ZIP

From a committed release checkout with the built host, run:

    python3 tools/package_rc12_release.py --beta-zip /path/to/NDS4MiSTer_RC11_Ecclesia_FMV_Beta2_20261026.zip --out-dir /path/to/new-output

The recipe requires the exact tested beta hash, retains its renderer/FPGA/hooks, and packages current source, build dependencies, licensing and scoped validation. Publishing is a separate operation.
