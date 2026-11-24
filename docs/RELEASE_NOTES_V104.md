# NDS4MiSTer v1.0.4

## What's new

* Added **Display options → Pixel Grid** with **Off, Light, Medium, and Strong** settings. It defaults to Off; **System → Save settings** remembers your choice.
* Pixel Grid supports standard **720p and 1080p HDMI** at **2× through 5× integer scale**. The 2× grid remains available for feedback. Menu text stays clear because it is drawn after the effect.
* Display options now leaves one blank line between **3D FPS Counter** and **3D Anti-aliasing** in HDMI mode.

The grid does not apply to Direct Video, native analog output, 1×, noninteger scaling, or other HDMI resolutions. To compare it through an external scaler, turn off that scaler's LCD/scanline and mask effects and use integer scaling.

## Video setup

Use the HDMI setup in README.md. Set `video_mode=0` for 720p60 or `video_mode=8` for 1080p60, with `direct_video=0`, then relaunch NDS. The package preserves existing video settings. At 1080p, Side by Side gives 3×; Top/Bottom with 90-degree rotation gives 4×. That rotated layout gives 2× at 720p.

## Install

1. Exit NDS with **System → Reboot**. Back up `saves/NDS` and `Scripts/.NDS`.
2. Extract the full standalone ZIP to the root of the SD card, including hidden files. Merge folders and replace package files.
3. Run **Scripts → NDS**.

Existing saves, mappings, and preferences remain in place. The release uses the normal `NDS.sh` launcher; the separate Pixel Grid test launcher can remain installed.

## Validation

The FPGA is the same Test 3 image checked in New Super Mario Bros., Tetris DS, and GTA: Chinatown Wars. The release host adds the v1.0.4 label and the Display options spacing adjustment, checked with the host menu and Pixel Grid tests. See VALIDATION.json for the exact checks and scope. This remains an experimental core; the FPGA is not statically timing-closed, and short gameplay checks do not establish full-game reliability.
