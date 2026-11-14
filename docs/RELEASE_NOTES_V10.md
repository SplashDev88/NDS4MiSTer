# NDS4MiSTer 1.0

1.0 keeps RC15's performance improvements and fixes installation upgrades and Reset settings.

## What's new

- One launcher for every release: **Scripts → NDS**.
- Settings, controller mappings and the in-game clock stay in **Scripts/.NDS/**. Existing RC14 and RC15 settings import automatically on first launch.
- Original RC14/RC15 launchers are backed up and removed from the Scripts menu. Custom launchers and private betas are left alone.
- Fixed Reset settings disabling the New Super Mario Bros. speed preset and preventing the next launch.
- Anti-aliasing defaults to Off on fresh installs and after Reset settings. Saved preferences are preserved when upgrading.
- The installed version appears in the core menu.
- Mr. Moro's RetroTINK-4K profile pack is available separately.

## Known issues

- You may still see slowdowns, stutter, audio hitches or graphical glitches, and a steady 60 FPS isn't guaranteed.
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz aren't supported yet.

## Install

1. Exit NDS with **System → Reboot**, then back up **saves/NDS**.
2. Extract the full ZIP to the root of your SD card, including hidden files. Merge folders and replace package files.
3. Run **Scripts → NDS**.
4. On a fresh install, choose your display settings and use **System → Save settings**.

Saves stay in the standard NDS folder. Back up **Scripts/.NDS/NDS_rtc.cfg** to keep your in-game clock.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend, Corn, skmp, apeekaboo, Mr. Moro and everyone who tested.
