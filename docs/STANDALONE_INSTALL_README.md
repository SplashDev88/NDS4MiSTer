# NDS4MiSTer v0.9.0-rc.10

**Smoother supported movies, faster New Super Mario Bros., more games booting, and adjustable right-stick touch range.**

Back up your installation and saves before updating.

## What's new since rc.9

- **Smoother opening movies.** Automatic acceleration for tested revisions of Castlevania: Dawn of Sorrow, Chrono Trigger, Ni no Kuni, Shin Megami Tensei: Strange Journey, Final Fantasy XII: Revenant Wings and Sonic Chronicles. Load your original ROM normally. Supported code is checked before acceleration is enabled; unmatched revisions retain the ordinary path. Loading supported games can take longer, especially from a network share. Movies keep their original frame rate.
- **Better New Super Mario Bros. performance.** The tested USA revision 0 uses automatic optimizations that reduce geometry work and rubberbanding. A faster ARM renderer also improves completed screen updates in the tested castle scene. There is no Speed hacks menu and the ARM still runs at 1 GHz. Some slowdown remains; all levels, power-ups and effects are not verified.
- **Ni no Kuni and Pokémon Conquest boot fixes.** Larger cartridge layouts now load correctly, and cartridge address mirroring is corrected. The tested Japanese Ni no Kuni reached gameplay and save/reload; USA/Australia Conquest revision 1 reached its opening battle. These are bounded checks, not full-game completion claims.
- **NAND saves for WarioWare D.I.Y. and Jam with the Band.** WarioWare's tested Mona score and Jam's registration/profile survived full core exit and relaunch. Other modes and regions need more coverage. **Daigassou! Band Brothers DX is not supported by this release**; its separate save experiment is paused.
- **Right Stick Range in the root menu.** Choose 100%, 125%, 150%, 175% or 200% to help controllers reach all four touchscreen corners. Start at 150% if needed, then use the lowest working value. Select **System → Save settings** to retain it. The default remains 100%.
- **Alternative MiSTer launcher handling.** Added discovery and return-to-menu handling for documented installations of Zaparoo, Degauss, RetroAchievements, Physical-CD, mister-disc and Console Mode. Automated discovery/recovery checks passed; real installations of each alternative frontend still need testing. This does not add RetroAchievements or disc support to the DS core.

## Performance example

In repeated **NSMB World 1 castle jumping** checks, the final renderer delivered about **39–40 completed screen updates/sec**, up from about **35–36** with the preceding private renderer. Earlier work in this release raised geometry submissions from about **35 to 58/sec**, reducing rubberbanding. These measure different stages and must not be added together.

These are development comparisons at **1 GHz**, **not a direct rc.9-to-rc.10 FPS benchmark**. Short Castlevania and Mario Kart checks found no material slowdown against their preceding private controls. This does not establish performance across every game or board.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the entire hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.10_Standalone.zip** to the SD card root. Include hidden files, merge `Scripts`, and overwrite program files.
4. Run **Scripts → NDS4MiSTer**, then **Load *.NDS**.

Keep the launcher and support folder together. Existing display settings, controller maps and clock settings are retained. The included `NDS_speed.cfg` is the release's automatic performance preset. The retained frontend may still show **rc.8** internally; the package manifest identifies **rc.10**.

Saves stay in `saves/NDS`, including for games on USB or a network share. Do not rename ROMs. If an older core left an incorrectly sized NAND save, back it up and move that individual file aside before creating a fresh save. Do not overwrite a save containing progress.

**Rollback:** exit cleanly and restore your backed-up launcher and hidden folder together. Keep current ordinary game saves. rc.9 does not support the new NAND saves; preserve them for a later return to rc.10. Offline clock-file behavior is unchanged from rc.9.

No game ROMs, game saves, commercial BIOS/firmware dumps, personal settings or kernel image are included. Support modules for Linux **6.18.38-MiSTer** and **5.15.1-MiSTer** are included. Display examples are in `QUICK_START.txt`.

## Known limits

- **NSMB goal pole:** a user reports background glitches while sliding down the pole, also seen in earlier releases. This sequence has not yet been reproduced or fixed in our test rig.
- The NSMB optimization omits six transform updates in verified USA revision 0 code. Two reference routes matched visually, but this is a compatibility tradeoff; report broken effects or animations with the level and power-up.
- Movie acceleration covers the listed revisions and tested opening sequences, not every movie or translation. Some loading/preparation takes about a minute. Playback, audio and game performance are not guaranteed hitch-free.
- Slowdown, uneven animation, graphics errors and crashes remain possible. **60 FPS has not been achieved throughout the core.** FPGA static timing closure remains unresolved.
- No save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode or PAL 50 Hz output. Native analog remains about 59.64 Hz.

[Validation and supported movie revisions](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.10/docs/release/VALIDATION_RC10.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.10/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

Download the **Standalone ZIP** and its **SHA-256 checksum**. GitHub's **Source code** archives are for developers, not installation.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Corresponding source, FFmpeg/ndspy credits and licenses are included.
