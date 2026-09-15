# NDS4MiSTer v0.4.0-beta.2

**Stability fixes.**

## What's new

- **Stability fixes.**

## How to install

1. Back up your saves.
2. Unzip the install file to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Within five minutes, go to **Console → NDS_20260915** and choose **Load NDS**. If you miss the window, run Kickstart again.

Run Kickstart after every reboot, and again any time you come back to the NDS core. Use the core and the ARM helper that shipped together in this release.

## Setting up TATE

1. Turn your monitor to portrait orientation.
2. Select **Video Layout → Top/Bottom** so the two DS screens stack.
3. Set **Video Rotation** to match. The picture has to rotate the opposite way from the monitor:

| If your monitor turns | Set Video Rotation to |
| --- | --- |
| Clockwise (to the right) | **90 CCW** |
| Counterclockwise (to the left) | **90 CW** |

Once the two match, the D-pad, mouse, and touch controls all move the way the screen looks.

The MiSTer menu doesn't follow the core's rotation — you set that separately in `MiSTer.ini` on your SD card. Add a menu rotation setting under `[NDS]`, for example:

```ini
[NDS]
osd_rotate=2
```

If the menu is upside down, use `osd_rotate=1` instead. If an `[NDS]` section is already there, edit that one instead of adding a second. Save the file and reboot. Putting the setting under `[NDS]` keeps it to this core, so the menu stays normal everywhere else. The installer won't touch your INI file. ([MiSTer INI documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/ini/))

## Turning on the second screen

Engine B is Off by default, which shows the same picture on both screens. Set **Engine B (next Reset) → On**, then reset or reload your ROM to get the true second screen. Demanding games can slow down with it enabled, and the second screen may lag behind.

## Known issues

- **Movies and audio can still hitch.** Playback is smoother than earlier releases, but not flawless in every game.
- **Engine B costs speed.** If a game gets choppy, turn it Off, then reset or reload your ROM.
- **Pokémon SoulSilver and Platinum: your character and furniture can go invisible.** The fix we have costs too much speed and is still on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Sound is still experimental.** Demanding games may stutter, glitch, or crash.

## Files

Source code is available through GitHub's **Source code (zip)** and **Source code (tar.gz)** links. The install ZIP has a SHA-256 checksum, and both the installer and the source archive include checksums for the files inside them.

## Thanks

This core builds on CPU, graphics, sound, and compatibility work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend. Full credits and licenses are in the source archive.
