# Bounded texture and palette upload snapshots

NDS4MiSTer v0.4.0-beta.5 — graphics corrections

Exact accepted FPGA/ARM pair; neither binary rebuilt for packaging.
FPGA: BREG2, internal build 260919-BREG2, Quartus 17.0.2 seed 2.
FPGA source: e9d32242b3511b70b458bfc6b9910aab6b93607c
FPGA SHA256: 6067222c1adeff683318eb7db82b4c6acf0abfa199336db02c90c443417eb840
ARM source: c00f91d000656328740822c748971138c31db4e0
ARM SHA256: 1a5df0005b5f6cdb47e1f65d03bb6ae533f2a61bf443125a4c9444ca347fe659
Kickstart SHA256: ec8cdfed70e66003f5c86b08568730de0caa5125d13b94997be5af986c4e853a
WC module SHA256: c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113
Public filename: _Console/NDS_20260920.rbf (renamed, identical bytes).

All 483 frozen FPGA inventory files and 951 ARM
source/build inputs match the accepted revisions. Quartus appended a redundant
source assignment to its working QSF; this tree preserves the frozen pre-build
QSF with the assignment already in files.qip. Only reviewed source is ported
onto public history. No private development history or runtime binaries added.

Engine B On is required. Both 2D screens and 3D are composed together on ARM.
FPGA CPU, audio, input, cartridge, saves and LCD event paths remain active.
Stock 1 GHz, WC, full-rate admission, weighted raster bands and TATE retained.
Kickstart enables H3D_UPLOAD_SNAPSHOT=1 and the existing matched/full-rate,
weighted/dual-core/adaptive/band-queue/X-partition settings. Full profiling and
BLACK_EVENT_TRACE are forced Off. Raw helper launches require the same flags.
Diagnostic code is dormant in the identical tested binary; no automatic capture
cookie, data dump, diagnostic launcher or telemetry process is shipped.

Metroid: FPGA Engine B shadow now returns readable window, blend and brightness
bits, retaining masks, byte lanes and reset. WININ read/modify/write previously
cleared the game's first window, removing the top screen's left half. Focused
register tests, complete console VHDL analysis and full Quartus flow passed.
Original title image was verified restored, then user tested gameplay successfully.

Castlevania: completed 3D raster fencing plus bounded texture/palette upload
snapshots. Temporarily mapping texture or palette banks to LCDC for upload could
clear flattened inputs before the deferred renderer used them. Retain the last
complete flattened slot for at most four render attempts while its prior banks
are in LCDC upload mode. Remap refreshes immediately, reassignment clears, real
mapped black palettes apply, permanent unmap expires and reset clears history.
Tradeoff: briefly older complete texture/palette contents during uploads; this
is not a cycle-accurate model of deliberately unmapped banks. Raw guest VRAM,
mappings and writes are unchanged. No new game/frame waits or clock increase.
The earlier two-attempt policy still flashed at captured expiry; four attempts
passed the user's moving gameplay comparison. One 20-second capture had zero
near-black samples in 500 coherent source samples and zero in 501 independent
samples. These are observations, not physical FPS or universal compatibility.
The user then tested Metroid Prime Pinball and reported it works great.

Full ARM service self-test and actual four-attempt texture-cache regression
passed under emulation. Regression covers expiry, remap, partial upload, mapped
black, reassignment, default oracle behavior, reset and trace masks. Event file
writer bounds itself to the smaller of 60 KiB and inherited RLIMIT_FSIZE.
Packaging separately verifies launcher environment/lifecycle, exact-source
identity, source/history audit, ZIP CRC/modes/content and all checksums.
No hardware changes or further gameplay tests occur during packaging.

ARM build: tools/build_hybrid_3d_service_armhf.sh; GCC 13.3.0, Cortex-A9/NEON
hard-float, static -O3, release LTO. FPGA project:
fpga/mister_nitro_console_island/NDS4MiSTer.qpf.
WC module source/config/toolchain/kernel provenance: kernel/nds_mem_wc/.
Pinned Linux 794e6f002d0f655c504733c126a01f8c1f0bc1d4; module vermagic
5.15.1-MiSTer SMP mod_unload ARMv7 p2v8. Incompatible module falls back to
Device pixel mapping; partial or corrupt module/hash pair is an install error.

Fit: 37506 ALMs needed, 39424 placed, 4139/4191 LABs, 447 M10K, 54 DSP.
Worst slack ns: setup -15.766, hold +0.041, recovery -10.706, removal +0.264.
Timing is not closed. Accepted based on user gameplay; no Fmax or FPS claim.
Strange Journey intro freeze, movie/audio hitches and other compatibility bugs
remain. Slow Pokemon GX readback fix deferred; Engine B Off unsupported.

No games, BIOS/firmware dumps, personal saves, captures or credentials included.
Use matching GitHub automatic Source code zip/tar.gz; no duplicate source ZIP.
SHA256SUMS covers all other tracked source files. Main GPLv3 LICENSE.txt;
separate module GPL-2.0 kernel/nds_mem_wc/COPYING. All attribution retained.
