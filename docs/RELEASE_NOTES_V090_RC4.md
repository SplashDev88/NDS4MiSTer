# NDS4MiSTer v0.9.0-rc.4

**Fixed graphical corruption in Fire Emblem: Shadow Dragon.**

## What's new

- **Fixed a VRAM address-mapping bug.** Fixes graphical corruption in **Fire Emblem: Shadow Dragon**.

## Install and play

1. Exit standalone with **System → Reboot**, then unzip to the root of your SD card, merging the **Scripts** folder. The hidden **Scripts/.NDS_Standalone** folder has to come with it — turn on "show hidden files" if you're copying by hand.
2. Run **Scripts → NDS4MiSTer**.
3. Choose **Load \*.NDS**, browse to your games, and pick an uncompressed `.nds` file.

In the device list, **fat** is the SD card and USB drives show as **usb0**, **usb1** and so on. MiSTer has to have them mounted already — this update doesn't set up networking or mount shares for you.

**Saves stay on the SD card in `saves/NDS`**, even for games on USB or a share. Keep filenames unchanged to keep using existing saves. Your settings, controller maps, games and `MiSTer.ini` are left alone.

The launcher supports **Linux 6.18.38-MiSTer** and retains support for **5.15.1-MiSTer**, with the matching write-combining module and 1 GHz clock control. No kernel is included. See **QUICK_START.txt**.

## Optional: DS firmware

Games use the built-in BIOS and firmware. You only need your own files to open the original DS menu. Keep `bios7.bin`, `bios9.bin` and `firmware.bin` together in any browsable folder, choose **Boot DS firmware**, and select `firmware.bin` when the browser appears. Later visits boot directly from the remembered folder. Tap the touch screen when prompted.

Your nickname, birthday, favorite color and language carry into games; the default nickname is **MiSTer**. Your original files aren't modified — personal settings are saved to `saves/NDS/firmware.bin`. Requires compatible BIOS files and a **256 KiB DS or DS Lite firmware image**; hashes are in **QUICK_START.txt**. Nintendo files aren't included.

## Menu and TATE

Open the menu with your controller's menu combo, the OSD button, or **F12**. Right for System, Left to go back. **The menu doesn't pause the game.** **System → Save settings** keeps display options; browser folders save on their own.

For portrait, select **Video Layout → Top/Bottom** and rotate opposite the monitor: **90 CCW** for a clockwise turn, **90 CW** for counterclockwise. The menu rotates separately — set `osd_rotate=2` (or `1` if it's upside down) in the `[NDS]` section of `MiSTer.ini`, then relaunch. On a compatible 1080p display, `video_mode=8` gives a wider portrait picture.

## Known issues

- **USB, HDD and network shares haven't been tested on hardware.** SD browsing has; external storage passed simulated tests only.
- **Slowdown and uneven animation remain.** Not every game hits 60 FPS, and movies or audio can hitch.
- **Firmware boot doesn't work with every dump.** Clock edits don't persist between launches, and RTC alarms aren't implemented.
- **Shin Megami Tensei: Strange Journey** can freeze in its intro; **GTA: Chinatown Wars** can clip near the camera. Other games may glitch or crash — testing doesn't cover every game or full playthroughs.

## Files

The release assets are the install ZIP and its SHA-256 checksum. Matching source is in GitHub's **Source code (zip)** and **(tar.gz)** links.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion, and to skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
