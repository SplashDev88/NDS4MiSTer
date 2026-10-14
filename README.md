# NDS4MiSTer

**Beta v0.9.0-rc.7-split.8.6: controller mapping fixes, a persistent DS game clock, and independent analog/digital displays.**

[Releases and previous stable version](https://github.com/SplashDev88/NDS4MiSTer/releases) · [Quick start](docs/STANDALONE_QUICK_START.txt)

## What's new

- **Controller mapping waits for release.** Held or jittering triggers cannot skip successive prompts. Cancel and disconnect retain the previous map.
- **RTC / game clock.** Games and DS firmware share MiSTer local time. DS clock edits persist and include elapsed time between launches.
- **Independent displays.** Analog uses one native 240p Main/Touch screen; digital has its own layout and Direct Video target.

- **Stable native CRT video.** Fixes the alternating frame length that caused vertical shaking. Native CRT output now uses a fixed 262-line frame at approximately 59.64 Hz.
- **DV1 verified on RetroTINK-4K.** Direct HDMI video and stereo audio passed with New Super Mario Bros. Use a direct connection when troubleshooting; a splitter in the test setup prevented DV1 from locking.
- **All display and gameplay features retained.** 3D FPS, TATE and menu rotation, HDMI scaling, scaled VGA, RGB/component, composite/S-video, Screen Peek, synthetic microphone blowing and lid sleep/wake remain available.

## Install and play

This beta updates the normal standalone installation. Before updating, back up `Scripts/NDS4MiSTer.sh`, the entire hidden `Scripts/.NDS_Standalone` folder, `saves/NDS`, and `config/NDS_storage.cfg`. See [upgrade and rollback](docs/STANDALONE_INSTALL_README.md).

1. Exit standalone with **System → Reboot**, then unzip to the root of your SD card, merging the **Scripts** folder. The hidden **Scripts/.NDS_Standalone** folder has to come with it — turn on "show hidden files" if you're copying by hand.
2. Run **Scripts → NDS4MiSTer**.
3. Choose **Load \*.NDS**, browse to your games, and pick an uncompressed `.nds` file.

In the device list, **fat** is the SD card and USB drives show as **usb0**, **usb1** and so on. MiSTer has to have them mounted already — this update doesn't set up networking or mount shares for you.

**Saves stay on the SD card in `saves/NDS`**, even for games on USB or a share. Keep filenames unchanged to keep using existing saves. Your settings, controller maps, games and `MiSTer.ini` are left alone.

The launcher supports **Linux 6.18.38-MiSTer** and retains support for **5.15.1-MiSTer**, with the matching write-combining module and 1 GHz clock control. No kernel is included. See [QUICK_START.txt](docs/STANDALONE_QUICK_START.txt).

## Optional: DS firmware

Games use the built-in BIOS and firmware. You only need your own files to open the original DS menu. Keep `bios7.bin`, `bios9.bin` and `firmware.bin` together in any browsable folder, choose **Boot DS firmware**, and select `firmware.bin` when the browser appears. Later visits boot directly from the remembered folder. Tap the touch screen when prompted.

Your nickname, birthday, favorite color and language carry into games; the default nickname is **MiSTer**. Your original files aren't modified — personal settings are saved to `saves/NDS/firmware.bin`. Requires compatible BIOS files and a **256 KiB DS or DS Lite firmware image**; hashes are in [QUICK_START.txt](docs/STANDALONE_QUICK_START.txt). Nintendo files aren't included.

## Menu and TATE

Open the menu with your controller's menu combo, the OSD button, or **F12**. Right for System, Left to go back. **The menu doesn't pause the game.** **System → Save settings** keeps display options; browser folders save on their own.

For portrait, select **Digital Layout → Top/bottom** and use **Display options → Video Rotation** opposite the monitor: **90 CCW** for a clockwise turn, **90 CW** for counterclockwise. The HDMI menu follows Video Rotation automatically; the native analog/CRT menu remains upright. The old `osd_rotate` and private menu-rotation override no longer control this frontend. On a compatible 1080p display, `video_mode=8` gives a wider portrait picture.

Games and DS firmware share the game clock, seeded from the MiSTer's local time. Date/time edits in DS firmware persist across launches and continue while powered off. See [clock behavior](docs/GAME_CLOCK.md).

## CRT and DV1 setup

Native analog automatically uses **240p**; select **Analog Screen: Main/Touch**. HDMI/DV1 has its own **Digital Layout**. For Direct Video through HDMI, **Display options → Direct Video Target: CRT** (default) limits that output to one 240p screen; choose **Scaler** for a RetroTINK or other compatible scaler to enable all four layouts. The same target is available under **F4: Advanced Options** during script startup. Older CRT-Off settings activate independent output at startup. Keep the MiSTer profile appropriate to your cable and hardware; the package does not edit `MiSTer.ini` or `yc.txt`.

On **SuperStation One composite or S-Video using its FPGA encoder**, keep **switch 3 UP** and use the **SVID profile**. That profile uses `vga_mode=svideo` for the SS1 composite socket too. Composite color was confirmed on SuperStation One with rc.6; this build retains the encoder but has not been physically requalified on that setup. See [Quick start](docs/STANDALONE_QUICK_START.txt) for component, RGB/VGA, and external-encoder guidance.

For **DV1**, connect HDMI to the RetroTINK-4K and use `direct_video=1`, `dvi_mode=0`, and `vga_scaler=0` in the active NDS profile. Exit to normal MiSTer and relaunch after INI changes. DV1 video and stereo audio passed on RetroTINK-4K with a direct HDMI connection. A splitter in the test setup prevented lock; bypass splitters when troubleshooting. Native outputs use the receiver's rotation, rather than the HDMI scaler's Video Rotation.

Main on HDMI and Touch on native VGA can run independently. Digital Main, Touch, Side-by-side and Top/bottom remain available while analog shows one 240p screen. Explicit `vga_scaler=1` continues to mirror the HDMI scaler for computer monitors.

If a game shows a black screen, try **Analog Screen: Main/Touch**, **Digital Layout: Main/Touch**, or hold **Screen Peek / F10**. Some games deliberately leave one DS screen blank. Native output is approximately **59.64 Hz**; a PAL television must accept that timing. This is not a 50 Hz PAL mode.

## Known issues

- **Experimental FPGA timing.** Routing and bounded hardware tests passed, but static timing still reports violations. Longer sessions and additional boards remain unqualified.

- **Display validation is limited.** RGBS240p, direct HDMI DV1, HDMI/TATE/menu rotation and scaled RGBHV VGA passed on RetroTINK-4K. Physical CRT acceptance and composite/S-video requalification on this build remain pending. See the release notes for receiver mode-switching behavior.
- **USB/HDD testing is limited.** SD browsing and a mounted CIFS network share have been exercised on hardware; external-drive behavior also has simulated coverage.
- **Slowdown and uneven animation remain.** Not every game hits 60 FPS, and movies or audio can hitch.
- **Firmware boot doesn't work with every dump.** RTC alarm interrupts are not implemented.
- **Shin Megami Tensei: Strange Journey** can freeze in its intro; **GTA: Chinatown Wars** can clip near the camera. Other games may glitch or crash — testing doesn't cover every game or full playthroughs.

## Files

The release assets are the install ZIP and its SHA-256 checksum. Matching source is in GitHub's **Source code (zip)** and **(tar.gz)** links.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion, and to skmp, the DreamSTer developer. Full credits and licenses are in the source tree.

The archive contains the matching split.8.6 FPGA and ARM host. The renderer and 1 GHz ARM setting are retained. Keep the files from one release together.

## More information

- [Release notes](docs/RELEASE_NOTES_SPLIT86.md)
- [Developer guide](docs/DEVELOPMENT.md)
- [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues)

## License

NDS4MiSTer is distributed under GPLv3; see [LICENSE.txt](LICENSE.txt). The write-combining kernel module is [GPL-2.0](kernel/nds_mem_wc/COPYING). Vendored components retain their own licenses and notices.
