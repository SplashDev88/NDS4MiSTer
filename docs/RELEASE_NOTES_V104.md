# NDS4MiSTer v1.0.4

## What's new

* Fixed Final Fantasy III FMV playback and music timing for the USA, Europe, and Japan releases.
* Added Display options → Pixel Grid with Off, Light, Medium, and Strong settings. Supports standard 720p and 1080p.

Pixel grid does not apply to Direct Video, analog output, non-integer scaling, or 1440p.

## Video Setup to Enable Optional Pixel Grid

Set `video_mode=8` for 1080p60 or `video_mode=0` for 720p60, and `direct_video=0`, then relaunch NDS.

## Install

1. Exit NDS with System → Reboot. Back up `saves/NDS` and `Scripts/.NDS`.
2. Extract the full standalone ZIP to the root of the SD card, including hidden files. Merge folders and replace package files.
3. Run Scripts → NDS.
