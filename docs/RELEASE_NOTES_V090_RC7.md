# NDS4MiSTer v0.9.0-rc.7

**Stable native 240p output, tested DV1, and full display features retained.**

## What's changed

- **Stable native CRT video.** Fixes the alternating frame length that caused vertical shaking. Native CRT output now uses a fixed 262-line frame at approximately 59.64 Hz.
- **DV1 verified on RetroTINK-4K.** Direct HDMI video and stereo audio passed with New Super Mario Bros. Use a direct connection when troubleshooting; a splitter in the test setup prevented DV1 from locking.
- **All display and gameplay features retained.** 3D FPS, TATE and menu rotation, HDMI scaling, scaled VGA, RGB/component, composite/S-video, Screen Peek, synthetic microphone blowing and lid sleep/wake remain available.
- Temporary FPGA diagnostic probes are removed. The scaler arithmetic refactor preserves its output and pipeline. Gameplay clocks, renderer, performance settings and the 1 GHz ARM clock are unchanged.

This release packages the exact FPGA, host and renderer binaries tested on the hardware rig. The unchanged host still displays **rc.6** in its compiled version label; the release manifest and launcher identify **rc.7**. This does not affect the new FPGA fixes.

## Install

1. Exit a running standalone session with **System → Reboot**.
2. Extract the ZIP to the SD card root, merging **Scripts** and including the hidden **Scripts/.NDS_Standalone** folder.
3. Run **Scripts → NDS4MiSTer** and choose **Load *.NDS**.

Merge the files instead of replacing the entire Scripts folder. Games, saves, controller maps, saved display options and `MiSTer.ini` are preserved. Saves remain in `saves/NDS` on the SD card; keep ROM filenames unchanged to use the matching saves. No ROMs, BIOS/firmware dumps, personal settings or controller maps are bundled.

Linux **6.18.38-MiSTer** and **5.15.1-MiSTer** remain supported with their matching modules. No kernel is included. Fresh settings start with CRT Mode Off; existing settings take priority.

## CRT and DV1 setup

For a native CRT, choose **CRT Mode: On** and **CRT Screen: Main/Touch**. Keep `vga_scaler=0` and use the MiSTer profile and cable appropriate to your analog hardware. The single DS screen is centered in a 320×240 picture. The native CRT menu stays upright. See **QUICK_START.txt** for RGB, component, composite and S-video profiles.

For **DV1**, connect MiSTer HDMI directly to the RetroTINK-4K and use `direct_video=1`, `dvi_mode=0`, and `vga_scaler=0` in the active profile. Exit to normal MiSTer and relaunch after changing the INI. Native output rotation uses the receiver's controls. For ordinary scaled HDMI, use `direct_video=0`.

For a compatible VGA monitor using the scaler, use `vga_mode=rgb`, `vga_scaler=1`, `composite_sync=0` and a supported `video_mode`; select **RGBHV** on the receiver. This was tested at 1080p60. These scaled VGA settings are separate from native 240p CRT settings.

Hold **F10** or a mapped **Screen Peek** button to view the other screen, then release to return. If a trigger cycles screens instead, bind it to **Screen Peek** under **System → Define NDS buttons**. Existing maps are preserved. This release does not include the separate newer all-controller mapping beta.

## Hardware checks

- Native RGBS 240p: **497 captured frames with zero measured displacement**.
- Direct HDMI DV1: **499 captured frames with zero measured displacement**, with 48 kHz stereo audio.
- NSMB run/jump, Peek release, audio, 3D FPS display and lid close/wake passed. Game frame counters advanced at about **59.8 frames/s** with no reported protocol faults during the bounded gameplay samples.
- Ordinary HDMI 1080p60, dual screens, clockwise/counterclockwise TATE and menu rotation, and scaled RGBHV VGA passed.

The 3D FPS counter can include reused images; game frame counters do not measure unique rendered frames. NSMB retains its existing alternate rendering-update profile.

## Validation limits and known issues

- This build was tested through RetroTINK-4K. **Physical CRT acceptance remains pending.** Composite/S-video is retained but was not physically requalified on this build; the earlier rc.6 SuperStation One composite-color result is historical.
- Synthetic microphone blowing is retained and its RTL regression passed; a game-specific blowing interaction was not requalified in this run. Physical microphone capture is not supported.
- Switching the receiver from DV1 to ordinary HDMI required reloading its profile and temporarily disabling AutoLoad DV1 during testing. If the receiver or capture loses signal after switching, check its input/profile settings. The exact transition cause is unresolved.
- Slowdown, uneven animation, graphical issues and audio/movie hitches remain possible. These bounded checks do not establish universal game compatibility or long-term stability. Strange Journey can freeze during its intro; GTA: Chinatown Wars can clip near the camera.
- Existing firmware and storage limits remain; see **QUICK_START.txt**. Separate Main-on-HDMI and Touch-on-VGA output is not implemented.

## Files and source

The release assets are the install ZIP and its SHA-256 checksum. Corresponding source is provided by GitHub's source ZIP/tar.gz at the matching release tag. Build provenance and hardware measurements are recorded in the source `docs` directory. Static timing reports remain diagnostic; hardware behavior determines acceptance.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (saneFriend). Thanks to Corn for the standalone suggestion and skmp, the DreamSTer developer. Full credits and licenses remain in the source tree.
