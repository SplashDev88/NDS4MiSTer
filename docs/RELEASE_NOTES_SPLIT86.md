# NDS4MiSTer v0.9.0-rc.7-split.8.6 beta

**Independent analog/digital screens, improved controller mapping and a persistent DS game clock.**

This is an experimental beta for testing. Back up your existing installation and saves before updating. FPGA timing violations remain, and longer sessions and additional boards still need testing.

## What's new

- **Independent displays.** Show Main on HDMI and Touch on native analog, or select a combined digital layout while analog stays on one 240p screen. Native analog output is selected automatically. Explicit scaled VGA continues to follow the digital layout.
- **Clearer display controls.** Use **Analog Screen** and **Digital Layout** for screen selection. Rotation and Direct Video Target are grouped under **Display options**. DV1 defaults to **CRT** for one screen; **Scaler** enables combined layouts.
- **Controller mapping waits for release.** Held or jittering triggers no longer skip successive prompts. Cancel or disconnect keeps the previous map. Existing maps remain compatible.
- **RTC / game clock.** Games and DS firmware share a clock initialized from MiSTer local time. DS date/time edits persist automatically and include elapsed time between launches. Set MiSTer's date, time and timezone before starting; relaunch after a system-time correction.

The package retains the tested split.8.6 binaries, renderer and 1 GHz ARM setting. Keep the files from this package together.

## Install or update

1. Exit the core using **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the entire hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.7-split.8.6_Standalone.zip** to the SD card root. Merge the `Scripts` folder, replace program files and include hidden files. Keep existing settings and maps.
4. Run **Scripts → NDS4MiSTer**, then **Load *.NDS**.

Saves remain in `saves/NDS`, including games loaded from USB or a network share. Keep ROM filenames unchanged. The package includes no ROMs, BIOS/firmware dumps, personal settings or kernel. Matching support modules are included for Linux 6.18.38-MiSTer and 5.15.1-MiSTer.

**Rollback:** Exit the core, move the beta launcher and support folder aside, then restore your backed-up launcher and complete support folder together. Keep current cartridge saves to retain progress. Preserve a copy of `NDS_rtc.cfg` if you want to return to your beta clock settings later.

## Display tips

- **Normal HDMI:** use `direct_video=0`.
- **DV1:** use `direct_video=1`, `dvi_mode=0` and `vga_scaler=0`, then relaunch after INI changes. Connect directly to the RetroTINK-4K when troubleshooting.
- **Combined DV1 layouts:** select **Display options → Direct Video Target → Scaler** and **1:1 (Sq. Pixel)** aspect correction on the RetroTINK. Native outputs use receiver rotation.
- **Black screen:** try Main/Touch or hold **F10 / Screen Peek**. Some games leave one screen blank.
- **PAL televisions:** native output is approximately 59.64 Hz. The TV must accept that timing; this beta does not add PAL 50 Hz output.

## Validation and known limits

Fresh install, upgrade and exact rollback passed on the test rig. HDMI, DV1 and analog layouts were exercised through RetroTINK-4K, with captured stereo audio checks. Bounded NSMB and Fire Emblem comparisons showed no crashes or protocol faults; Fire Emblem suspend/save/reload passed. RTC tests covered invalid clocks, late correction, DST and simulated offline time. Animal Crossing and White 2 had bounded in-game clock checks.

- Static timing remains unresolved. Successful routing and bounded tests do not establish long-term stability.
- Physical controllers/triggers, USER/OSD buttons, CRTs/adapters and SS1 composite/S-video need more current-build coverage.
- RTC alarms/periodic interrupts, save states and DS wireless multiplayer are not implemented.
- Slowdown, uneven animation, audio hitches, graphical errors and crashes remain possible. Strange Journey can freeze in its intro; GTA: Chinatown Wars can clip near the camera.

[Validation details](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.7-split.8.6/docs/release/VALIDATION_SPLIT86.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.7-split.8.6/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

## Files and credits

Download the **Standalone ZIP** and its **SHA-256 checksum** below. GitHub's **Source code** archives are for developers, not installation.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Full credits and licenses are in the source tree.
