# NDS4MiSTer v0.9.0-rc.12

Faster Castlevania: Order of Ecclesia gameplay, smoother opening movies across all four supported regions, and restored Ni no Kuni story video.

## What's new since rc.11

- **Faster Order of Ecclesia gameplay.** Rendering and replay optimizations improve throughput and frame pacing. Tested EU, Japan and Korea combat scenes improved from about 34 to 55 completed paired-screen updates per second, roughly 59%. These are screen-update measurements; full-game steady 60 fps is not guaranteed.
- **Smoother Order of Ecclesia opening movie.** Accelerated decoding preserves the original movie and audio at its native approximately 15 fps.
- **Ecclesia regional coverage.** Both improvements support USA, Europe, Japan and Korea retail revision 0. These are all four variants in the current project catalog. Unlisted revisions and modified ROMs are not implicitly supported by acceleration.
- **Fixed Ni no Kuni story movies showing black video after New Game.** Supports Japanese retail and the English v1.0 translation. The English intro, first story movie, movement and dialogue passed a MiSTer test with 3,215 movie-frame decodes and zero decoder errors.

RC11's Portrait of Ruin improvements, digital menu rotation and Direct Video 1 menu alignment fixes are retained. The FPGA image and 1 GHz ARM clock are unchanged. Movie acceleration activates automatically for verified ROM versions; original ROM files are not rewritten.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.12_Standalone.zip** to the root of your SD card. Include hidden files, merge the `Scripts` folder, and overwrite existing program files.
4. Run **Scripts → NDS4MiSTer**, choose **Load *.NDS**, and select your ROM.

A first load of a large ROM from network storage may take several minutes while it is verified and prepared. Later loads can reuse the verified cache. Existing display settings, controller mappings and saves are retained.

## Known limitations

- This release candidate has limited testing. Gameplay does not consistently hold 60 fps; slowdown, graphical glitches and crashes may still occur. Heavy Ecclesia warp effects remain slow. FPGA static setup/recovery timing remains unresolved.
- The Ni no Kuni movie sweep completed all 15 story clips, but clip S07 has a one-frame screen-clear difference before playback. Later story triggers and return scenes have not all been tested in their natural gameplay context; this is not a full-playthrough qualification.
- The NSMB goal-pole background glitch remains.
- RetroTINK LCD Grid 2 can darken or cause banding in some layouts. The optional DS Lite-style recipe applies to the documented Tate setup; other layouts may need separate profiles or the effect disabled.
- Not yet supported: save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer, DSi mode and PAL 50 Hz output.

Source, build instructions, validation records and licenses are included in `Scripts/.NDS_Standalone/source` and `licenses`. No ROMs, user saves or personal display settings are included.

## Thanks

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. FFmpeg and ndspy credits and licenses are included.
