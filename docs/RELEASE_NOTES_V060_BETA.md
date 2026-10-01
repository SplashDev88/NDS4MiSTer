# NDS4MiSTer v0.6.0-beta

**A new standalone launcher, a familiar NDS menu, and improved game pacing.**

> Draft for review. This release has not been published.

## Read this first

**Start this release from Scripts → NDS Standalone.** You no longer need to run Kickstart separately or launch an NDS core from Console. There is no five-minute window.

Standalone uses a lightweight NDS menu in place of the normal MiSTer program while you play. This leaves more ARM processor time available for the game. Your normal MiSTer installation stays in place: **System → Reboot** returns to the usual MiSTer menu.

Standalone is the direction for future NDS4MiSTer development. This installer keeps your existing NDS release, settings and files intact, so you can still use the version you already have.

## What's new

- **One script to launch.** NDS Standalone starts the matching core and ARM helper together, then opens the NDS menu. Choose **Load NDS** to play.
- **Improved pacing and less repeated drawing work.** This is the build we preferred in testing, including New Super Mario Bros. and Castlevania. Speed still depends on the game and scene; this is not a promise of 60 FPS everywhere.
- **Super Mario 64 DS graphics fixed.** The first course no longer collapses into a horizontal line in our tested version.
- **Familiar menus and controls.** Core options, button mapping, Recent Files and the ROM loading bar follow the MiSTer layout. Press Right for the System page and Left to return.
- **More reliable network ROM loading.** After you choose a ROM, slow network reads no longer make the launcher think it has frozen and return to MiSTer after 20 seconds. Loading can take longer, provided file data keeps arriving. It stops after two minutes without progress.
- **A button to switch layouts.** The last option in **Define NDS buttons** is **Cycle Video Layout**. Assign a spare button to switch layouts while playing.
- **Your saves carry over.** Standalone uses the same `games/NDS` and `saves/NDS` folders as the normal core. Your controller maps and standalone settings are kept separate.

Earlier game fixes, both TATE directions, touch input and cartridge saves are retained. The ARM processor runs at **1 GHz**, with write-combining enabled. There is no 1.2 GHz overclock.

## Install and play

1. Back up `saves/NDS` on your SD card.
2. Unzip the install file to the root of the SD card, merging the **Scripts** folder. Copy its hidden support folder too.
3. Open **Scripts → NDS Standalone**. Wait for the NDS menu to appear.
4. Choose **Load NDS**. A fresh installation starts with both screens On in **Top/Bottom** layout. If you have older saved settings, check that **Engine B (next Reset)** is **On** for two independent screens.
5. Choose a game from `games/NDS`. Use an uncompressed `.nds` file, up to **128 MiB**.

Use this script each time you want to start standalone. It includes its own matching core and helper; don't mix its support files with another version. It does not change your `MiSTer.ini` or install a different Linux kernel.

The launcher requires **Python 3.8 or newer** and a MiSTer kernel that supports the included write-combining module and 1 GHz clock control. This build was tested with **Linux 5.15.1-MiSTer**. If the launcher reports a missing requirement, see the bundled **QUICK_START.txt**.

## Using the menu

Open the menu with your controller's usual menu combination, the MiSTer's OSD button, or **F12**. New controllers can use Select + Start or the Guide button, then **System → Define NDS buttons**.

Use **System → Save settings** to keep your options for the next launch. For Recent Files, highlight **Load NDS** and press the controller's Select button or the keyboard's backtick key.

**Greyed-out System options are not implemented yet.** Use normal MiSTer for video/audio filters, Bluetooth pairing and other global settings. **Opening the NDS menu does not pause the game.**

To return to normal MiSTer, choose **System → Reboot**. Despite its familiar name, this returns to the MiSTer menu; it does not power-cycle the board. Your old NDS release still uses its own Kickstart and Console launch steps.

## Second screen

**Engine B On** draws both DS screens separately and is recommended for normal play. **Off** duplicates the first screen and leaves out anything drawn only by the second engine. It may help speed in some games, but the gain varies.

Reset or reload the game after changing Engine B. If both screens show the same picture, turn it On and reload. Existing NDS settings take priority on first use; standalone saves its own settings separately afterward. With no existing settings, rotation and the FPS counter start Off.

## TATE setup

Choose **Video Layout → Top/Bottom**, then set **Video Rotation** opposite to the way your monitor physically turns: **90 CCW** for a clockwise turn, or **90 CW** for a counterclockwise turn. D-pad, mouse and touch directions follow the rotated picture.

The menu rotates separately. For a 1080p display in portrait orientation, this optional `MiSTer.ini` setup gave us a wider picture with small borders:

```ini
[NDS]
video_mode=8
osd_rotate=2
```

`video_mode=8` selects 1080p at 60 Hz. Use it only if your display supports that mode. If the menu is upside down, change `osd_rotate` to `1`. Edit the existing `[NDS]` section rather than adding a second one, then return to normal MiSTer and relaunch standalone.

This keeps the change to NDS; it also applies when you use the older normal NDS core. The installer leaves your INI alone. TATE uses whole-pixel scaling, so small borders are expected.

## Known issues

- **Slowdown and uneven animation remain.** The tested USA version of New Super Mario Bros. uses fewer drawing updates to help game pacing. Other versions may behave differently. The **3D FPS Counter** is a counter, not a speed setting or a guarantee of 60 FPS gameplay.
- **Network folder browsing can still stall.** The loading fix covers a selected ROM. Opening network folders or checking Recent Files can still hang on an unresponsive share and return you to MiSTer. Copying games to the SD card's `games/NDS` folder avoids these network delays.
- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **GTA: Chinatown Wars can still show occasional clipping near the camera.**
- **Movies and audio can still hitch.** Sound remains experimental, and other games may have graphics problems, slow down or crash.
- **The System menu is not a complete replacement for every MiSTer feature.** Unavailable options are greyed out. Some controller setups, alternate INI configurations and display changes still need more testing.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree include internal checksums.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion and skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
