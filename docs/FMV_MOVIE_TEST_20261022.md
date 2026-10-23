# Private FMV Movie Test

This private launcher selects six prepared movie tests on the development
MiSTer. It uses helper O, the retained Castlevania Beta2 host and FPGA image,
and the established 1 GHz ARM clock. It is not a public release package.

## Start a test

1. Exit the current core using **System → Reboot** to return to MiSTer's menu.
2. Open **Scripts → NDS_FMV_Movie_Test**.
3. Choose a game using the arrow keys and Enter. The launcher verifies its complete prepared ROM and the
   matching runtime files before starting; allow time for this check.
4. For Castlevania, Chrono Trigger, Revenant Wings and Sonic Chronicles, wait
   for the opening movie. For Ni no Kuni, confirm at the title screen. For
   Strange Journey, choose New Game to start the opening sequence.
5. Exit with **System → Reboot** before selecting another test.

The choices are Castlevania: Dawn of Sorrow, Chrono Trigger, Ni no Kuni,
Shin Megami Tensei: Strange Journey, Final Fantasy XII: Revenant Wings and
Sonic Chronicles. The new launcher keeps the existing launchers available.

## What this test includes

The five new prepared copies offload selected opening-movie decoding and
color conversion to the ARM renderer. Strange Journey also offloads its
postfilter. Castlevania uses the existing guarded Beta2 decoder fast paths.
The menu checks full ROM hashes, game codes and revisions, plus the exact
host, renderer, FPGA, supervisor and bootstrap identities. Mismatches stop
the launch before takeover.

These optimizations preserve the movies' authored frame rates: an original
12 or 15 FPS movie should run at that rate. They do not create interpolated
60 FPS video. Later movies and whole-game compatibility are not certified.

The prepared copies stay on this MiSTer. Selecting an ordinary ROM through
the core's Load menu does not apply the five new prepared-copy optimizations.
Use this launcher's game selection for the measured tests.

## Saves and rollback

Each choice uses its own `NDS FMV …` save in `saves/NDS`. These are test saves,
separate from the normal game saves; progress does not automatically transfer
between them. Original ROMs, normal saves, settings and existing launchers
are unchanged. Return to the normal launcher to resume normal use.

The helper protocol changes selected VRAM contents and is restricted to
the explicitly prepared routines. Do not mix this helper with other runtime
files or treat this private fixture launcher as an update for all users.

## Evidence and source

The detailed experiment report is
[FMV_OFFLOAD_EXPERIMENT_20261022.md](FMV_OFFLOAD_EXPERIMENT_20261022.md).
It distinguishes failed prototypes, software differential tests, measured
native openings, audio comparisons, transitions and gameplay controls.

The installed kit includes validation receipts, build instructions, applicable
licenses and corresponding source. No ROM, movie or soundtrack is included
in that source bundle. The pinned minimal FFmpeg/Librempeg decoder dependency
and build recipe are described in
[third_party/fmv/README.md](../third_party/fmv/README.md).
