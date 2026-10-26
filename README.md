# NDS4MiSTer v0.9.0-rc.11

Faster *Castlevania: Portrait of Ruin* gameplay, smooth opening movies, restored menu look and feel, and a fix for the Direct Video 1 menu.

## What's new since rc.10

- **Faster _Portrait of Ruin_ gameplay.** Rendering, replay and worker-scheduling optimizations improve throughput and frame pacing in tested scenes. Measurements were taken on the USA (Rev 0) release; full speed throughout the game isn't guaranteed yet, and gains may differ in other regions.
- **_Portrait of Ruin_ opening movies now play at their native ~30 fps.**
- **Menus now follow digital picture rotation.** The native analog Main/Touch menu still stays upright.
- **Fixed the Direct Video 1 menu.** Unrotated side-by-side menus now line up with the game's pixel grid while keeping the same width.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.11_Standalone.zip** to the root of your SD card. Make sure hidden files are included, merge the `Scripts` folder, and overwrite existing program files.
4. Run **Scripts → NDS4MiSTer**, choose **Load *.NDS**, and select your ROM.

## Known limitations

- This is a release candidate with limited testing. Gameplay does **not** hold a steady 60 fps, and slowdown, graphical glitches and crashes may still occur. FPGA static setup/recovery timing is still unresolved.
- The NSMB goal-pole background glitch is still present.
- Not yet supported: save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode and PAL 50 Hz output.

Source code, build instructions and licenses are included in `Scripts/.NDS_Standalone/source` and `licenses`.

## Thanks

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. FFmpeg and ndspy credits and licenses are included.
