# NDS4MiSTer v0.9.0-rc.7

**Stable native 240p and DV1 support**

## What's new

- **Stable native CRT video.** Fixes an alternating frame length that caused vertical shaking. Native CRT output now uses a fixed 262-line frame at ~59.64 Hz.
- **DV1 verified on RetroTINK-4K.**

This release packages the exact FPGA, host, and renderer binaries tested on the hardware rig.

> **Note:** The host binary is unchanged and still shows **rc.6** in its version label. The release manifest and launcher correctly identify **rc.7**. This has no effect on the FPGA fixes.

## Install

1. If a standalone session is running, exit with **System → Reboot**.
2. Extract the ZIP to the SD card root. **Merge** into the existing `Scripts` folder (don't replace it), and make sure the hidden `Scripts/.NDS_Standalone` folder is included.
3. Run **Scripts → NDS4MiSTer** and choose **Load \*.NDS**.

**Preserved:** games, saves, controller maps, display options, and `MiSTer.ini`. Saves stay in `saves/NDS`; keep ROM filenames unchanged so they match.

**Not included:** ROMs, BIOS/firmware dumps, personal settings, controller maps, or a kernel.

**Supported kernels:** Linux `6.18.38-MiSTer` and `5.15.1-MiSTer`, with their matching modules.

## Display setup

New installs default to **CRT Mode: Off**. Existing settings take priority.

### Native CRT (240p)

- Set **CRT Mode: On** and **CRT Screen: Main** or **Touch**.
- Keep `vga_scaler=0`, and use the MiSTer profile and cable for your analog hardware.
- One DS screen is centered in a 320×240 frame. The menu stays upright.
- See `QUICK_START.txt` for RGB, component, composite, and S-video profiles.

### DV1 (RetroTINK-4K)

- Connect MiSTer HDMI directly to the RetroTINK-4K.
- In the active profile: `direct_video=1`, `dvi_mode=0`, `vga_scaler=0`.
- After changing the INI, exit to normal MiSTer and relaunch.
- Use the receiver's controls for native output rotation.

### Scaled HDMI

- Use `direct_video=0`.

### Scaled VGA (RGBHV)

- `vga_mode=rgb`, `vga_scaler=1`, `composite_sync=0`, and a supported `video_mode`.
- Select **RGBHV** on the receiver. Tested at 1080p60.
- These settings are separate from the native 240p CRT settings above.

### Screen Peek

Hold **F10** or a mapped **Screen Peek** button to view the other screen; release to return. If a trigger cycles screens instead, rebind it to **Screen Peek** under **System → Define NDS buttons**. Existing maps are preserved.

The separate all-controller mapping beta is **not** included in this release.

## Hardware validation

| Test | Result |
|---|---|
| Native RGBS 240p | 497 captured frames, zero measured displacement |
| Direct HDMI DV1 | 499 captured frames, zero measured displacement, 48 kHz stereo |
| Gameplay (NSMB) | Run/jump, Peek release, audio, 3D FPS display, lid close/wake passed; ~59.8 game frames/s, no protocol faults in bounded samples |
| Other modes | HDMI 1080p60, dual screens, CW/CCW TATE, menu rotation, scaled RGBHV VGA passed |

The 3D FPS counter can include reused images, and game frame counters don't measure unique rendered frames. NSMB keeps its existing alternate rendering-update profile.

## Known issues and limits

- **Physical CRT acceptance is still pending.** This build was tested through a RetroTINK-4K.
- **Composite/S-video** remains available but wasn't re-tested on this build. The rc.6 SuperStation One composite result is historical.
- **Microphone:** Synthetic blowing is retained and passed RTL regression, but wasn't re-tested in-game. Physical mic capture isn't supported.
- **DV1 → HDMI switching:** During testing, switching the receiver required reloading its profile and temporarily disabling AutoLoad DV1. If you lose signal after switching, check the receiver's input/profile settings. Root cause is unresolved.
- **Compatibility:** Slowdown, uneven animation, graphical glitches, and audio/movie hitches are still possible. These tests don't establish universal compatibility or long-term stability.
  - *Shin Megami Tensei: Strange Journey* can freeze during its intro.
  - *GTA: Chinatown Wars* can clip near the camera.
- Separate outputs (Main on HDMI, Touch on VGA) aren't implemented.
- Existing firmware and storage limits still apply; see `QUICK_START.txt`.

## Files and source

- Install ZIP and its SHA-256 checksum.
- Source: GitHub's source archive at this release tag.
- Build provenance and hardware measurements are in the source `docs` directory. Static timing reports are diagnostic only; hardware behavior determines acceptance.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, Nitro_DarkSide, the melonDS contributors, heni, and InsaneFriend (saneFriend). Thanks to Corn for the standalone suggestion.
