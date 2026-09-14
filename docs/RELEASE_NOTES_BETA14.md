# NDS4MiSTer v0.3.0-beta.14

**Smoother FMV playback and TATE mode for a sideways monitor.**

## What's new

- **Smoother opening movies.** Movie playback has improved, with fewer audio hitches in our Chrono Trigger and Castlevania testing. Occasional stutters can still happen.
- **TATE mode.** Rotate the picture 90 degrees counterclockwise from the core menu. For a portrait setup, turn your monitor clockwise, select **Video Layout → Top/Bottom**, then set **Video Rotation → 90 CCW**. Rotation is Off by default.
- **Controls stay familiar.** D-pad, mouse, and touch controls keep their normal directions when using the physically rotated monitor.
- **Earlier fixes carry over.** Optional Engine B, Chrono Trigger startup and sprite fixes, Kirby graphics, transparency, screen fades, colored text, touchscreen, sound, cartridge saves, and previous boot fixes are retained.
- **Still stock speed.** The ARM processor runs at 1 GHz. No overclock.

## Known issues — read before you play

- **Movies and audio can still hitch occasionally.** Playback is smoother, but full-speed playback in every game is still a work in progress.
- **Engine B can slow games down.** It is Off by default, which copies Engine A to both screens. On restores the second graphics engine, but demanding games can slow down and the second screen may lag. Change **Engine B (next Reset)**, then reset or reload your ROM to apply it.
- **TATE currently supports 90 CCW only.** The MiSTer menu has its own rotation setting; rotating the game does not rotate the menu automatically. TATE does not guarantee full-speed gameplay with both engines enabled.
- **Pokémon SoulSilver and Platinum: your character and furniture can go invisible.** The existing fix costs too much speed and remains on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Sound is still experimental.** Demanding games may stutter, glitch, or crash.

## How to install

1. Back up your saves.
2. Unzip the install file to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, go to **Console → NDS_20260914** and choose **Load NDS**. If you miss the window, run Kickstart again.
6. Want both graphics engines? Set **Engine B (next Reset) → On**, then reset or reload your ROM.
7. Using a sideways monitor? Turn it clockwise, select **Video Layout → Top/Bottom**, then set **Video Rotation → 90 CCW**.

Run Kickstart after every reboot and before returning to the NDS core. Use the core and ARM helper supplied together in this release.

Source code is available through GitHub's **Source code (zip)** and **Source code (tar.gz)** links. The install ZIP has a SHA-256 checksum, and both the installer and source include checksums for their files.

## Thanks

This core builds on CPU, graphics, sound, and compatibility work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Full credits and licenses are in the source archive.
