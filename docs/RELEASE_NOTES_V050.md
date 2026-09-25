# NDS4MiSTer v0.5.0

**More games working, restored graphics, and faster rendering.**

Still pre-1.0. More games run than in any release so far, but expect rough edges — see Known issues.

## Read this first

**Engine B is now required.** Both screens are drawn in this build, and Engine B must be On. If you're upgrading, your saved settings may still have it Off, which gives you a blank display. Set **Engine B (next Reset) → On**, then reset or reload your game. This reverses the guidance from beta.3, where Off was the default and turning it On cost you speed. The Off option is still in the menu but isn't supported here.

## What's new

**Games that now start and play**

- **Kirby Mass Attack** and **Kirby Super Star Ultra** — no more hangs at startup or white screens.
- **Resident Evil: Deadly Silence** — the game no longer gets stuck partway through.
- **Grand Theft Auto: Chinatown Wars** — no longer crashes on certain bad 3D shapes. Stray triangles can still appear.

**Graphics fixed / restored**

- **Pokémon Platinum** — your character and the furniture in your room, including the bed, TV, shelves and plant, all show up now.
- **Mega Man ZX** — missing graphics and white bands are fixed.
- **Final Fantasy Tactics A2: Grimoire of the Rift** — missing graphics and black areas at startup and in the opening menus now draw correctly.

**Speed**

- 2D and 3D drawing and graphics transfers now repeat less work, so games run faster without giving up the restored graphics. Some slowdown remains. The ARM processor still runs at stock 1 GHz, with write-combining enabled on supported kernels.

**Stability**

- **Disconnected Wi-Fi hangs addressed.** MiSTer's Linux networking could stall the core while repeatedly searching for a Wi-Fi network, including during Lunar Knights' opening movie. Kickstart now stops those retries when Wi-Fi is disconnected. If you're connected, nothing changes, your saved network settings stay put, and normal Wi-Fi startup returns after a reboot.

**Earlier fixes carry over.** Castlevania: Dawn of Sorrow's bottom-screen flashes, Metroid Prime Pinball's missing screen section, Chrono Trigger's startup and sprite fixes, smoother movies, cartridge saves, touch input, and both TATE rotation directions.

## Install

1. Back up your saves.
2. Unzip to the root of your SD card, merging the `_Console` and `Scripts` folders.
3. Restart your MiSTer.
4. Run **Scripts → NDS\_Kickstart**.
5. Open **Console → NDS\_20260925** within five minutes. Miss the window and you'll need to run Kickstart again.
6. Set **Engine B (next Reset) → On**, then choose **Load NDS** and pick your game. If a game is already loaded, reset or reload it after changing Engine B.

Run Kickstart after every reboot and any time you return to the NDS core. Use the core, ARM helper and launcher that shipped together. Don't mix in files from older releases.

## TATE setup

Select **Video Layout → Top/Bottom** for stacked screens. Set **Video Rotation** opposite to the way the monitor physically turns: **90 CCW** for a clockwise turn, **90 CW** for a counterclockwise turn. D-pad, mouse and touch keep their normal directions on the turned monitor.

The MiSTer menu rotates separately. Add this under `[NDS]` in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

If the menu comes out upside down, use `osd_rotate=1`. Edit the existing `[NDS]` section if there is one, then save and reboot. The installer won't touch your INI.

## Known issues

- **Blank screen after upgrading?** Check that Engine B is On. See Read this first; other causes of a blank screen are still possible.
- **Shin Megami Tensei: Strange Journey can still freeze in the intro.**
- **GTA: Chinatown Wars may still show stray triangles.** The crash fix doesn't solve every graphics problem in it.
- **Some slowdown and uneven animation remain.** These improvements don't get every game to 60 FPS.
- **Movies and audio can still hitch.** Sound is still experimental.
- **Pokémon SoulSilver hasn't been tested with these fixes.** Platinum's character and room graphics are confirmed restored, but other Pokémon problems may remain ([issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16)).
- **Other graphics and compatibility problems remain.** Testing doesn't cover every game or a full playthrough. Demanding games may still slow down, glitch or crash.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is available through GitHub's **Source code (zip)** and **(tar.gz)** links. The installer and source tree each include internal checksums.

## Thanks

Special thanks to **InsaneFriend (GitHub: saneFriend)** for the Resident Evil: Deadly Silence, Kirby Mass Attack, Kirby Super Star Ultra, Grand Theft Auto: Chinatown Wars and Mega Man ZX fixes, along with earlier writable SPI firmware, ARM7 Wi-Fi boot-memory and cartridge-IR compatibility work. These Wi-Fi compatibility fixes do not add DS wireless multiplayer.

Built on work from the MiSTer community, FPGAzumSpass, the Nitro\_DarkSide and melonDS contributors, and heni. Thanks to skmp, the DreamSTer developer, for the write-combining suggestion. Full credits and licenses are in the source tree.
