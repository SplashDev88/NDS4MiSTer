# Beta.6 source and validation

NDS4MiSTer v0.4.0-beta.6 — graphics fixes and rendering improvements

Exact accepted PBOX1 FPGA and C22 ARM helper. Neither binary rebuilt.
Public core filename: _Console/NDS_20260924.rbf
Internal FPGA build ID: 260923-PBOX1 (retained to preserve accepted bytes).
FPGA source: 92bc7ec4ed477ee2a22f7c0302bbb892310e9665
FPGA SHA256: 063eea5a39d60e3ffe673fc44cb6845b8dcc49d7ae313f4cd16c963812ca7731
ARM source: 1bf99289437cb8cc19f4c8808f3b076de15746be
ARM SHA256: a110bdb24e63c69c9565cdf9a4725642e998cffe13a87f0a15550890d412bb3d
Kickstart SHA256: f85d2bc07a63af3eeda83985ed76801322dea4af668e438f0875fc3a02ebdcfa
WC module SHA256: c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113

All 958 ARM source/build files match the accepted helper revision.
All 255 non-test RTL, FPGA project and Nitro_DarkSide files match
the compiled PBOX1 revision. A later GX status testbench adds coverage only.
This local release branch starts at public beta.5, with no private development
history. GPL headers and component attribution are preserved.

Engine B On is required; both screens are composed together. Stock ARM 1 GHz,
WC output, matched/full-rate admission and weighted dual-core raster settings
are retained. Kickstart now explicitly supplies matrix-prefix=fast,
query-fast-poll=0, packet-NC=0 and standard-palette-cache=1, exactly as the
accepted private selector did. Existing profiling and black-event capture stay
Off. No extra kernel module, telemetry daemon or private test selector ships.

New compatibility fixes since beta.5:
- Final Fantasy Tactics A2: ordered, cached clip-matrix results restore startup
  and menu geometry. Preserve fast command-bank overflow ordering and advance
  pending geometry after natural VBlank. A bounded intake-owned matrix prefix
  supplies exact results without waiting for unrelated frame raster work.
- Pokemon Platinum: ordered BOX_TEST visibility bit restores room geometry
  (bed, TV/PC, clock, shelves, plant); retains the player/matrix fix. Hardware
  new-game, save and reload checks passed; user accepted graphics and speed.
  SoulSilver has not been validated with this pair; do not claim it fixed.
- Disconnected Wi-Fi retry guard: tested Lunar Knights opening crash traced to
  a kernel scheduling stall. Kickstart stops a verified disconnected wireless
  retry process once; connected/associating Wi-Fi and saved settings are kept.
  Wi-Fi startup resumes on reboot. See docs/WIFI_RETRY_STALL.md.

Rendering improvements: exact general perspective/color/depth span shortcuts,
sprite setup and priority reuse, NEON full-row sprite batches, affine tile
reuse, owned publication planes and moving intake off the busy replay CPU.
C22 additionally caches exact standard 4bpp palette expansion per scanline,
comparing actual palette bytes; no ignored writes or stale frame substitution.
7,077,888 exact output-pixel comparisons passed on emulated ARM. Native six-scene
comparisons matched all 12 screen hashes. Full ARM service self-test passed.
Bounded C22 versus C17 animated Castlevania room runs measured 25.245 versus
25.631 fresh delivered frames/s (+1.53%); this is an incremental C22 comparison,
not a release-to-release, whole-game or 60-FPS claim. Other scene speeds vary.
The user accepted C22: some slowdown, but much better. Original test captures
and game-derived fixtures are private and excluded from release/source assets.

Prior Castlevania upload-snapshot and Metroid window/brightness corrections,
Chrono startup/sprite/movie fixes, Kirby fixes, TATE, saves, touch and sound are
retained. The bounded four-attempt upload snapshot policy and its accuracy
tradeoff remain documented in docs/CASTLEVANIA_UPLOAD_SNAPSHOT.md.

InsaneFriend (GitHub: saneFriend) is credited for retained writable SPI
firmware, ARM7 Wi-Fi boot-memory and cartridge-IR compatibility fixes.
These boot-memory fixes do not implement Nintendo DS wireless networking.
The separate Resident Evil: Deadly Silence PU-store submission is NOT in this
accepted PBOX1 FPGA. Its REPU1 trial regressed NSMB/Castlevania startup; the
REPU2 follow-up remains separate. Do not advertise Resident Evil as fixed.

PBOX1 full Quartus 17.0.2 seed-2 flow passed: 38,011 ALMs, 449 M10K, 54 DSP.
Worst setup slack -19.680 ns, hold +0.066 ns. Timing is not closed. Gameplay
acceptance is not a timing guarantee across boards. No Fmax or 60-FPS claim.
Strange Journey intro freeze, occasional movie/audio hitches and other
compatibility/performance limitations remain. Engine B Off is unsupported.

Build ARM with tools/build_hybrid_3d_service_armhf.sh: GCC 13.3.0, Cortex-A9
NEON hard-float, static -O3 and release LTO. FPGA project:
fpga/mister_nitro_console_island/NDS4MiSTer.qpf.
WC module source/config/toolchain/kernel provenance: kernel/nds_mem_wc/.
Pinned Linux 794e6f002d0f655c504733c126a01f8c1f0bc1d4; vermagic
5.15.1-MiSTer SMP mod_unload ARMv7 p2v8. Incompatible module safely falls back
to Device mapping. Missing/mismatched module or service checksum is an install
error; reinstall the complete matching package.

Release packaging verifies supervisor lifecycle/flags and Wi-Fi guard offline,
exact runtime/source hashes, source/history audit, ZIP CRC/modes/file inventory
and all checksums. No hardware changes during packaging. No games, firmware
dumps, saves, private captures, credentials, INI or personal configuration ship.
Matching source uses GitHub automatic zip/tar.gz at the release tag. No duplicate
source ZIP asset. SHA256SUMS covers every other tracked file. Main LICENSE.txt
is GPLv3; separate WC module is GPL-2.0 with COPYING in kernel/nds_mem_wc/.
