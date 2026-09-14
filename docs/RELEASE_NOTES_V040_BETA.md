# NDS4MiSTer v0.4.0-beta

**Smoother in-game movies, plus TATE mode support.**

## What's new

- **Smoother movie playback.** The cutscenes that play at the start of many games run better, with fewer audio hitches in our Chrono Trigger and Castlevania testing. Occasional stutters can still happen.
- **TATE mode.** TATE is the arcade term for turning a monitor on its side. The core can now rotate its picture 90 degrees counterclockwise, so the stacked DS screens fit a portrait display. Rotation is Off by default — see **Setting up TATE** below.
- **Controls stay correct on a sideways monitor.** With the monitor turned clockwise and the picture rotated to match, D-pad, mouse, and touch controls keep their normal directions. Up is still up.
- **Earlier fixes carry over.** Optional Engine B, Chrono Trigger startup and sprite fixes, Kirby graphics, transparency, screen fades, colored text, touchscreen, sound, cartridge saves, and previous boot fixes are all retained.

## How to install

1. Back up your saves.
2. Unzip the install file to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, go to **Console → NDS_20260914** and choose **Load NDS**. If you miss the window, run Kickstart again.

Run Kickstart after every reboot, and again any time you come back to the NDS core. Use the core and the ARM helper that shipped together in this release. Do not mix versions.

## Setting up TATE

1. Turn your monitor 90 degrees clockwise.
2. In the core menu, select **Video Layout → Top/Bottom** so the two DS screens stack.
3. Set **Video Rotation → 90 CCW**.

The MiSTer menu (the OSD) does not follow the core's rotation, so it will still be sideways unless you rotate it separately. Add this section at the end of `MiSTer.ini` on your SD card:

```ini
[NDS]
osd_rotate=2
```

If you already have an `[NDS]` section, add or update `osd_rotate=2` there instead. Save the file and reboot. This rotates the menu counterclockwise for NDS only; it leaves other cores' menu settings alone. The installer does not edit `MiSTer.ini` for you.

## Turning on the second screen

Engine B is Off by default, which shows the same picture on both screens. Turning it On restores the true second screen. Set **Engine B (next Reset) → On**, then reset or reload your ROM to apply it. Demanding games can slow down with it enabled, and the second screen may lag behind.

## Known issues — read before you play

- **Movies and audio can still hitch.** Playback is smoother than before, but not yet flawless in every game.
- **Engine B costs speed.** See above. If a game gets choppy, turn it back Off, then reset or reload your ROM.
- **TATE only rotates counterclockwise.** There is no clockwise or 180-degree option yet, so the monitor has to be turned clockwise. Rotation also doesn't guarantee full-speed play, especially with Engine B on.
- **Pokémon SoulSilver and Platinum: your character and furniture can go invisible.** The fix we have costs too much speed and is still on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Sound is still experimental.** Demanding games may stutter, glitch, or crash.

## Files

Source code is available through GitHub's **Source code (zip)** and **Source code (tar.gz)** links. The install ZIP has a SHA-256 checksum, and both the installer and the source archive include checksums for the files inside them.

## Thanks

This core builds on CPU, graphics, sound, and compatibility work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Full credits and licenses are in the source archive.
