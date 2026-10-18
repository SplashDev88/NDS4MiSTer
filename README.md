# NDS4MiSTer v0.9.0-rc.9

**Modest speed improvements, game compatibility fixes, and offline DS clock support fix.**

## What's new since rc.8

- **Faster rendering and graphics.** Better CPU load balancing, plus skipping redundant rendering and pixel conversion. Improves Castlevania: Dawn of Sorrow and New Super Mario Bros.; gains vary by scene.
- **DS clock fallback.** If MiSTer's date is missing or outside 2000–2099, the clock starts at Jan 1, 2000. Changes you make to the date/time are saved. For accurate time, set MiSTer's local time and timezone, then relaunch. Without a valid system clock, time spent powered off can't be tracked.
- **Game compatibility and save fixes.** Includes Wizard of Oz menu-label and Mushroom Men menu corrections, Ninja Reflex and Jackass improvements, and shared save/graphics fixes detailed below. Huge thanks to Insanefriend for these.

## Game fixes and compatibility

- **The Wizard of Oz: Beyond the Yellow Brick Road ([#34](https://github.com/SplashDev88/NDS4MiSTer/issues/34)):** fixed the missing **New Game** and **Continue** labels in the tested menus by correcting sprite-memory reads. Movement and temporary save/reload also passed. Later menus, permanent saves and every reported flicker case are not fully verified.
- **Mushroom Men: Rise of the Fungi ([#31](https://github.com/SplashDev88/NDS4MiSTer/issues/31)):** corrected the misplaced screens, duplicated menu bands and missing menu pixels in the tested sequence. Graphics backpressure and event-queue changes also kept memory bounded during the recorded checks. The first checkpoint saved and reloaded correctly; later gameplay and the original unspecified save failure need more coverage.
- **Ninja Reflex ([#24](https://github.com/SplashDev88/NDS4MiSTer/issues/24)):** improved the tested geometry-backlog behavior. A 56-minute session reached all six category menus, completed **Firefly Catch** and retained its completion mark after a cold restart, with no transport faults. This does not establish that every reported invisible-menu case is fixed.
- **Jackass the Game ([#40](https://github.com/SplashDev88/NDS4MiSTer/issues/40)):** preserves fast geometry-query handling through the tested phone transition and tutorial. Testing reached player control and another NPC conversation. Long transitions can still occur; mission completion is not verified.

**Shared fixes:** corrected flash-save page wrapping and long save-chip reads;
restored VRAM bank-register reads used when games restore texture mappings;
preserved graphics commands during large bursts; and fixed a lost graphics-DMA
request at a pause boundary. The VRAM correction includes the earlier King Kong
fix, but its original texture report is not yet verified as resolved.

**Save/reload checks** also passed for Spyro: Shadow Legacy and Lunar Knights,
with Final Fantasy Tactics A2 and Pokémon White 2 used as regression checks.
Their original reported save errors were not all reproduced, so these are
validation results rather than claims that every save issue is fixed.

These checks were recorded during the bug-fix work inherited by this runtime;
the final rc9 renderer did not receive a new full sweep of every listed game.
[Issue-by-issue scope and remaining work](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/release/RC9_GAME_FIXES.md).

## Measured scene improvements

Recorded at **1 GHz**, during the optimization work included in this release:

| Game and scene | Earlier measurement | Later measurement | What was counted |
| --- | ---: | ---: | --- |
| Castlevania: cave/bat room left of the save room | 14.5–14.8/sec | **22.6/sec in rc9** | Completed screen updates |
| Castlevania: upper-right Warg combat room | 12.7/sec | **21.9/sec in rc9** | Completed screen updates |
| NSMB: World 2-5, repeated jumping | About 30/sec | **54.5–55.5/sec** | Visible changes around Mario |

These are development milestones, **not a direct rc.8-to-rc.9 FPS benchmark**.
Completed screen updates can reuse images, while visible-change counts depend
on animation and the image detector. Neither is a guarantee of whole-game FPS.
[Measurements and baselines](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/release/VALIDATION_BETA12_RC9.md#performance-examples).

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the entire hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.9_Standalone.zip** to the SD card root. Include hidden files, merge `Scripts` and overwrite program files. Existing settings and maps are kept.
4. Run **Scripts → NDS4MiSTer**, then **Load \*.NDS**.

Keep the launcher and all support files from this package together. The retained host may still display **rc.8** internally; the release launcher and manifest identify **rc9**.

Saves stay in `saves/NDS`, including for games loaded from USB or a network share. Do not rename ROMs. No ROMs, BIOS/firmware dumps, saves, settings or kernel image are included. Support modules for Linux **6.18.38-MiSTer** and **5.15.1-MiSTer** are included.

**Rollback:** Exit cleanly and restore your backed-up launcher and hidden folder together. Keep current game saves. rc.8 cannot read the new offline `NDS-RTC-v2` clock file: restore its clock-file backup, or move the v2 file aside and set MiSTer's local time before returning to rc.8. Keep a copy if you want to return to this beta's clock settings.

## Testing and known limits

The unchanged rc9 runtime has automated renderer checks, repeated Castlevania and NSMB comparisons, and a fresh private-package launch test through the RetroTINK-4K rig. The public package has separate archive and installation checks documented below. Long sessions, all games and multiple boards are not fully qualified.

- **60 FPS has not been achieved.** Slowdown, uneven animation, audio hitches, graphics errors and crashes remain possible. Gains from separate optimization tests are not a measured rc.8-to-rc.9 percentage.
- FPGA static timing closure remains unresolved.
- Native analog output remains about **59.64 Hz**; there is no PAL 50 Hz mode.
- Save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer and DSi mode are not implemented.

[Validation details](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/release/VALIDATION_BETA12_RC9.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

Download the **Standalone ZIP** and its **SHA-256 checksum** from [Releases](https://github.com/SplashDev88/NDS4MiSTer/releases). GitHub's **Source code** archives are for developers, not for installing. Display setup examples are in `QUICK_START.txt`.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Full credits and licenses are included.

For developers: [architecture](docs/architecture.md), [rc9 evidence](docs/PRIVATE_BETA_20261017.md) and [post-freeze audit](docs/PERFORMANCE_AUDIT_FOLLOWUP_20261017.md).
