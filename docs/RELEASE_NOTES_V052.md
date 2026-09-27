# NDS4MiSTer v0.5.2

**Final Fantasy Tactics A2 regression fix.**

## What's new

- **Final Fantasy Tactics A2: Grimoire of the Rift fixed.** Restores fast, responsive menus and corrects the grey boxes in the startup logos, including when reloading the game.

All previous fixes and features carry over.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Open **Console → NDS_20260926** within five minutes, then choose **Load NDS**. Miss the window and you'll need to run Kickstart again.

Run Kickstart after every reboot and any time you return to the NDS core. Use the core, ARM helper and launcher that shipped together. Don't mix in files from older releases.

## Second screen

**Engine B (next Reset) → On** gives you both DS screens, drawn separately. That's the setting you want for normal play. **Off** skips the second engine and copies the first screen's picture to both. It may help speed in some games, but don't count on much, and anything that only appears on the other screen — menus, maps, gameplay — disappears with it.

Reset or reload your ROM after changing the setting. Your saved settings carry over from the last version, so if both screens show the same picture after upgrading, Engine B is Off — turn it On and reload.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the way the monitor physically turns: **90 CCW** for a clockwise turn, **90 CW** for a counterclockwise turn. D-pad, mouse and touch keep their normal directions on the turned monitor.

The MiSTer menu rotates separately. Add this under `[NDS]` in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If the menu comes out upside down, use `osd_rotate=1`. Edit the existing `[NDS]` section if there is one, then save and reboot. The installer won't touch your INI.

## Known issues

- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **GTA: Chinatown Wars may still show stray triangles.** The crash fix doesn't solve every graphics problem in it.
- **Slowdown and uneven animation remain**, with or without Engine B. These fixes don't guarantee full-speed play. Performance varies by game and by scene.
- **Movies and audio can still hitch.** Sound is still experimental.
- **Pokémon SoulSilver hasn't been tested with these fixes.** Platinum's character and room graphics are confirmed restored, but other Pokémon problems may remain ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Other graphics and compatibility problems remain.** Testing doesn't cover every game or a full playthrough. Demanding games may still slow down, glitch or crash.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree each include internal checksums.

## Thanks

Special thanks to **InsaneFriend (GitHub: saneFriend)** for the Resident Evil: Deadly Silence, Kirby Mass Attack, Kirby Super Star Ultra, Grand Theft Auto: Chinatown Wars and Mega Man ZX fixes, along with earlier writable SPI firmware, ARM7 Wi-Fi boot-memory and cartridge-IR compatibility work. These Wi-Fi compatibility fixes do not add DS wireless multiplayer.

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, and heni. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
