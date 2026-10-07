# NDS4MiSTer v0.9.0-rc.6

**Screen Peek, CRT/analog video, composite color, experimental DV1, and display/control improvements.**

## What's new

- **Screen Peek.** In **Left Only**, **Right Only**, or CRT Mode, hold **F10** or a mapped **Screen Peek** button to see the other DS screen. Release to return. Two-screen layouts are unaffected. Add the optional binding under **System → Define NDS buttons**; existing mappings remain valid.
- **CRT and analog video.** Adds native RGB/component output and the composite/S-Video encoder. **CRT Mode: On** selects one DS screen centered in a 320×240 picture; **CRT Screen** below it switches Main/Touch. This changes the picture on HDMI too; it does not switch the analog port on or off. Composite color is confirmed on SuperStation One.
- **Experimental DV1 / Direct Video.** Adds the native video path and display metadata for receivers such as the RetroTINK-4K. Physical RetroTINK-4K testing is still pending.
- **Menus that follow the display.** The HDMI menu and loading dialogs follow **Video Rotation**, while the native CRT menu stays upright. No separate `osd_rotate` adjustment is needed. CRT controls are grouped below 3D FPS Counter with a blank separator.
- **3% right-stick dead zone.** Small center drift no longer repeatedly reveals the touch crosshair. This complements the existing DualSense gyro events and trigger-mapping fixes.
- Retains rc.5 lid open/close, hold-to-blow microphone, independent touch rotation, current-game ROM highlighting, and the rc.4 Fire Emblem graphics fix.

The renderer, performance settings and 1 GHz clock are unchanged. Fresh settings keep CRT Mode off; existing settings take priority.

## Install and play

1. If the core is already running, exit with **System → Reboot**. Then unzip to the root of your SD card, merging the **Scripts** folder. The hidden **Scripts/.NDS_Standalone** folder has to come with it — turn on "show hidden files" if you're copying by hand.
2. Run **Scripts → NDS4MiSTer**.
3. Choose **Load \*.NDS**, browse to your games, and pick an uncompressed `.nds` file.

In the device list, **fat** is the SD card and USB drives show as **usb0**, **usb1** and so on. MiSTer has to have them mounted already — this release doesn't set up networking or mount shares for you.

**Saves stay on the SD card in `saves/NDS`**, even for games on USB or a share. Keep filenames unchanged to keep using existing saves. Your settings, controller maps, games and `MiSTer.ini` are left alone.

The launcher supports **Linux 6.18.38-MiSTer** and retains support for **5.15.1-MiSTer**, with the matching write-combining module and 1 GHz clock control. No kernel is included. See **QUICK_START.txt**.

## Optional: DS firmware

Games use the built-in BIOS and firmware. You only need your own files to open the original DS menu. Keep `bios7.bin`, `bios9.bin` and `firmware.bin` together in any browsable folder, choose **Boot DS firmware**, and select `firmware.bin` when the browser appears. Later visits boot directly from the remembered folder. Tap the touch screen when prompted.

Your nickname, birthday, favorite color and language carry into games; the default nickname is **MiSTer**. Your original files aren't modified — personal settings are saved to `saves/NDS/firmware.bin`. Requires compatible BIOS files and a **256 KiB DS or DS Lite firmware image**; hashes are in **QUICK_START.txt**. Nintendo files aren't included.

## Menu and TATE

Open the menu with your controller's menu combo, the OSD button, or **F12**. Right for System, Left to go back. **The menu doesn't pause the game.** **System → Save settings** keeps display options; browser folders save on their own.

For portrait, select **Video Layout → Top/Bottom** and rotate opposite the monitor: **90 CCW** for a clockwise turn, **90 CW** for counterclockwise. Leave **Touch Rotation** on **Normal** when using a physically rotated monitor. The HDMI menu follows Video Rotation automatically; the native analog/CRT menu remains upright. The old `osd_rotate` and private menu-rotation override no longer control this frontend. On a compatible 1080p display, `video_mode=8` gives a wider portrait picture.

## CRT and DV1 setup

For a CRT, use **CRT Mode: On** and select **CRT Screen: Main/Touch**. Keep the MiSTer profile appropriate to your cable and hardware; the package does not edit `MiSTer.ini` or `yc.txt`.

On **SuperStation One composite or S-Video using its FPGA encoder**, keep **switch 3 UP** and use the **SVID profile**. That profile uses `vga_mode=svideo` for the SS1 composite socket too. Composite color was confirmed on SuperStation One with an NTSC CRT. See **QUICK_START.txt** for component, RGB/VGA, and external-encoder guidance.

For **DV1**, connect HDMI to the RetroTINK-4K and use `direct_video=1`, `dvi_mode=0`, and `vga_scaler=0` in the active NDS profile. Exit to normal MiSTer and relaunch after INI changes. DV1 is experimental and has not yet been physically tested on a RetroTINK-4K. Native outputs use the receiver's rotation, rather than the HDMI scaler's Video Rotation.

Separate Main-on-HDMI and Touch-on-VGA output is not implemented. Both ports share the selected DS picture; their menus can have different orientations.

## Known issues

- **Display validation is limited.** Composite color is user-confirmed on SuperStation One; Castlevania and NSMB boot checks passed on the new FPGA. Other analog hardware and DV1 still need physical testing.
- **USB/HDD testing is limited.** SD browsing and a mounted CIFS network share have been exercised on hardware; external-drive behavior also has simulated coverage.
- **Slowdown and uneven animation remain.** Not every game hits 60 FPS, and movies or audio can hitch.
- **Firmware limitations.** Firmware boot doesn't work with every dump, clock edits don't persist between launches, and RTC alarms aren't implemented.
- **Shin Megami Tensei: Strange Journey** can freeze in its intro; **GTA: Chinatown Wars** can clip near the camera. Other games may glitch or crash — testing doesn't cover every game or full playthroughs.

## Files

The release assets are the install ZIP and its SHA-256 checksum. Matching source is in GitHub's **Source code (zip)** and **(tar.gz)** links.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion, and to skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
