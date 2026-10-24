# rc.10 validation and scope

rc.10 retains the accepted **Performance RC1 revision 2** rendering algorithms,
FPGA and runtime settings. Package revision 9 expands the six exact-identity
movie profiles to every MODS/VXDS asset found in their verified cartridges.
The renderer is rebuilt with the same compiler profile data to recognize the
new virtual headers; rendering algorithms and guest hooks are unchanged.
The loader selects same-header revisions by full SHA-256. Both qualified
Ni no Kuni layouts use read-only FAT relocation within the cartridge window.
The README and release notes remain unchanged at the owner's request.

The menu-spacing host is retained from package revision 7: a blank line follows
Display options and Lid; Right Stick Range and Lid are adjacent. Menu navigation,
touch-range, split-output and no-speed-menu checks passed after that layout
change. The public wrapper points at `Scripts/.NDS_Standalone`.
Package/installation receipts accompany the final ZIP; inherited runtime tests
below are not represented as a new sweep of every game.

The Band Brothers DX candidate is excluded. Its first hardware registration
save failed; booting and interpreter tests did not establish working hardware
save support. The earlier NAND implementation is retained for WarioWare D.I.Y.
and Jam with the Band.

## Frozen components

| Component | SHA-256 |
| --- | --- |
| Host | `e8dfbbd4c8b721e01db07bcf0d482701f180d857483229020de48a769fbf2301` |
| FPGA | `4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26` |
| Renderer | `1ad26b0fefaba899227b200c63983c70c5da49f6752c18cc3f19ad9bbf51d1cc` |
| Supervisor | `92ebab31844c099f818e7734a2fc7b35cc1a6460ebe8bf461d67c3e30c7d52aa` |

ARM clock is 1 GHz. Internal performance preset is 5; no Speed hacks OSD.
The inherited host version string remains rc.8. FPGA source is commit
`5924000f9d422fc624fdc0aecad424eab5ca9325` with the three recorded graphics
build overrides. Host/renderer baseline is `12325dfd6af12c962a81b98b2b1978cced5d5ae8`,
plus the recorded menu-removal overlay and rc.10 menu-spacing change. The shipped source archives and
provenance identify each component separately; the package branch's newer RTL
experiments are not the FPGA build inputs.

## Gameplay performance

Measurements count completed paired-screen updates. They are not whole-game
FPS, geometry submission rate, or a direct public rc.9 comparison.

| Scene | Preceding private control | Selected renderer | Scope |
| --- | ---: | ---: | --- |
| NSMB W1 castle, repeated jumps | 35.66/sec | 39.15 and 40.41/sec | Approx. 20 sec windows; repeat in same boot |
| Castlevania cave/bat room | 21.74/sec | 21.89/sec | Fresh boots, matching isolated save seed |
| Mario Kart Figure-8 Circuit | 26.49/sec | 27.33/sec | Fresh boots; race field/timer variation |

NSMB picture-gap p95 changed from 36.18 ms to 32.89/30.03 ms. These scored
recordings had zero transport faults and zero OBS rendering/encoding drops.
Independent later RC1 controls recorded 39.47 (NSMB), 21.75 (Castlevania), and
26.74 (Mario Kart) completed updates/sec, also with zero faults/capture drops.
No new speed claim is made from those standalone controls.

The renderer passed the service self-tests and 5,132 raster comparisons;
256 same-binary boundary cases matched across compiler builds. Profile-guided
compilation had zero coverage mismatches and ships no training instrumentation.
Two reference routes matched both screens with the six-transform NSMB patch;
this is not proof for every level, effect or power-up. The reported goal-pole
background corruption remains unverified and unresolved.

See the included `PERFORMANCE_RC1_VALIDATION_20261023.md` and
`NSMB_SPEED_BETA_VALIDATION_20261023.md` for controls and rejected candidates.

## Supported accelerated movies — current package

| Title | Verified code/revision | Accelerated asset coverage |
| --- | --- | --- |
| Castlevania: Dawn of Sorrow, USA | ACVE / 0 | Existing shared decoder/converter/audio routine hooks; opening validated |
| Chrono Trigger, USA | YQUE / 0 | All 10 MODS streams |
| Ni no Kuni, Japan | B2KJ / 0 | All 17 MODS streams |
| Ni no Kuni, English translation v1.0 | B2KJ / 0 plus full source SHA-256 | All 17 MODS streams, byte-identical to the Japanese movie assets |
| Strange Journey, USA | BMTE / 0 | All 11 MODS streams |
| Final Fantasy XII: Revenant Wings, USA | AXFE / 0 | All 20 VXDS streams |
| Sonic Chronicles, USA | YWSE / 0 | All 59 VXDS streams |

These counts are file streams, including separate upper/lower-screen planes;
they are not counts of distinct cutscenes. The exact inventory is recorded in
[RC10_MOVIE_ASSETS.json](RC10_MOVIE_ASSETS.json). Six cartridge profiles require
a complete source-hash match; Castlevania checks its header and routine bytes.
Other revisions and translations are not automatically qualified. Original
cartridges remain unchanged. Coverage of all listed assets does not establish
full-playthrough testing, every late-game transition, or perfect audio sync.

The opening-only checks below describe the inherited qualification.
The six earlier retail sessions exited cleanly with no transport faults, decoder errors or
detected audio-dropout windows. Ni no Kuni recordings each had one OBS render
drop and zero encoding drops; the strict zero-capture-drop gate was therefore
not met. Selected moving sections showed no source-relative pause exceeding
50 ms beyond expected cadence. Audio-window checks do not prove lip-sync or
absence of all audible defects. A later installed Chrono opening smoke check
passed; the final PGO renderer did not receive another complete six-game sweep.

## Compatibility and controls

- Ni no Kuni's larger ROM layout reached gameplay and save/reload during the
  earlier boot-fix work. Pokémon Conquest USA/Australia revision 1 reached the
  opening battle; save/reload and revision 0 on the fixed image remain unverified.
- WarioWare D.I.Y. USA: Mona score saved/reloaded on NAND3. Jam with the Band
  Europe: registration, one-button demo and profile reload. The later inherited
  runtime did not receive another complete NAND retail sweep. Rhythm latency,
  compositions, microphone, wireless/downloads and power loss are unqualified.
- Right-stick range: all default coordinate pairs, monotonic/clamped output,
  mapping/rotation, persistence/reset and menu tests passed. A hardware touch
  diagnostic reached all corners at 150% with simulated 70% diagonal travel;
  full core exit/reload retained it. The user's physical controller is untested.
- Alternative Main paths: 63 automated launcher/recovery checks passed. Stock
  Main launch and return tested on hardware; other installed frontends need
  actual device checks.
- The live RC1-r2 root menu was checked without a Speed hacks entry. Full host,
  menu, display and right-stick tests passed after the menu-only change.

## Release package checks

The packaging tool verifies all accepted input hashes, exact runtime pins,
source/license coverage, safe archive paths, package checksums and absence of
ROMs, saves and personal settings. The only shipped configuration is the
explicit release performance preset. Source includes authored hook assembly,
corresponding runtime archives, compiler profile counters and FFmpeg source.

A separate receipt records installation, package validation, launch/clean return
and protection of existing saves/settings. The FPGA and host stay byte-identical
to package revision 7. The renderer change and PGO rebuild are documented in
`source/RC10-renderer-build.json`. Do not describe these package checks as new full-game
qualification. Long sessions, all outputs/controllers and multiple boards remain
unqualified; FPGA static timing remains unresolved.

## Package revision 8 English translation qualification (historical)

The original Japanese cartridge SHA-256 is
`7c78318ae93bd5639e592be98b22114e2160c54397f7bfff5e1bfe61b54a4f3c`.
Applying the [translation team's v1.0 patch](https://gbatemp.net/threads/ni-no-kuni-translation-eng.373770/) yields the only accepted English input:
`1ce3fdaf9d83a813328d642e4c7ef41ec8d6273f497b98a09355f9f6f821c627`.
Both retain B2KJ/revision 0, so the header alone cannot select the hooks.
Other patch versions and modified inputs receive no inferred profile.

The English image places real files beyond the 464 MiB cartridge window.
For this exact hash, a read-only virtual layout relocates FAT file payloads
at 128-byte boundaries, keeps the boot/system prefix, and removes only verified
0xff padding. All 12,614 files were audited: the three intended replacements
are the movie overlay and the two opening assets. No original cartridge, save,
translation patch, PDF or movie payload is included in the release.
The virtual image uses 485,837,312 bytes, leaving 701,952 bytes below the limit.
Its SHA-256 is `81ad18886fa7cf0398ef7cc3c6fbb391874cfd4139220e363a597753107be51d`.

A compact-only control and the original translation produced identical screen
hashes and audio across 8,200 emulated frames. All 2,634 decoded opening frames
also matched the Japanese reference. One decoder return crossed an emulated
frame boundary one frame earlier; presented frames and audio remained identical.
The loader reconstructed all five existing virtual images without changing
any output byte. Eleven preparation tests, three hook-guard tests, six supervisor
tests, 24 preflight tests, receiver identity checks and renderer self-tests passed.

The 360-second hardware recording at 1 GHz decoded 5,268 frames across two
opening cycles. There were zero decoder/transport errors and zero OBS rendering
or encoding drops. Selected moving sections on both screens had no pause more
than 50 ms beyond source cadence. The 900 nonquiet 100-ms audio windows had no
detected dropouts. This is bounded opening coverage, not a full playthrough or
proof of every movie, translation revision or audible transition.

NSMB Europe and European Dawn of Sorrow, Chrono Trigger, Revenant Wings and
Sonic Chronicles are **not added**: those owned ROM inputs were unavailable for
address/asset qualification and hardware testing. Their US addresses are not
reused without verification. The existing US NSMB optimization is retained.

A fresh English game reached interactive Morton Street, the control tutorial
and directional movement before a clean exit. It did not reach a progress-saving
checkpoint during that bounded run.

## Revision 8 speed regression check

Fresh 1 GHz hardware runs used the existing isolated seeds and repeated routes:

| Scene | Previous RC1 control | Revision 8 | Active window |
| --- | ---: | ---: | --- |
| NSMB W1 castle, repeated jumping | 39.47/sec | 39.39 and 39.62/sec | 20.71 / 20.65 sec |
| Castlevania cave/bat room | 21.75/sec | 21.84/sec | 20.01 sec |
| Mario Kart Figure-8 Circuit | 26.74/sec | 27.04/sec | 20.01 sec |

No speed regression was detected in these bounded scenes. Every run had zero
transport faults and zero OBS rendering/encoding drops. These are completed
paired-screen updates, not whole-game FPS. Mario Kart field/timer differences
and ordinary measurement variation preclude claiming a new speed improvement.
Renderer source was compared against the accepted baseline: only the movie
receiver identity table and its tests differ; rendering algorithms are unchanged.

A separate cold English boot loaded a copy of the earlier isolated Japanese
checkpoint into Oliver's Room. The 65,536-byte save remained unchanged after
reading, and the session exited cleanly. This validates reading that existing
checkpoint; a fresh English save-write/reload cycle and later story progression
are not qualified by this check.


## Package revision 9 expanded movie qualification

The offline asset audit found 117 MODS/VXDS streams in the five retail images,
plus 17 byte-identical streams in the supported English translation. All 72,725
unique asset frames passed native metadata decoding. Lossless packet reframing
preserves every original video/audio byte, audio count, frame-rate field and
keyframe entry. Every FAT file was compared against its original payload or its
specified movie/overlay transform: 42,755 file entries checked across six profiles.
No movie payloads or game code are included in the profile registry.

The shipped receiver matched full-packet reference output for 89,804 frame decodes
across 134 assets, including replay from frame zero after each movie. Decoder
contexts and six reused output buffers were retained across movie changes.
Strange Journey asset 4930 uses quantizers beyond the original opening's range;
all 1,650 frames matched the game's interpreted original decoder byte-for-byte
(121,651,200 YUV bytes). The envelope guard now accepts the decoder's documented
12–161 quantizer range rather than the opening-only bound of 43.

Both Ni no Kuni layouts discard only audited erased padding; unchanged files
remain byte-identical. The expanded English layout uses 486,051,328 bytes of the
486,539,264-byte cartridge window, leaving 487,936 bytes. The Japanese layout
leaves 6,525,440 bytes. Unknown or modified images retain the existing fail-closed
selection/fallback behavior.

Fresh hardware and package checks are recorded with the final archive receipt.

The same receiver ran directly on the MiSTer's ARM processor against all 117
retail streams: 73,661 frame decodes, including eight-frame restarts where
available, matched complete-packet reference pixels with no errors. The English
movie bytes are identical and were separately included in the 134-asset native
comparison. These are decoder-corpus checks, not full-game playthroughs.

A fresh English Ni no Kuni hardware session played the first story sequence
and returned to interactive Morton Street. Across 360 seconds, 1,800 transport
samples were fault-free, 1,446 video frames decoded with zero errors, and OBS
reported zero rendering/encoding drops. That story asset's 581 frames also
matched the game's interpreted original decoder exactly (42,835,968 YUV bytes).
The earlier opening was skipped during this session. These checks do not prove
all later audio transitions or subtitle synchronization.

The final Revenant Wings profile reuses one abandoned movie span, keeping its
virtual cartridge at 128 MiB. The first expanded draft crossed into 256 MiB.
All movie envelopes are identical between these layouts, and all 1,852 FAT
payloads were rechecked. Only that profile's FAT offsets, cartridge header and
receiver identity changed; the final build passed the renderer self-test.

Fresh cold-launch playback checks used the expanded profiles at 1 GHz:

| Profile | Measured playback window | Decoded frames | Decoder/transport errors |
| --- | ---: | ---: | ---: |
| Chrono Trigger USA | 120 sec | 1,644 | 0 / 0 |
| Revenant Wings USA, initial expanded layout | 120 sec | 1,326 | 0 / 0 |
| Sonic Chronicles USA | 120 sec | 2,134 | 0 / 0 |
| Strange Journey USA | 120 sec | 2,826 | 0 / 0 |
| Ni no Kuni Japan | 150 sec | 2,634 | 0 / 0 |

These five recordings had zero OBS rendering/encoding drops. The expanded
layout's first renderer build was used for this sweep. The final renderer changes
only the Revenant Wings virtual-header identity after the storage adjustment
above; its final-layout playback check is recorded separately. Movie payloads,
decoder code, guest hooks, and rendering algorithms did not change between the
two builds.

## Revision 9 final checks

The final 128 MiB Revenant Wings layout decoded 1,324 frames in a
120-second cold-launch playback check. All 600 transport samples were fault-free,
with zero decoder errors and zero OBS rendering/encoding drops.

| Scene | Preceding revision 8 control | Expanded movie build |
| --- | ---: | ---: |
| NSMB W1 castle, repeated jumping | 39.39 / 39.62 updates/sec | 39.38 / 39.23 updates/sec |
| Castlevania cave/bat room | 21.84 updates/sec | 21.78 updates/sec |
| Mario Kart Figure-8 Circuit, crowded start | 22.13 updates/sec | 22.14 updates/sec |

No material speed regression was detected in these bounded 1 GHz checks. The
NSMB and Castlevania runs used the initial expanded helper; the final helper
differs only in its Revenant Wings header identity. Mario Kart used the final
helper and a fresh matched revision 8 control. Both start-grid screenshots show
the same countdown, time, position and race field. An earlier 22.48/sec result
compared with the older 27.04/sec empty-track scene was not a matched comparison
and is excluded from the regression conclusion. These counts measure completed
paired-screen updates, not whole-game FPS.

All gameplay runs had zero transport faults. The first NSMB capture had one
OBS rendering drop; its repeat had none. Castlevania and both matched Mario Kart
captures had zero rendering/encoding drops. Capturing does not establish an
absence of every visible or audible hitch.

The movie corpus checks cover sequential playback and restarts at frame zero.
The receiver requires consecutive frame sequences; arbitrary seeks beginning
at a nonzero frame are not qualified by these checks. Later in-game transitions,
subtitle timing and full playthroughs still require broader coverage.

## Revision 10 loading follow-up

The rc.10 repack retains the FPGA and renderer binaries from revision 9. It
updates the host and loader to show loading activity, avoid NSMB ARM9
recompression, stream qualified relocated ROMs and cache verified prepared
Ni no Kuni images locally. All loading stages display **Loading ROM**.

[Loading validation](RC10_LOADING_FOLLOWUP.md) and the
[machine-readable results](RC10_LOADING_VALIDATION.json) record image equivalence,
cache invalidation and recovery tests, measured load times, bounded movie checks
and the short NSMB regression check. Cache hits hash the entire prepared image
and check source metadata; the original source is fully hashed on cache misses.
The first cache creation adds SD writes and can be slower than an uncached load.
The package contains no prepared cartridge data, saves or user settings.

The exact final ZIP receives a separate installation, public-launcher, menu,
clean-exit and rollback check, recorded in `RC10_INSTALL_VALIDATION.json` beside
the archive. The approved release notes and README are unchanged. The package
records its new source revision and includes that complete source archive; the
original published rc.10 tag is retained.
