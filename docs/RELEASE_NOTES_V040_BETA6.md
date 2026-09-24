# NDS4MiSTer v0.4.0-beta.6

**Graphics fixes for Final Fantasy Tactics A2 and Pokémon Platinum, plus faster rendering.**

## What's new

- **Final Fantasy Tactics A2: Grimoire of the Rift graphics fixed.** Missing graphics and black areas during startup and in the opening menus now display correctly.
- **Pokémon Platinum's missing graphics restored.** The player character and room furniture, including the bed, TV, shelves and plant, now appear correctly in our testing. Saving and reloading the room also passed.
- **Faster rendering.** Improvements to 2D and 3D drawing reduce repeated work while keeping the restored graphics. The latest build played much better in testing, though some slowdown remains. The ARM processor still runs at stock 1 GHz, with write-combining enabled on supported kernels.
- **A wireless-related crash addressed.** Disconnected Wi-Fi repeatedly searching for a network could stall the core, including during Lunar Knights' opening movie. Kickstart now stops those retries when Wi-Fi is disconnected. Connected Wi-Fi and saved network settings are left alone; normal Wi-Fi startup returns after a reboot.
- **Earlier game fixes carry over.** Castlevania: Dawn of Sorrow's bottom-screen flashes, Metroid Prime Pinball's missing screen section, Chrono Trigger's startup and sprite fixes, and Kirby's graphics fixes are retained, along with smoother movies, cartridge saves, touch input and both TATE rotation directions.

## Install

> **Engine B must be On for this build.** Settings saved from an older build may leave it Off, which can produce a blank display.

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Open **Console → NDS_20260924** within five minutes. If more time passes, run Kickstart again.
6. Set **Engine B (next Reset) → On**, then choose **Load NDS** and select your game. If a game is already loaded, reset or reload it after changing Engine B.

Run Kickstart after every reboot and any time you return to the NDS core. Use the core, ARM helper and launcher supplied together.

Both screens are drawn in this build, so leave Engine B On. The Engine B Off option is still in the menu but is not supported here.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the monitor's physical turn: **90 CCW** for a clockwise turn, **90 CW** for a counterclockwise turn. D-pad, mouse and touch keep their native directions on the turned monitor.

The MiSTer menu rotates separately. Add this under `[NDS]` in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If the menu appears upside down, use `osd_rotate=1`. Edit the existing `[NDS]` section if there is one, then save and reboot. The installer does not touch your INI.

## Known issues

- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **Some slowdown and uneven animation remain.** These improvements do not make every game run at 60 FPS.
- **Movies and audio can still hitch.** Sound is still experimental.
- **Pokémon SoulSilver has not been verified with these fixes.** Platinum's tested character and room graphics are restored, but this does not establish that every Pokémon graphics issue is resolved ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Other graphics and compatibility problems remain.** Demanding games may still slow down, glitch or crash.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree each include internal checksums.

## Thanks

Special thanks to **InsaneFriend (GitHub: saneFriend)** for the writable SPI firmware, ARM7 Wi-Fi boot-memory and cartridge-IR compatibility fixes retained in this release. The Wi-Fi boot-memory fixes help game compatibility; they do not add DS wireless multiplayer.

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, and heni. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
