# NDS4MiSTer v0.4.0-beta.1

**TATE now rotates in either direction, with the smoother movie playback from v0.4.0-beta retained.**

## What's new

- **Clockwise TATE rotation.** The core menu now offers **Video Rotation → Off / 90 CCW / 90 CW**, so you can match a monitor that turns either way. Rotation is Off by default and can be changed without resetting the game.
- **Your existing rotation settings carry over.** Saved Off and 90 CCW settings keep their previous meaning.
- **Smoother movie playback carries over.** The Chrono Trigger and Castlevania movie/audio improvements from v0.4.0-beta are retained. Occasional hitches can still happen.
- **Earlier fixes carry over.** Optional Engine B, Chrono Trigger startup and sprite fixes, Kirby graphics, transparency, screen fades, colored text, touchscreen, sound, cartridge saves, and previous boot fixes are retained.
- **Processor speed is unchanged.** The release uses the same ARM helper as v0.4.0-beta at a stock 1 GHz. No overclock.

## How to install

1. Back up your saves.
2. Unzip the install file to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, go to **Console → NDS_20260914** and choose **Load NDS**. If you miss the window, run Kickstart again.

Run Kickstart after every reboot, and again any time you come back to the NDS core. Use the core and ARM helper supplied together in this release.

## Setting up TATE

1. Turn your monitor to portrait orientation.
2. Select **Video Layout → Top/Bottom** so the two DS screens stack.
3. Choose the picture rotation that matches your setup:

| Your monitor physically turns | Set Video Rotation to |
| --- | --- |
| Clockwise / right | **90 CCW** |
| Counterclockwise / left | **90 CW** |

The picture rotates in the opposite direction to the monitor. D-pad, mouse, and touch controls keep their normal directions when the monitor and picture rotations match.

The MiSTer menu rotates separately. To match **90 CW**, add this section at the end of `MiSTer.ini`:

```ini
[NDS]
osd_rotate=1
```

For **90 CCW**, use `osd_rotate=2` instead. If an `[NDS]` section already exists, update the setting there. Save and reboot. This applies the menu setting to NDS only; the installer does not edit your INI file. See the [MiSTer INI documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/ini/#menu-settings).

## Turning on the second screen

Engine B is Off by default, which shows the same picture on both screens. Set **Engine B (next Reset) → On**, then reset or reload your ROM for the true second screen. Demanding games can slow down with it enabled, and the second screen may lag behind.

## Known issues

- **Movies and audio can still hitch.** Playback is smoother than earlier releases, but not flawless in every game.
- **Engine B costs speed.** If a game gets choppy, turn it Off, then reset or reload your ROM.
- **TATE has no 180-degree option yet.** Rotation also does not guarantee full-speed gameplay, especially with Engine B On.
- **Pokémon SoulSilver and Platinum: your character and furniture can go invisible.** The available fix costs too much speed and remains on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Sound is still experimental.** Demanding games may stutter, glitch, or crash.

## Files

Source code is available through GitHub's **Source code (zip)** and **Source code (tar.gz)** links. The install ZIP has a SHA-256 checksum, and both the installer and source archive include checksums for the files inside them.

## Thanks

This core builds on CPU, graphics, sound, and compatibility work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Full credits and licenses are in the source archive.
