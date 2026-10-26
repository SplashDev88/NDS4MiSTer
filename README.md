# NDS4MiSTer v0.9.0-rc.12

Faster gameplay and smoother FMVs in *Castlevania - Order of Ecclesia* and fixed *Ni no Kuni* story FMV bug.

[Download rc.12](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.12/NDS4MiSTer_v0.9.0-rc.12_Standalone.zip) · [Release notes](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.12)

## What’s new

- **Order of Ecclesia runs faster.** Combat is noticeably smoother, about 60% faster in testing, though it doesn’t hold a steady 60 fps yet.
- **Order of Ecclesia’s opening movie plays smoothly** with its original audio.
- **Ni no Kuni story movies no longer show a black screen** after starting a New Game. Works with the Japanese release and the English v1.0 translation.

The Ecclesia improvements work with the USA, Europe, Japan and Korea releases. Everything from rc.11 is still included.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.12_Standalone.zip** to the root of your SD card. Include hidden files, merge the `Scripts` folder, and overwrite existing files.
4. Run **Scripts → NDS4MiSTer**, choose **Load \*.NDS**, and pick your ROM.

Your saves, controller mappings and display settings carry over. The first load of a large ROM over the network may take a few minutes; later loads are faster.

## Known issues

- This is a release candidate. Expect occasional slowdown, graphical glitches or crashes.
- Heavy warp effects in *Ecclesia* are still slow.
- Not yet supported: save states, wireless multiplayer, DSi mode and PAL 50 Hz output.

## Thanks

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp.
