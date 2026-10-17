# NDS4MiSTer v0.9.0-rc.9

**Smoother Castlevania play, improved rendering and frame delivery, and offline DS clock support.**

This packages the tested Beta12 runtime at **1 GHz**. Back up your installation and saves before updating.

## What's new since rc.8

- **Castlevania: Dawn of Sorrow performance improvements.** Rendering and CPU work distribution have been optimized, with particular testing in the cave/bat area and the enemy-heavy combat room near the Lost Village save room. Improvements vary by scene and game.
- **Improved graphics delivery, including New Super Mario Bros.** Rendering reuses unchanged work where it is safe and reduces unnecessary pixel conversion. Frame skipping remains off; this does not guarantee that every frame finishes on time.
- **Offline DS clock startup.** If MiSTer's date is unavailable or outside 2000–2099, the DS clock starts from January 1, 2000. Date/time edits persist. Set MiSTer's local time and timezone when possible, then relaunch. Without usable system time, time spent powered off cannot be recovered.
- **Save and compatibility fixes.** Includes flash-save page wrapping and long-transfer fixes, ARM9 VRAM/OAM readback fixes, and graphics-command/DMA ordering work. This does not resolve every game issue.

Independent HDMI/analog layouts, controller mapping that waits for button release, touch rotation, Screen Peek, microphone blowing input and persistent clock edits are retained.

## Measured scene improvements

Recorded at **1 GHz**, during the optimization work included in this release:

| Game and scene | Earlier measurement | Later measurement | What was counted |
| --- | ---: | ---: | --- |
| Castlevania: cave/bat room left of the save room | 14.5–14.8/sec | **22.6/sec in Beta12** | Completed screen updates |
| Castlevania: upper-right Warg combat room | 12.7/sec | **21.9/sec in Beta12** | Completed screen updates |
| NSMB: World 2-5, repeated jumping | About 30/sec | **54.5–55.5/sec** | Visible changes around Mario |

Castlevania's earlier measurements used Performance Beta6; enemy phases vary,
especially in combat. NSMB's outdoor comparison measured the introduction of
full-rate drawing in Performance Beta5, a change retained in Beta12. It was not
rerun outdoors on the final Beta12 binary. Beta12's latest World 1 castle control
delivered **44.8 completed screen updates/sec**; that heavier scene should not be
confused with the outdoor result.

These are development milestones, **not a direct rc.8-to-rc.9 FPS benchmark**.
Completed screen updates can reuse images, while visible-change counts depend
on animation and the image detector. Neither is a guarantee of whole-game FPS.
[Measurements and baselines](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/release/VALIDATION_BETA12_RC9.md#performance-examples).

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the entire hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.9_Standalone.zip** to the SD card root. Include hidden files, merge `Scripts` and overwrite program files. Existing settings and maps are kept.
4. Run **Scripts → NDS4MiSTer**, then **Load \*.NDS**.

Keep the launcher and all support files from this package together. The retained host may still display **rc.8** internally; the release launcher and manifest identify **rc.9 / Beta12**.

Saves stay in `saves/NDS`, including for games loaded from USB or a network share. Do not rename ROMs. No ROMs, BIOS/firmware dumps, saves, settings or kernel image are included. Support modules for Linux **6.18.38-MiSTer** and **5.15.1-MiSTer** are included.

**Coming from the dated private Beta12:** that launcher uses a separate settings folder. The public kit uses its own existing settings, or fresh defaults. Shared game saves remain available. See the included README before moving settings between kits.

**Rollback:** Exit cleanly and restore your backed-up launcher and hidden folder together. Keep current game saves. rc.8 cannot read the new offline `NDS-RTC-v2` clock file: restore its clock-file backup, or move the v2 file aside and set MiSTer's local time before returning to rc.8. Keep a copy if you want to return to this beta's clock settings.

## Testing and known limits

The unchanged Beta12 runtime has automated renderer checks, repeated Castlevania and NSMB comparisons, and a fresh private-package launch test through the RetroTINK-4K rig. The public package has separate archive and installation checks documented below. Long sessions, all games and multiple boards are not fully qualified.

- **60 FPS has not been achieved.** Slowdown, uneven animation, audio hitches, graphics errors and crashes remain possible. Gains from separate optimization tests are not a measured rc.8-to-rc.9 percentage.
- FPGA static timing closure remains unresolved.
- Native analog output remains about **59.64 Hz**; there is no PAL 50 Hz mode.
- Save states, persistent lid-close resume, RTC alarms/interrupts, wireless multiplayer and DSi mode are not implemented.
- The experimental 1.2 GHz clock and rejected post-Beta12 changes are not included.

[Validation details](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/release/VALIDATION_BETA12_RC9.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.9/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

Download the **Standalone ZIP** and its **SHA-256 checksum**. GitHub's **Source code** archives are for developers, not for installing. Display setup examples are in `QUICK_START.txt`.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Full credits and licenses are included.
