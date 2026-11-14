# NDS4MiSTer RC15

[Download ZIP](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.15/NDS4MiSTer_v0.9.0-rc.15_Standalone.zip) · [Release page](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.15) · [Compatibility list](https://docs.google.com/spreadsheets/d/1HNx41BC4jj3XQ-pzT3D9oJNnD20f9ZzkurHLMI3L-Is/htmlview) · [Mr. Moro’s optional RetroTINK-4K pack](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.15/NDS4MiSTer_RetroTINK4K_MrMoro_Profiles.zip)

RC15 is a moderate performance update over RC14. It adds several new display settings, including the option to turn off anti-aliasing for more speed.

## What's new

- Faster overall, for example:
  - Castlevania: Dawn of Sorrow: 30 → 39 FPS
  - New Super Mario Bros.: 15 → 30 FPS on the overworld map, and about 60 FPS in level 1-1
  - Mario Kart DS: game pacing went from half speed to full speed (though the framerate dropped slightly)
- FPGA-accelerated rendering where it helps, falling back to ARM where it doesn't
- Faster texture handling and a larger texture cache
- Game-specific speedups for several titles, including Castlevania: Dawn of Sorrow, Pokémon Platinum, Final Fantasy Tactics A2, New Super Mario Bros., Mario Kart DS, Ultimate Mortal Kombat 3 and more

## Known issues

- You may still see slowdowns, stutter, audio hitches or graphical glitches, and a steady 60 FPS isn't guaranteed
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz aren't supported yet

## Install

1. Exit NDS with System → Reboot, then back up saves/NDS.
2. Extract the full ZIP to the root of your SD card, including hidden files.
3. Run Scripts → NDS_RC15.
4. Choose your display settings on first launch, then use System → Save settings to keep your preferences.

Saves stay in the standard NDS folder.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend, Corn, skmp, apeekaboo and everyone who tested.
