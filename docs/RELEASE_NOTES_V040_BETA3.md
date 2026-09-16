# NDS4MiSTer v0.4.0-beta.3

**Faster 3D graphics transfers with write-combining memory.**

## What's new

**Faster 3D.** Every frame, the ARM processor has to hand its finished 3D graphics over to the FPGA, and that hand-off has been one of the core's biggest bottlenecks. A new memory mode called write-combining batches those writes together instead of sending them one at a time. Expect a solid speed-up in 3D-heavy games, though how much depends on the game.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS\_Kickstart**.
5. Within five minutes, open **Console → NDS\_20260916** and choose **Load NDS**. Miss the window and you'll need to run Kickstart again.

Run Kickstart after every reboot and any time you return to the NDS core. Use the core and ARM helper that shipped together here.

## TATE setup

Turn your monitor to portrait, then select **Video Layout → Top/Bottom**. Set **Video Rotation** to the opposite direction from the monitor: **90 CCW** if it turned clockwise, **90 CW** if it turned counterclockwise. Once they match, D-pad, mouse, and touch all move the way the screen looks.

The MiSTer menu rotates separately, in `MiSTer.ini` on your SD card. Add this at the end of the file:
```ini
[NDS]
osd_rotate=2
```

If the menu comes out upside down, switch to `osd_rotate=1`. Edit the `[NDS]` section if you already have one, then save and reboot. Keeping it under `[NDS]` leaves the menu normal in every other core. The installer won't edit your INI for you. ([MiSTer INI docs](https://mister-devel.github.io/MkDocs_MiSTer/advanced/ini/))

## Second screen

Engine B is Off by default, showing the same picture on both screens. Set **Engine B (next Reset) → On** and reset or reload your ROM for the real second screen. Demanding games can slow down with it on, and the second screen may lag.

## Known issues

- **Shin Megami Tensei: Strange Journey can still freeze in the intro.** This update doesn't fix it.
- **Movies and audio can still hitch** — smoother than before, not flawless.
- **Engine B costs speed.** If a game gets choppy, turn it Off and reset.
- **Pokémon SoulSilver and Platinum:** your character and furniture can go invisible. The fix costs too much speed and is on hold ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Sound is experimental.** Demanding games may stutter, glitch, or crash.

## Files

Source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The install ZIP has a SHA-256 checksum, and both archives include checksums for the files inside.

## Thanks

Built on CPU, graphics, sound, and compatibility work from the MiSTer community, FPGAzumSpass, the Nitro\_DarkSide and melonDS contributors, heni, and InsaneFriend. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source archive.
