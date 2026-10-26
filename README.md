# NDS4MiSTer v0.9.0-rc.11

Portrait of Ruin performance and movie improvements, rotating menus, and a compact horizontal menu.

## What's new since rc.10

- **Faster Portrait of Ruin gameplay in tested USA scenes.** Exact rendering, replay and worker-scheduling optimizations improve throughput and frame spacing. These gameplay measurements cover USA revision 0; they do not establish full-speed play throughout the game or equivalent gains in every region.
- **Portrait of Ruin opening movies at approximately their native 30 fps.** Automatic acceleration covers all four known retail variants: USA, Europe (all included languages), Japan and Japan Rev 1. Complete movies and skipping were checked on hardware; software comparisons reproduce the original decoded RGB frames. Unknown or modified ROMs retain normal decoding.
- **Menus follow digital picture rotation.** The independent native analog Main/Touch menu remains upright.
- **Compact horizontal Direct Video 1 menu.** Unrotated side-by-side menus align with the game pixel grid while retaining their previous width.
- **Optional DS Lite-style RetroTINK 4K recipe.** The included guide describes the tested 1080p Tate setup with LCD Grid 2. It is a manual recipe, not an importable device profile or an automatic change to your settings.

The earlier Dawn of Sorrow and other supported movie accelerations, New Super Mario Bros. improvements, loading cache, boot fixes, NAND saves, right-stick range and alternative-launcher support remain included. The ARM clock remains 1 GHz.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.11_Standalone.zip** to the SD-card root. Include hidden files, merge `Scripts`, and overwrite program files.
4. Run **Scripts → NDS4MiSTer**, then **Load *.NDS** and select your original ROM.

This updates the normal standalone installation. Earlier private-beta launchers remain separate. Existing settings and saves are preserved; games keep their normal save identity. No patched ROM is required. Linux support modules for **6.18.38-MiSTer** and **5.15.1-MiSTer** are included. No game ROMs, saves, commercial BIOS/firmware, personal settings or kernel image are included.

For rollback, exit the core and restore the backed-up launcher and complete hidden kit together. Keep your current saves unless you intend to undo game progress. See QUICK_START.txt for older RTC-format compatibility.

## Known limitations

- This is a release candidate with bounded testing. Gameplay is **not consistently 60 fps**; slowdown, graphical errors and crashes can still occur. FPGA static setup/recovery timing remains unresolved.
- The RetroTINK LCD Grid 2 recipe is qualified for the documented Tate setup. Other layouts may become dim or show banding with that effect; disable the LCD effect or use a separately adjusted profile for those layouts. The core does not install RetroTINK profiles.
- One initial Japan Rev 1 movie test showed brief clustered stalls. Warm and fresh-save/cache repeats did not reproduce them; the cause remains unconfirmed.
- The previously reported NSMB goal-pole background glitch remains unresolved. Save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode and PAL 50 Hz output remain unsupported. Native analog output is about 59.64 Hz.

See VALIDATION_RC11.md for the tested scope and RETROTINK_DS_LITE.md for the optional display recipe. Corresponding source, build instructions and licenses are included under `Scripts/.NDS_Standalone/source` and `licenses`.

## Thanks

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. FFmpeg and ndspy credits and licenses are included.
