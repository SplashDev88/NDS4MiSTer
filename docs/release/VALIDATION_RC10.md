# rc.10 validation and scope

rc.10 retains the accepted **Performance RC1 revision 2** rendering algorithms,
FPGA and runtime settings. Package revision 8 adds exact-hash movie support for
Ni no Kuni's English translation v1.0. The renderer is rebuilt with the same
compiler profile data to recognize that virtual cartridge; the supervisor's
renderer checksum is updated. The loader selects same-header revisions by
full SHA-256 and streams a compacted file layout for this translation only.

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
| Renderer | `728e306fbb6f80bd075dfaa1021fcbca0478d5caca536199cb224a992c0ab1a9` |
| Supervisor | `2f2a2c946187fcc2a1413ba4f178d49911fc37abe823303a40aba8d1b6a5b038` |

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

## Supported accelerated movies

| Title | Verified code/revision | Tested scope |
| --- | --- | --- |
| Castlevania: Dawn of Sorrow, USA | ACVE / 0 | Guarded decoder/converter/audio routines; 140 sec opening |
| Chrono Trigger, USA | YQUE / 0 | Opening; 230 sec |
| Ni no Kuni, Japan | B2KJ / 0 | Both opening streams; 480 sec |
| Ni no Kuni, English translation v1.0 | B2KJ / 0 plus full source SHA-256 | Both opening streams, two cycles; 360 sec |
| Strange Journey, USA | BMTE / 0 | Opening; 180 sec |
| Final Fantasy XII: Revenant Wings, USA | AXFE / 0 | Upper/lower opening streams; 180 sec |
| Sonic Chronicles, USA | YWSE / 0 | Upper/lower opening streams; 210 sec |

Six cartridge profiles require a complete source-hash match; Castlevania checks
its header and routine bytes. Other revisions, translations and movie assets
are not automatically qualified. The original cartridges remain unchanged.
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

## English translation v1.0 qualification

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
