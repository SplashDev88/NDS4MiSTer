# NDS4MiSTer v0.9.0-rc.10

**Smoother FMVs, a modest speed boost, boot fixes, adjustable right-stick range, NAND save support, and alternative MiSTer launcher support.**

[Download the latest release](https://github.com/SplashDev88/NDS4MiSTer/releases/latest)

## What's new since rc.9

- **Smoother opening movies.** FMV playback is optimized for tested revisions of *Castlevania: Dawn of Sorrow*, *Chrono Trigger*, *Ni no Kuni*, *Shin Megami Tensei: Strange Journey*, *Final Fantasy XII: Revenant Wings* and *Sonic Chronicles*.
- **Faster New Super Mario Bros.** Optimizations for the tested USA revision 0 reduce geometry work and rubberbanding.
- **Caching reduces repeat load times in supported games.**
- **Boot fixes for Ni no Kuni and Pokémon Conquest.** Larger cartridge layouts now load correctly, and cartridge address mirroring has been fixed.
- **NAND saves** for *WarioWare D.I.Y.* and *Jam with the Band*. *Daigassou! Band Brothers DX* remains unsupported.
- **Right Stick Range** setting in the root menu. Choose 100%, 125%, 150%, 175% or 200% so your controller can reach all four touchscreen corners. Use **System → Save settings** to retain your choice.
- **Alternative MiSTer launcher support.** Added discovery and return-to-menu handling for documented installations of Zaparoo, Degauss, RetroAchievements, Physical-CD, mister-disc and Console Mode. Automated checks passed; each alternative frontend still needs hardware validation.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.10_Standalone.zip** to the root of your SD card. Include hidden files, merge the `Scripts` folder, and overwrite existing program files.
4. Run **Scripts → NDS4MiSTer**, then choose **Load *.NDS**.

Support modules are included for Linux **6.18.38-MiSTer** and **5.15.1-MiSTer**. The package does **not** include game ROMs, game saves, commercial BIOS/firmware dumps, personal settings or a kernel image.

## Known limitations

- **NSMB goal pole glitch:** A user has reported background glitches while sliding down the goal pole, also present in earlier releases. We haven't reproduced it in our test rig yet.
- Slowdown, uneven animation, graphical errors and crashes can still occur. **The core does not yet run at a consistent 60 FPS**, and FPGA static timing closure is still unresolved.
- Not yet supported: save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode and PAL 50 Hz output. Native analog output remains about 59.64 Hz.

## Links

[Validation & supported movie revisions](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.10/docs/release/VALIDATION_RC10.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.10/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

> **Download the Standalone ZIP and its SHA-256 checksum.** GitHub's auto-generated *Source code* archives are for developers and won't work for installation.

## Thanks

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Corresponding source code, FFmpeg/ndspy credits and licenses are included in the package.
