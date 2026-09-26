# v0.5.1 source and validation

NDS4MiSTer v0.5.1 — NSMB graphics, optional Engine B and rendering speed

Accepted build: 260926-VEC1. Public core: _Console/NDS_20260926.rbf.
Compiled FPGA source: f61d3eed8945616c947694e64a5010e7abefed88
Compiled ARM source: 316917c08290705721e3805551744c98b4368ac1
FPGA SHA256: dd2f7dd3c68025d25493307cde0883b12b163d2b426edf717ee5272f5f915c55
ARM SHA256: ae491e2041f3d5a14cc9dabbeaf22a0869a58d2331f56e6905ae2ee3f37e9a1b
Kickstart SHA256: e76a83d8678e7feac55609d3689707e4c0b5f52b16fc2a5b614f696ef57c7273
WC module SHA256: c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113

Neither runtime binary was rebuilt for packaging. All compiled inputs are
preserved. The public launcher now embeds query-fast-poll=1, matching the
accepted private selector, with matrix-prefix=fast, packet-NC=0 and standard
palette-cache=1. The launcher lifecycle regression checks these values.
Stock 1 GHz, write-combining, matched full-frame transport, upload snapshot,
weighted dual-core raster and direct plane publication remain enabled.
Diagnostics and optional timing profiling are Off during normal operation.

Changes since v0.5.0:
- Optional Engine B uses a complete matched transport in both modes. Off
  skips B rendering and points both output planes at the completed A image.
  Frame ownership, reset/session validation, TATE and true dual-screen On
  remain supported. Content available only through Engine B is absent Off.
- NSMB repeating 2D HBlank DMA no longer invalidates the geometry matrix cache.
  A bounded single-unit HBlank transfer can use independent main-RAM/IO fast
  lanes while the CPU waits for a real GX reply. That reply is retained until
  DMA releases the IO mux. No speculative CPU response or fake geometry data.
- H/I VRAM mirror decoding restores NSMB's Engine B overworld-map graphics.
- VEC1 exposes the nine already-computed vector matrix words at 0x680..0x6a0
  through the existing readback cache. Missing reads collapsed NSMB Star Coin
  environment coordinates to a pale center texel; correct values restore gold.
- Exact decoded texture-row alpha summaries avoid raster work for invariant-T
  spans that the game's alpha test will reject. Normal invalidation/re-upload
  and multi-layer texture handling are retained; no approximate shading.

User acceptance on September 26: NSMB works great, with the Star Coin fixed,
and a large perceived Castlevania speed improvement. This is not a measured
Castlevania FPS percentage. The VEC1 coin fix alone measured 29.87 versus 29.86
adopted paired screens/s in the same static hardware fixture using the same
fast helper (about 0.04% difference, effectively unchanged). These are transport
update rates, not unique-pixel FPS or a whole-game 60 FPS claim.
Earlier row-cache comparison in a stationary castle scene measured about 3.3%
more adopted pairs/s than EBO7's preceding helper; scene phases differed.
Engine B Off did not show a meaningful additional NSMB speed gain in the
tested EBO7 starting scene. Other games may benefit; no universal gain claimed.

Qualification includes all 25 cached matrix words, vector-first/clip reuse,
busy/stale/reset/invalidation and reply CDC regressions, plus 91,872 matrix
prefix comparisons. The exact ARM helper passed its full emulated ARM service
self-test, 774 cached/uncached raster comparisons and 108 texture re-upload/
layer cases. Earlier accepted On/Off mode, HBlank overlap and 262,144 H/I VRAM
decoder checks are retained. Software zero-vector replay reproduces the pale
coin; hardware A/B on a private placement fixture confirms white on EBO7 and
gold on VEC1. Private ROM fixtures and saved states are not distributed.
Castlevania startup pictures were also checked; the user then tested gameplay.
Full playthroughs and universal board/game compatibility are not claimed.

Quartus 17.0.2 map/fit/asm/STA completed. Area 38,902/41,910 ALMs,
42,524 registers, 530/553 M10K, 54/112 DSP. Worst setup -21.922 ns;
worst hold -0.373 ns. Timing is NOT closed. EBO7 baseline setup was -15.255 ns
and hold -0.336 ns. Hardware acceptance does not establish timing closure or
guarantee all devices/corners. No Fmax claim is made.

Earlier InsaneFriend/saneFriend ports remain: Resident Evil: Deadly Silence,
Kirby Mass Attack, Kirby Super Star Ultra, GTA: Chinatown Wars, Mega Man ZX.
See docs/INSANEFRIEND_COMPAT_PORT.md for authorship, exact integration details
and limits. FFT A2/Platinum graphics, C22 rendering, Castlevania/Metroid display
fixes, Chrono startup/movie/sprite fixes, saves/touch/TATE and disconnected
Linux Wi-Fi retry guard remain. DS wireless multiplayer is not implemented.
Strange Journey intro freeze, GTA stray triangles, movie/audio hitches and
other game-specific issues remain. SoulSilver has not been independently
verified with these graphics fixes.

ARM build: tools/build_hybrid_3d_service_armhf.sh, GCC 13.3.0, Cortex-A9 NEON
hard-float, static -O3/release LTO. FPGA project:
fpga/mister_nitro_console_island/NDS4MiSTer.qpf.
WC module source/config/toolchain/kernel provenance: kernel/nds_mem_wc/.
Pinned Linux 794e6f002d0f655c504733c126a01f8c1f0bc1d4; vermagic
5.15.1-MiSTer SMP mod_unload ARMv7 p2v8. Incompatible module falls back to
Device mapping. Missing or mismatched service/module checksums are install
errors; reinstall the complete matching package rather than bypassing them.

No games, BIOS/firmware dumps, saves, private captures, credentials or INI
ship. Source SHA256SUMS covers every other tracked file. GPLv3 headers,
attributions and the separate GPL-2.0 WC COPYING are preserved. Installer
inventory/modes/internal and external hashes, source/history and Git archive
are verified. GitHub provides source zip/tar.gz from the matching release
tag; do not duplicate a source ZIP as a release asset.
