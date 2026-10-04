# NDS4MiSTer v0.9.0-rc.2

**Browse games and DS firmware on SD, USB, or network storage—and remember their folders.**

## What's new

- **Browse to your games.** Choose **Load *.NDS** and use `..` at the top to go up a folder. Keep going up to switch between mounted SD, USB, and network storage, then browse down to your games.
- **Your folders are remembered.** The game browser opens where you last left it, even after a reboot. No extra setting or Save settings step is needed.
- **Choose your DS firmware folder.** **Boot DS firmware** now opens a file browser too. Select `firmware.bin`, with `bios7.bin` and `bios9.bin` beside it. Its folder is remembered separately from your games.
- **Better handling of unavailable storage.** If a remembered drive or share is missing, you can retry or browse elsewhere. Slow folder reads can be cancelled without locking up the menu.

Earlier fixes and features carry over, including larger ROM support, Super Mario 64 DS graphics, personal firmware settings, TATE, touch input, saves, and movie playback. The FPGA core, renderer, and 1 GHz ARM clock setting are unchanged from rc.1.

## Install and play

1. Exit standalone through **System → Reboot**, then unzip to the root of your SD card and merge the **Scripts** folder. Include the hidden **Scripts/.NDS_Standalone** folder. If copying extracted files by hand, turn on "show hidden files."
2. Run **Scripts → NDS4MiSTer**.
3. Choose **Load *.NDS**. Use `..` to navigate to your game folder, then select an uncompressed `.nds` file.

At the device list, **fat** is the SD card. A mounted USB drive appears as **usb0**, **usb1**, and so on. Drives and network shares must already be mounted by MiSTer; this update does not configure networking or mount shares for you.

**Saves stay on the SD card in `saves/NDS`**, including when games are on USB or a network share. Keep each game's filename unchanged to use its existing save. The installer preserves your settings, controller maps, games, and `MiSTer.ini`.

The launcher needs a kernel with write-combining and 1 GHz clock control. Testing used **Linux 5.15.1-MiSTer**. No kernel is included. See **QUICK_START.txt** for requirements and troubleshooting.

## Optional: DS firmware

Normal games use the built-in BIOS and firmware. You only need your own files to open the original DS menu.

Keep these three files together in any browsable folder:

```text
bios7.bin
bios9.bin
firmware.bin
```

Choose **Boot DS firmware**, browse to that folder, and select **firmware.bin**. Tap the touch screen when prompted. Your nickname, birthday, favorite color, and language carry into games. The default nickname is **MiSTer**.

Original files stay untouched. Saved personal settings remain in **saves/NDS/firmware.bin** on the SD card. Compatible BIOS files and a **256 KiB DS or DS Lite firmware image** are required. Reference SHA-256 hashes and compatibility details are in **QUICK_START.txt**. Nintendo BIOS and firmware files are not included.

## Menu and TATE

Open the menu with your controller's menu combo, the board's OSD button, or **F12**. Press Right for System and Left to return. **The menu does not pause the game.** Use **System → Save settings** to keep display options; browser folders save automatically.

For portrait play, select **Video Layout → Top/Bottom** and rotate the picture opposite to the monitor: **90 CCW** for a clockwise monitor turn, **90 CW** for a counterclockwise turn.

To rotate the menu, edit the existing `[NDS]` section in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

Use `osd_rotate=1` if the menu is upside down. On a compatible 1080p display, `video_mode=8` gives a wider portrait picture. Return to normal MiSTer and relaunch after editing.

## Known issues

- **Physical USB/HDD and network-share testing is still needed.** SD browsing was tested on hardware; external-storage handling passed simulated tests.
- **Slowdown and uneven animation remain.** Not every game runs at 60 FPS, and movies or audio can hitch.
- **Shin Megami Tensei: Strange Journey** can freeze during its intro.
- **GTA: Chinatown Wars** can clip near the camera.
- **Firmware boot does not work with every dump.** Clock edits do not save between launches, and RTC alarms are not implemented.
- **Other games may glitch or crash.** Testing does not cover every game or full playthroughs.

## Files

The release assets are the install ZIP and its SHA-256 checksum. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion and skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
