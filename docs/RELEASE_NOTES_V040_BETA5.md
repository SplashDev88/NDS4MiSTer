# NDS4MiSTer v0.4.0-beta.5

**Graphics fixes for Castlevania and Metroid Prime Pinball, with the recent speed gains retained.**

## What's new

- **Castlevania: Dawn of Sorrow's black flashes fixed.** The bottom screen could briefly flash black while moving around. The latest fix passed our gameplay testing without the flash returning.
- **Metroid Prime Pinball's missing screen section fixed.** The left half of the top screen now displays correctly, including the title screen.
- **Recent speed improvements carry over.** Faster rendering, write-combining graphics transfers, smoother movies and both TATE rotation directions are retained. The ARM processor still runs at stock 1 GHz.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, open **Console → NDS_20260920**.
6. Set **Engine B (next Reset) → On**, then choose **Load NDS** and select your game. If a game is already loaded, reset or reload it after changing Engine B.

**Engine B must be On for this build.** Older saved settings may leave it Off, which can produce a blank display. Run Kickstart after every reboot and any time you return to the NDS core. If five minutes pass before opening the core, run Kickstart again. Use the core, ARM helper and launcher supplied together.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the monitor's physical turn: **90 CCW** for a clockwise turn, or **90 CW** for a counterclockwise turn. D-pad, mouse and touch retain their native directions for the turned monitor.

The MiSTer menu rotates separately. Under `[NDS]` in `MiSTer.ini`, use:

```ini
[NDS]
osd_rotate=2
```

If the menu appears upside down, use `osd_rotate=1`. Edit the existing `[NDS]` section if present, then save and reboot. The installer does not edit your INI.

## Second screen

Both screens are drawn together in this build. **Keep Engine B On** and reset or reload your ROM after changing the setting. The Engine B Off option remains in the menu but is not supported by this build.

## Known issues

- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **Movies and audio can still hitch.** Playback is smoother than earlier releases, but not flawless in every game.
- **Pokémon SoulSilver and Platinum:** your character and furniture can remain invisible. The fix costs too much speed and is still on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Other graphics and compatibility problems remain.** These fixes address the two games tested; demanding games may still slow down, glitch or crash. Sound is still experimental.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree each include internal checksums.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
