# RC15 AA Beta1 build

The source archive contains the matching host and renderer source in
`NDS4MiSTer-rc15-source.tar.gz`. The FPGA is byte-identical to public RC14;
its frozen inputs and provenance remain in `components/`. The original PGO
training counters and FFmpeg 7.1.1 source are also retained there.

Use the RC14 ARM hard-float toolchain/container and FFmpeg build instructions.
Mount this source at `/work`, extract the 79 original `.gcda` counters into
`/tmp/nds-portrait-combo3-pgo`, and mount the FFmpeg ARM installation at
`/evidence/vx-research/combined-arm-install`. The `/work/build-armhf` path is
significant for matching the training profiles.

Run `tools/release/build_rc15_renderer.sh` inside that container. It builds and
tests the renderer using the same Release/LTO/PGO recipe as RC14, with partial
training and coverage correction for changed source. Missing/mismatched old
profiles may fall back to ordinary optimization, as in the release recipe.
Run `tools/standalone_host/build.sh` from the host for the standalone executable.
The host generator reads `tools/standalone_host/VERSION`.

Run the host graphics, display menu, Direct Video, split output, touch range,
screen peek and dual OSD C++ tests on Linux, plus the Python supervisor,
public preflight and video target tests. Renderer `--self-test` includes full
pixel/native-buffer oracles for AA and repeated live AA toggles with identical
geometry. Never run the service self-test on an active MiSTer.

After building, pin the helper SHA256 in `supervisor.py`, commit the source,
and invoke `tools/package_rc15_beta.py` with `--rc14`, `--sources` (the pinned
RC14 runtime/source ZIPs), and a new `--out` directory. Its audit requires the
RC14 core/catalog and all unrelated runtime payloads to remain byte-identical.
No user graphics preference is bundled; a fresh installation defaults to On.

This package does not establish FPGA timing closure or a general game-speed
improvement. Hardware evidence is recorded separately against package hashes.
