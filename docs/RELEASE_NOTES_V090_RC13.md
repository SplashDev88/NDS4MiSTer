# NDS4MiSTer v0.9.0-rc.13

This release candidate carries the accepted game optimizations developed from rc12: faster Final Fantasy Tactics A2 rendering, terrain optimizations for Pokémon Platinum, HeartGold and SoulSilver, and faster starter-selection rendering in HeartGold and SoulSilver.

## Changes since rc12

- **Final Fantasy Tactics A2 (USA revision 0):** accepted renderer optimizations reduce repeated rendering work. Demanding scenes still run below native speed.
- **Pokémon Platinum (USA revision 1):** skip terrain models outside the tested visibility bounds. The measured outdoor route gained about 13% in completed screen-buffer updates.
- **Pokémon HeartGold (USA revision 0):** terrain visibility filtering improves the measured plaza scene by about 3%; the starter screen avoids repeating identical idle drawing work.
- **Pokémon SoulSilver (USA revision 0):** the corresponding independently checked terrain patch improves the measured plaza by about 6.5%. Starter idle rendering rose from 14.23 to 43.94 completed screen-buffer updates per second compared with the previous SoulSilver beta.
- Guest patches activate automatically for exact verified ROM identities. They affect the loaded game image; original ROM files are not rewritten. Unknown revisions and regions retain their ordinary loading path.

These are bounded scene measurements, not whole-game speedups, unique animation FPS or changes to the game's clock rate. Pokémon patches use the accepted functional/perceptual budget: timing, RAM, RNG or audio can differ from unpatched runs. They are not certified bit-exact across an entire game.

RC12's Order of Ecclesia improvements, Ni no Kuni story-video fix, 21 movie profiles, NSMB regional optimizations and earlier display/menu work are retained. The FPGA image and stock 1 GHz ARM clock are unchanged. No new Animal Crossing or Phantom Hourglass patch is enabled.

## Install or update

1. Exit through **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.13_Standalone.zip** to the SD-card root, including hidden files. Merge `Scripts` and overwrite program files.
4. Run **Scripts → NDS4MiSTer**, choose **Load *.NDS**, and select your ROM.

Existing saves, controller mappings and display settings are retained. A first large-ROM load from network storage can take several minutes while the image is verified. For rollback, exit and restore the matching backed-up launcher and entire support folder together; keep your current saves unless you intend to undo game progress.

## Known limitations

- Testing covers specific scenes and save/reset/reload paths, not full playthroughs. Broader Pokémon battle and later-game behavior needs more coverage. In Platinum's fixed-input battle replay, battle progress and HP diverged; coherent scenes and a matching saved file do not establish identical battle behavior.
- Additional Pokémon revisions and regional releases are inventoried but are not enabled by resemblance to the USA versions. See `VERSION_COVERAGE.md` for exact support.
- Slowdown, audio hitches, graphical glitches and crashes remain possible. FPGA static setup/recovery timing remains unresolved; this package does not introduce new RTL.
- The inherited NSMB goal-pole background glitch remains. Ni no Kuni clip S07 has a one-frame screen-clear difference, and later story triggers are not fully qualified in natural gameplay.
- Save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode and PAL 50 Hz output remain unsupported. RetroTINK LCD Grid 2 can darken or band outside the tested layout.

The release-specific host rebuild changes only the version text. The accepted beta runtime was tested on MiSTer; this exact release ZIP has offline package/stream validation and has not been launched on hardware. Detailed scope, component hashes, corresponding source and build instructions are included.

## Credits

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Included license notices cover FFmpeg, ndspy and other dependencies. No commercial ROMs, BIOS dumps, user saves or personal settings are included.
