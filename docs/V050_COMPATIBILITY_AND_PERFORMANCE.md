# v0.5.0 source and validation

NDS4MiSTer v0.5.0 — compatibility, graphics and speed improvements

Release packaging of the accepted 260925-IFP3 FPGA/ARM pair. Neither runtime
binary was rebuilt for packaging. Public core filename: _Console/NDS_20260925.rbf.
Compiled source: 1d81c99c268375c79e5dcd1e10e891eee5c5900b.
FPGA SHA256: 34c339bbf0142393eb7c95d68c9e2acbf8cc111947d81585447fe04f4107fce1
ARM SHA256: d5963af5bbbc1becdc4a589f58b16edc1c19d02db9ada7fc7963552fe6e985b0
Kickstart SHA256: f85d2bc07a63af3eeda83985ed76801322dea4af668e438f0875fc3a02ebdcfa
WC module SHA256: c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113

This package supersedes the local, unpublished September 24 beta.6 package.
Public beta.5 remains its release predecessor. The release source preserves
all compiled inputs from the IFP3 revision; only release documentation and
checksums change. GPL/copyright notices and original attribution are retained.
No source archive is duplicated as a release asset: GitHub supplies matching
source zip/tar.gz at the release tag.

InsaneFriend compatibility ports:
- Resident Evil: Deadly Silence: privileged ARM9 store-permission correction,
  with reviewed REPU2 data-address permission decoding and legacy CP15 readback.
  Permission handling remains partial, not full DataAbort/read/user emulation.
- Kirby Mass Attack: Thumb format-5 low-register ADD/CMP decode on both CPUs.
- Kirby Super Star Ultra: ARM9 STM original base-in-list value; ARM7 advanced
  base substitution only when writeback is enabled.
- GTA: Chinatown Wars: bounds on every ten-vertex clip-buffer emission prevent
  malformed geometry corrupting the ARM helper stack. Stray grey triangles
  and the underlying malformed-geometry cause are not resolved by this guard.
- Mega Man ZX: DMA display-register mirroring, main-RAM DMA fast lane, VRAM
  queue/read cache, wide SDRAM writes and packed graphics event transport.
  Bounded late forced-blank replay uses later register/VRAM state for held
  lines; this is an intentional timing approximation, bounded at 64 lines.

Integration preserves existing GX readback fence kind 10, assigning packed
VRAM pairs kind 11 on both sides. Fence continuation/commit-last ordering and
malformed-tag validation remain intact. Explicit signed DMA address stepping
fixes a VHDL NATURAL-overload failure for decrement transfers, without an
additional pipeline stage. See docs/INSANEFRIEND_COMPAT_PORT.md for detail,
archive identities, authorship and regression coverage.

User accepted the IFP3 build after testing Mega Man ZX (Europe), reporting it
works amazingly well and requesting this package. This is focused hardware
validation, not a claim of independent full-game testing of all five ports.
The exact pair was loaded with stock 1 GHz ARM, WC pixel mapping, matrix-prefix
fast, query-fast-poll=0, packet-NC=0 and standard-palette-cache=1. The public
Kickstart embeds those same production values; diagnostics remain Off.
Engine B On is required. Use the paired FPGA, helper and launcher together.

Retained unreleased beta.6 improvements:
- Final Fantasy Tactics A2 startup/menu graphics: ordered cached clip-matrix
  results and intake-owned matrix prefixes avoid waiting for unrelated raster.
- Pokemon Platinum character and room furniture: ordered BOX_TEST visibility
  restores geometry while retaining player/matrix fixes. Prior hardware
  room, save and reload checks passed. SoulSilver remains unverified.
- C22 renderer: exact perspective/color/depth span shortcuts, sprite setup
  reuse, NEON sprite rows, affine tile reuse, owned publication planes and
  exact standard 4bpp palette expansion cache with actual-byte comparisons.
  Earlier checks covered 7,077,888 exact pixels on emulated ARM and all 12
  screen hashes across six native scenes. This package makes no universal
  60 FPS, new measured percentage or release-to-release speed claim.
- Kickstart disconnected Wi-Fi retry guard addresses the observed Lunar
  Knights opening-movie kernel scheduling stall. Connected/associating Wi-Fi
  and saved settings remain; normal startup resumes after reboot.
- Castlevania upload snapshot and Metroid window/brightness fixes; Chrono
  startup, sprites and movies; TATE CW/CCW; touch, sound and cartridge saves.
  The bounded four-attempt snapshot policy remains documented in
  docs/CASTLEVANIA_UPLOAD_SNAPSHOT.md.

IFP3 automated validation passed CPU authored-program and negative-control
checks, actual clipper ASan/UBSan/output tests, 72 DMA combinations at three
latencies, 512 SDRAM transactions, VRAM/DMA ownership checks, GX fence/packer
scoreboards, complete console analysis and full host/emulated-ARM service
self-tests, including packed-versus-unpacked rendered-pixel comparisons.
See integration notes for limits of each test.

Quartus 17.0.2 complete map/fit/asm/STA flow succeeded. Utilization:
39,116/41,910 ALMs; 530/553 M10K; 54/112 DSP.
Worst setup slack -21.592 ns; worst hold +0.067 ns; recovery -10.851 ns.
Timing is NOT closed. Hardware acceptance does not guarantee operation across
all boards or timing corners. No timing-closure or Fmax claim is made.
Strange Journey intro freeze, GTA stray triangles, movie/audio hitches and
other game-specific issues remain. Engine B Off is unsupported.

Build ARM with tools/build_hybrid_3d_service_armhf.sh: GCC 13.3.0, Cortex-A9
NEON hard-float, static -O3 and release LTO. FPGA project:
fpga/mister_nitro_console_island/NDS4MiSTer.qpf.
WC module source/config/toolchain/kernel provenance: kernel/nds_mem_wc/.
Pinned Linux 794e6f002d0f655c504733c126a01f8c1f0bc1d4; vermagic
5.15.1-MiSTer SMP mod_unload ARMv7 p2v8. Incompatible module falls back to
Device mapping. Missing/mismatched module or service checksum is an install
error; reinstall the complete matching package.

Packaging verifies exact binary/source identities, existing test receipts,
Kickstart flags, public source/history, ZIP CRC/file inventory/modes and all
checksums. No MiSTer changes during packaging. No games, firmware dumps, saves,
personal captures, credentials, INI or private configuration ship. Source
SHA256SUMS covers every other tracked file. Main LICENSE.txt is GPLv3;
separate WC module is GPL-2.0 with COPYING in kernel/nds_mem_wc/.
