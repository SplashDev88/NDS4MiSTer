# rc.10 validation and scope

rc.10 packages the accepted **Performance RC1 revision 2** gameplay runtime.
The FPGA, renderer, movie worker, supervisor, clock controller and runtime
settings are unchanged. The host is rebuilt only to add one blank line between
Display options, Right Stick Range, Lid and Reset. Menu navigation, touch-range,
split-output and no-speed-menu checks pass after that layout change. The public wrapper points at `Scripts/.NDS_Standalone`.
Package/installation receipts accompany the final ZIP; inherited runtime tests
below are not represented as a new sweep of every game.

The Band Brothers DX candidate is excluded. Its first hardware registration
save failed; booting and interpreter tests did not establish working hardware
save support. The earlier NAND implementation is retained for WarioWare D.I.Y.
and Jam with the Band.

## Frozen components

| Component | SHA-256 |
| --- | --- |
| Host | `877970e11a69ab93d09ef1cea822b5bf8b28f4aa2dc61edc0530b522db7a724a` |
| FPGA | `4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26` |
| Renderer | `78384aacd738bfbacdc50bd9ceb336a2704042e94f09da2b5e0c843caccde35d` |
| Supervisor | `2a94d422e213c71aee3741be5589003376cc0058428a1e0ac4a05579f1df25fc` |

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
| Strange Journey, USA | BMTE / 0 | Opening; 180 sec |
| Final Fantasy XII: Revenant Wings, USA | AXFE / 0 | Upper/lower opening streams; 180 sec |
| Sonic Chronicles, USA | YWSE / 0 | Upper/lower opening streams; 210 sec |

Five cartridge profiles require a complete source-hash match; Castlevania checks
its header and routine bytes. Other revisions, translations and movie assets
are not automatically qualified. The original cartridges remain unchanged.
All six sessions exited cleanly with no transport faults, decoder errors or
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
and protection of existing saves/settings. Renderer/FPGA binaries stay byte-identical
to Performance RC1 r2; the host differs only for menu spacing. Do not describe these package checks as new full-game
qualification. Long sessions, all outputs/controllers and multiple boards remain
unqualified; FPGA static timing remains unresolved.
