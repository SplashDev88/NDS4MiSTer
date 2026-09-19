# NDS4MiSTer v0.4.0-beta.4

**Much faster, with several graphical regressions still to fix.**

## What's new

This release packages the latest test build, MATCH4. It is much faster in testing, but several graphical regressions remain and will need to be fixed in future updates. Speed and smoothness vary by game; this is still an experimental beta.

The updated renderer composes both screens together, improves rendering and caching, and removes the previous alternate-frame drawing limit. Write-combining graphics transfers and stock 1 GHz ARM operation are retained.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, open **Console → NDS_20260918**.
6. Set **Engine B (next Reset) → On**, then choose **Load NDS** and select your game. If a game is already loaded, reset or reload it after changing Engine B.

**Engine B must be On for this build.** Older saved settings may leave it Off, which can produce a blank display. Run Kickstart after every reboot and any time you return to the NDS core. If five minutes pass before opening the core, run Kickstart again. Use the core, helper and launcher supplied together.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the monitor's physical turn: **90 CCW** for a clockwise turn, or **90 CW** for a counterclockwise turn. D-pad, mouse and touch retain their native directions for the turned monitor.

The MiSTer menu rotates separately. Under `[NDS]` in `MiSTer.ini`, use `osd_rotate=2`, or `osd_rotate=1` if the menu appears upside down. Edit the existing `[NDS]` section if present, then save and reboot. The installer does not edit your INI.

## Second screen

Both screens are composed together in this build. **Keep Engine B On** and reset or reload your ROM after changing the setting. The Engine B Off option remains in the menu but is not supported by this test build.

## Known issues

- **Several graphical regressions remain.** Flickering, intermittent black flashes and other rendering problems still need fixes. Castlevania's bottom-screen flashing is unresolved.
- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **Movies and audio can still hitch.** Higher speed does not guarantee smooth or full-speed playback in every game.
- **Pokémon SoulSilver and Platinum:** player and furniture graphics can remain missing; the slower GX readback correction is still deferred (issue #16).
- **Sound and compatibility remain experimental.** Demanding games may stutter, glitch or crash. No universal 60 FPS claim is made.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source will be available through GitHub's **Source code (zip)** and **(tar.gz)** links when this release is published. The installer and source tree each include internal checksums.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
