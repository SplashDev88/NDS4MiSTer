# RC14 corresponding source and build instructions

The installable `NDS4MiSTer_v0.9.0-rc.14_Standalone.zip` contains runtime
files, instructions and licenses. Matching development material is supplied
separately in `NDS4MiSTer_v0.9.0-rc.14_Sources.zip`.

`NDS4MiSTer-rc14-source.tar.gz` is the committed release tree. It includes
the host, supervisor, loader, accepted 22-entry guest catalog and hook
assembly, renderer and kernel-module sources, vendored libraries, and packaging
tools. The remaining `components/` files preserve the exact older inputs
used for the unchanged FPGA and renderer binaries.

## Host

Build the cross-compilation container using `tools/Dockerfile.mister-armhf`.
The tested Ubuntu 24.04 image and command are recorded in
`docs/release/RC14_HOST_BUILD.json`. Run:

```sh
bash tools/standalone_host/build.sh
```

This generates `core_menu.h` from `VERSION` and compiles a static Cortex-A9,
NEON, hard-float C++17 executable at O2. Before relabeling, the same build
reproduced the accepted Y/C Beta2 host byte for byte. RC14 changes only
the version literal in the compiled host inputs. The shorter label moves
section addresses and references, so byte identity of the relabeled host
is not claimed. Host tests and the Python/host reader integration pass.

## FPGA

The core is the exact successful Y/C Beta2 binary. Extract
`components/dv1-yc-fpga-inputs.tar.gz` into a separate directory. Its 1,979
inputs are checked against `components/FPGA_INPUTS.json`.
`components/FPGA_BUILD.json` records the source revision, tool version,
resource use, stage outcomes and unresolved timing.

Use Quartus Lite 17.0.2 Build 602 with the included project and constraints
in `fpga/mister_nitro_console_island`, and run map, fit, asm and sta for
`NDS4MiSTer`. The original build used Linux/amd64 under Docker with its
libudev compatibility shim. No FPGA rebuild was needed for RC14. Static
setup/recovery timing is not closed.

## Renderer and FFmpeg

The renderer is unchanged from RC13. Its exact source, input inventory,
original build record and commands are in the `components/Regional_Renderer_*`
files. The original build record predates later acceptance and hardware
qualification; it is preserved as a historical record.

Build the included FFmpeg 7.1.1 using `tools/build_fmv_ffmpeg.py --target armhf`.
Mount its install at `/evidence/vx-research/combined-arm-install`, renderer
source at `/work`, and the counters from `portrait-combo3-pgo.tar.gz` at
`/tmp/nds-portrait-combo3-pgo`. Run `Regional_Renderer_BUILD.sh` in the cross
container. Preserve `/work/build-armhf`, since GCC profile paths matter.
Partial-training and coverage-mismatch fallback are intentional. Run renderer
self-tests only in the container, without opening a live MiSTer device.

## Loader and kernel modules

Runtime Python and JSON match the committed release source. The compiled
guest stubs are reproduced from its assembly and match the accepted bytes.
`fmv/guest_catalog.json` is the unchanged RC13 catalog.
The normal launcher pins its hash. Mario Kart course transformations and
their cache are excluded; the existing movie cache remains available. No ROM or prepared cartridge asset is included or needed
to build these tools. The existing `fmv/build_guest.py` regenerates compiled
stubs with the ARM toolchain.

The unchanged write-combining modules support 5.15.1-MiSTer and
6.18.38-MiSTer. Their module source, kernel configuration, build scripts,
dependency revisions and provenance are under `kernel/nds_mem_wc` in the
release source tree. Build recipes name the required external kernel and
cross-toolchain inputs.

## Packaging

Build the host above and run `python3 tools/standalone_host/fmv/build_guest.py`
inside the cross-build container first. Generated hook binaries are ignored
by Git; the packager verifies them against the accepted runtime bytes.

The maintainer packager authenticates the original source-complete Y/C
Beta2 ZIP and Mr. Moro's supplied profile ZIP:

```sh
python3 tools/package_rc14_release.py \
  --yc-zip /path/to/NDS4MiSTer_DV1_YC_Beta2_20261103.zip \
  --profile-zip '/path/to/NDS4MiSTER - Retrotink 4K Profile.zip' \
  --out-dir /path/to/new-output
```

Those historical package inputs are maintainer artifacts; all corresponding
component sources are independently present in this source download. Inspect
an install ZIP with `python3 tools/package_rc14_release.py --audit FILE.zip`.
Packaging creates files locally and performs no upload, push or publication.
