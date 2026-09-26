# NDS4MiSTer v0.5.1

**Faster gameplay, New Super Mario Bros. graphics fixes, and an optional second screen.**

## What's new

- **Faster rendering.** More efficient drawing reduces repeated work. Castlevania: Dawn of Sorrow showed a noticeable speed improvement in our gameplay testing, and New Super Mario Bros. runs well again. Results vary by game; this does not make every game run at 60 FPS.
- **New Super Mario Bros. graphics fixed.** Fixes address background flickering, corruption on the bottom-screen overworld map, and large Star Coins that looked clear or pale instead of gold.
- **Engine B is optional again.** Unlike v0.5.0, this release supports turning the second graphics engine Off. Off skips drawing Engine B and copies Engine A to both screens. This can help performance, but the gain depends on the game and content drawn only by Engine B will be missing. Leave it On for both screens.
- **Earlier fixes carry over.** Pokémon Platinum, Final Fantasy Tactics A2, Mega Man ZX, Resident Evil: Deadly Silence, Kirby Mass Attack, Kirby Super Star Ultra and GTA: Chinatown Wars retain their fixes. TATE in both directions, touch input, cartridge saves, smoother movies and the disconnected Wi-Fi guard are also retained.
- **No overclock.** The ARM processor still runs at stock 1 GHz, with write-combining on supported kernels.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS_Kickstart**.
5. Open **Console → NDS_20260926** within five minutes, then choose **Load NDS**. If you miss the window, run Kickstart again.

Run Kickstart after every reboot and any time you return to the NDS core. Use the core, ARM helper and launcher that shipped together. Do not mix files from older releases.

## Second screen

Set **Engine B (next Reset) → On** for both DS screens, or **Off** to show Engine A on both. Reset or reload your ROM after changing it. Off can hide menus, maps or gameplay that normally appear on the other screen.

The installer preserves your saved settings. If both screens show the same picture after upgrading, turn Engine B On and reset or reload the ROM.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the way the monitor physically turns: **90 CCW** for a clockwise turn, **90 CW** for a counterclockwise turn. D-pad, mouse and touch keep their normal directions on the turned monitor.

The MiSTer menu rotates separately. Add this under `[NDS]` in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If the menu comes out upside down, use `osd_rotate=1`. Edit the existing `[NDS]` section if there is one, then save and reboot. The installer does not touch your INI.

## Known issues

- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **GTA: Chinatown Wars may still show stray triangles.** The crash fix does not solve every graphics problem.
- **Some slowdown and uneven animation remain.** Speed varies by game and scene, with or without Engine B.
- **Movies and audio can still hitch.** Sound is still experimental.
- **Pokémon SoulSilver has not been verified with these fixes.** Platinum's tested character and room graphics are restored, but other Pokémon problems may remain.
- **Other graphics and compatibility problems remain.** Testing does not cover every game or a full playthrough. Demanding games may still slow down, glitch or crash.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree each include internal checksums.

## Thanks

Special thanks to **InsaneFriend (GitHub: saneFriend)** for the Resident Evil: Deadly Silence, Kirby Mass Attack, Kirby Super Star Ultra, Grand Theft Auto: Chinatown Wars and Mega Man ZX fixes, along with earlier writable SPI firmware, ARM7 Wi-Fi boot-memory and cartridge-IR compatibility work. These Wi-Fi compatibility fixes do not add DS wireless multiplayer.

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, and heni. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
