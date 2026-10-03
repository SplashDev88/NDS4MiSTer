# NDS4MiSTer

**v0.9.0-rc.1 — New standalone launcher, support for 512 MiB games, and the original DS firmware menu.**

[Download v0.9.0-rc.1](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.1) · [Quick start](docs/STANDALONE_QUICK_START.txt)

This is a release candidate. Many games are playable, but graphics, sound, and compatibility still have rough edges.

## What's changing

**Launch from Scripts → NDS4MiSTer.** One step now starts the core, the ARM helper, and the NDS menu. Kickstart is gone.

Standalone mode shuts down the normal MiSTer program while you play. That frees ARM time for the core. **System → Reboot** returns you to the normal MiSTer menu without power-cycling the board.

All future releases will use the standalone launcher. Your older NDS core and Kickstart setup still work, but they are no longer supported. Your games, saves, and settings stay where they are.

## What's new

- **Larger games load.** The loader now handles supported 256 MiB and 512 MiB ROMs. **Kingdom Hearts: 358/2 Days** and **Pokémon White 2** worked in testing. Not every large game will work, and DSi mode is not supported.
- **Boot the DS firmware menu.** Choose **Boot DS firmware** to open the original DS interface. You must supply your own BIOS and firmware files.
- **Your nickname follows you into games.** Set your nickname, birthday, favorite color, and language in the DS settings. The default nickname is **MiSTer**.
- **Super Mario 64 DS fixed.** The first course no longer collapses into a horizontal line.
- **Smoother rendering.** Less repeated drawing work means better pacing. Speed still varies by game and scene.
- **Switch screen layouts on the fly.** Map **Cycle Video Layout**, the last option in **Define NDS buttons**, to a spare button.
- **Network loading is more forgiving.** Slow reads from a CIFS share no longer trigger a timeout. A fully stalled load still times out.

Earlier fixes carry over, including touch input, cartridge saves, both TATE directions, and smoother movie playback. The Engine B On/Off option is gone. The ARM processors stay overclocked at **1 GHz**.

## Install and play

1. Exit standalone, then unzip the install ZIP to the root of your SD card and merge the **Scripts** folder. Make sure the hidden **Scripts/.NDS_Standalone** folder copies over. If you copy files by hand, turn on "show hidden files."
2. Open **Scripts → NDS4MiSTer** and wait for the NDS menu.
3. Choose **Load *.NDS** and pick an uncompressed game from `games/NDS`.
4. Use **System → Save settings** to keep your display options.

New installs default to **Top/Bottom** with rotation off. Existing settings take priority. Saves go in `saves/NDS`.

The launcher needs a kernel with write-combining and 1 GHz clock control. We tested on **Linux 5.15.1-MiSTer**. The installer does not change your kernel or your INI. If the launcher reports a missing requirement, see [QUICK_START.txt](docs/STANDALONE_QUICK_START.txt).

## Optional: DS firmware

You do not need these files to play games. To boot the DS menu, place your own files in `games/NDS`:

```text
games/NDS/bios7.bin
games/NDS/bios9.bin
games/NDS/firmware.bin
```

**SHA-256 hashes of the files used for testing:**

```text
ba65f690eb04ec92db67c0e299e21ad71de087d6d5de8a9cb17a62eaab563c17  bios7.bin
1693983a7707ae394786fa526c0552457888a51d4e410d715ef07acd5a540555  bios9.bin
330c59198faec64b40e96cc875b422d340fc9ab1a9e32e9bd9b7baa1dbe6ba7f  firmware.bin
```

Check the original files in `games/NDS`. Firmware revisions and personal settings can change the firmware hash, so a different hash does not automatically mean the file is incompatible. The saved copy in `saves/NDS/firmware.bin` is expected to change when you edit your settings.

Choose **Boot DS firmware** and tap the touch screen when prompted. Change your personal details in DS settings, then start games through **Load *.NDS**.

Your original files are never modified. Changes save to **saves/NDS/firmware.bin**.

Firmware boot is experimental. It needs a **256 KiB DS or DS Lite firmware image** and supported BIOS files. Some dumps and touch-calibration settings do not work yet.

## Menu and TATE

Open the menu with your controller's menu combo, the board's OSD button, or **F12**. Press Right for System and Left to go back. **The menu does not pause the game.** Greyed-out options are not built yet.

For portrait play, set **Video Layout → Top/Bottom**. Rotate the picture opposite to the monitor: **90 CCW** if you turned the monitor clockwise, **90 CW** if you turned it counterclockwise.

To rotate the menu, edit your existing `[NDS]` section in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If the menu is upside down, use `osd_rotate=1`. On a 1080p display, adding `video_mode=8` gives a wider portrait picture. Return to normal MiSTer and relaunch for changes to take effect.

## Known issues

- **Slowdown and uneven animation.** Not every game runs at 60 FPS.
- **Movies and audio can hitch.** Sound is still experimental.
- **Shin Megami Tensei: Strange Journey** can freeze during its intro.
- **GTA: Chinatown Wars** can clip near the camera.
- **Firmware boot does not work with every dump.** Clock edits do not save between launches, and RTC alarms are not implemented.
- **Other games may glitch or crash.** We have not tested every game or full playthroughs.

## Files

Download the install ZIP and its SHA-256 checksum from the [release page](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.1). Use the install ZIP to play; the **Source code (zip)** and **(tar.gz)** links contain the matching source.

## More information

- [Release notes](docs/RELEASE_NOTES_V090_RC1.md)
- [Quick start and troubleshooting](docs/STANDALONE_QUICK_START.txt)
- [Developer guide, build instructions, and detailed compatibility notes](docs/DEVELOPMENT.md)
- [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues) — include the game, version, scene, and steps to reproduce.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion and skmp, the DreamSTer developer. Full credits and licenses are in the source tree.

## License

NDS4MiSTer is distributed under GPLv3; see [LICENSE.txt](LICENSE.txt). The write-combining kernel module is [GPL-2.0](kernel/nds_mem_wc/COPYING). Vendored components retain their own licenses and notices.
