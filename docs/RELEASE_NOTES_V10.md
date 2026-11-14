# NDS4MiSTer v1.0

## What's new

- Settings, controller mappings and the clock now live in permanent locations (Scripts/NDS.sh and Scripts/.NDS/) and move over automatically from RC14/RC15.
- Fixed a bug where resetting settings disabled certain speed optimizations.
- On fresh installs, anti-aliasing now starts Off for improved speed.
- Fixed a controller-mapping bug that could leave Define buttons stuck on "Release all controls".

## Known issues

- You may still see slowdowns, stutter, audio hitches or graphical glitches, and a steady 60 FPS isn't guaranteed.
- Save states, wireless multiplayer and DSi mode aren't supported yet.

## Install

1. Exit NDS with **System → Reboot**, then back up **saves/NDS**.
2. Extract the full ZIP to the root of your SD card, including hidden files. Merge folders and replace package files.
3. Run **Scripts → NDS**.
4. On a fresh install, choose your display settings and use **System → Save settings**.

Saves stay in the standard NDS folder. Back up **Scripts/.NDS/NDS_rtc.cfg** to keep your in-game clock.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend, Corn, skmp, apeekaboo, Mr. Moro and everyone who tested.
