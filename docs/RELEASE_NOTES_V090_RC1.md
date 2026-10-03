# NDS4MiSTer v0.9.0-rc.1

**Standalone launch, larger games, and the original DS firmware menu.**

This is a release candidate. Many games are playable, but graphics, sound, and compatibility still have rough edges.

## What's changing

**Start from Scripts → NDS4MiSTer.** This release starts the core, ARM helper, and NDS menu together. There is no separate Kickstart step, Console launch, or five-minute window.

Standalone stops the normal MiSTer program while you play and runs its own lightweight menu. This makes more ARM processing time available to the core. **System → Reboot** returns you to the normal MiSTer menu; it does not power-cycle the board.

Standalone is the direction for future releases. Your existing normal NDS core and Kickstart installation remain available. Games, saves, and `MiSTer.ini` stay in place.

## What's new

- **Larger games work.** The loader now handles supported 256 MiB and 512 MiB ROM layouts. **Kingdom Hearts: 358/2 Days** and **Pokémon White 2** worked in our testing. This does not add DSi mode or guarantee that every larger game works.
- **Boot the DS firmware menu.** Choose **Boot DS firmware** to visit the original DS interface using your own compatible BIOS and firmware files. These files are optional for normal games and are not included.
- **Your nickname carries into games.** Save your nickname, birthday, favorite color, and language through the DS settings. Normal games continue to use the built-in firmware, with your saved personal settings. The default nickname is **MiSTer**.
- **Castlevania dialogue corrected.** The lines through character names and dialogue text seen during the firmware test builds are fixed.
- **Super Mario 64 DS graphics fixed.** The first course no longer collapses into a horizontal line in our tested version.
- **Improved pacing and rendering.** The accepted standalone build reduces repeated drawing work and retains the write-combining speed improvements. Speed still varies by game and scene.
- **A button to switch screen layouts.** Map **Cycle Video Layout**, the last option in **Define NDS buttons**, to a spare button and switch layouts while playing.
- **Better handling of slow ROM reads.** Delayed network reads can keep loading without triggering the old recovery timeout. A completely stalled load still times out, and network browsing can still cause problems.

Earlier game fixes, both TATE directions, touch input, cartridge saves, and smoother movie playback carry over. Both graphics engines are always enabled; the Engine B On/Off option has been removed. The ARM processors remain at **1 GHz**, with no overclock.

## Install and play

1. Unzip to the root of your SD card, merging the **Scripts** folder. Include the hidden **Scripts/.NDS_Standalone** support folder. If copying extracted files manually, enable “show hidden files” so it is not missed.
2. Open **Scripts → NDS4MiSTer** and wait for the NDS menu.
3. Choose **Load *.NDS** and select an uncompressed game from `games/NDS`.
4. Use **System → Save settings** to keep your display options.

Fresh installations use **Top/Bottom**, with rotation Off. Existing settings take priority. Standalone shares cartridge saves in `saves/NDS` with the normal core; keep the same ROM filename to use its matching save.

Use the matching support files from this release. The launcher requires a compatible kernel with write-combining and 1 GHz clock control; testing used **Linux 5.15.1-MiSTer**. It does not install a kernel or change your INI. See **QUICK_START.txt** if it reports a missing requirement.

## Optional DS firmware setup

Put your own compatible files directly in `games/NDS`:

```text
games/NDS/bios7.bin
games/NDS/bios9.bin
games/NDS/firmware.bin
```

Choose **Boot DS firmware**, then tap the touch screen when prompted. Use the DS settings to change your personal details. Start games through **Load *.NDS** afterward.

Your original files stay untouched. Saved firmware changes go directly into **saves/NDS/firmware.bin**, alongside your game saves. There is no firmware subfolder.

Firmware boot is experimental: it requires a compatible **256 KiB DS/DS Lite image** and supported BIOS files. Some dumps and touch-calibration settings are not supported yet. Normal games work without these files. See **QUICK_START.txt** for details.

## Menu and TATE

Open the menu with your controller's menu combination, the board's OSD button, or **F12**. Press Right for System and Left to return. **Opening the menu does not pause the game.** Greyed-out System options are not implemented; use normal MiSTer for those features.

For portrait play, select **Video Layout → Top/Bottom** and rotate the picture opposite to the monitor: **90 CCW** for a clockwise monitor turn, **90 CW** for a counterclockwise turn.

The menu rotates separately in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If it is upside down, use `osd_rotate=1`. Edit an existing `[NDS]` section rather than adding another. For a display that supports 1080p, adding `video_mode=8` under `[NDS]` can give a wider portrait picture with small borders. Return to normal MiSTer and relaunch to apply changes. The installer leaves your display settings alone.

## Known issues

- **Slowdown and uneven animation remain.** This is not a promise of 60 FPS in every game.
- **Movies and audio can still hitch.** Sound remains experimental.
- **Shin Megami Tensei: Strange Journey can still freeze during its intro.**
- **GTA: Chinatown Wars can still show clipping near the camera.**
- **Firmware boot is not compatible with every dump.** Touch calibration is not fully supported. Firmware clock edits are not saved across launches, and RTC alarm interrupts are not implemented.
- **Some larger ROM layouts remain unsupported.** A 512 MiB file size alone does not guarantee compatibility.
- **Network browsing can still stall.** Local SD loading avoids those network delays.
- **Other games may glitch or crash.** Testing does not cover every game or a full playthrough.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source will be available through the GitHub release's **Source code (zip)** and **(tar.gz)** links. The installer and source tree include internal checksums.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion and skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
