# NDS4MiSTer v0.9.0-rc.7-split.8.6 beta

This beta adds controller mapping that waits for a complete release, a persistent
DS game clock, and independent native analog and digital output.

## Install or update

1. Exit the core through **System → Reboot**. This returns to normal MiSTer.
2. Before updating, back up `Scripts/NDS4MiSTer.sh`, the entire hidden
   `Scripts/.NDS_Standalone` folder, `saves/NDS`, and `config/NDS_storage.cfg`.
3. Extract the entire ZIP to the SD card root, merging **Scripts** and replacing
   its program files. Include hidden files. Keep existing settings and maps;
   the archive contains none. Do not delete the old folder before merging.
4. Run **Scripts → NDS4MiSTer**, choose **Load *.NDS**, and select a game.

A fresh install requires normal MiSTer but no earlier NDS release. Linux
6.18.38-MiSTer and 5.15.1-MiSTer have matching included support modules. The
launcher checks prerequisites; it does not install a kernel or change your INI.
Use the FPGA, host, supervisor and support files from one package together.

Games use cartridge saves in **saves/NDS on the SD card**, even when ROMs are
on USB or a network share. Keep ROM filenames unchanged to keep using their
matching saves. Save inside the game; save states are not included.

## Return to the previous release

Exit through **System → Reboot**, move the beta's launcher and entire hidden
support folder aside, and restore the backed-up launcher and folder together.
Leave cartridge saves in place to retain current progress. Keep a backup of
the beta's `NDS_rtc.cfg`; older releases ignore it. Restoring an older save
backup also restores older game progress, so do that only intentionally.

The backup method restores the exact previous installation and avoids mixing
support files. Retain the previous release ZIP and its checksum as well.

## Displays and a black screen

Native analog automatically shows one 240p screen. **Analog Screen** selects
Main or Touch; **Digital Layout** independently selects Main, Touch,
Side-by-side, or Top/bottom. Explicit `vga_scaler=1` still uses scaled VGA.

For DV1, use `direct_video=1`, `dvi_mode=0`, and `vga_scaler=0` with a compatible
receiver. **Direct Video Target: CRT** limits DV1 to one screen; **Scaler**
enables combined layouts. This option is also available through **F4: Advanced
Options** during startup. Normal HDMI uses `direct_video=0`.

If a game shows black, try the other Main/Touch screen or hold **F10 / Screen
Peek**. Some games intentionally leave one screen blank. Native output is
approximately 59.64 Hz; a PAL television must accept that timing. This beta
does not add PAL 50 Hz output. Cable, adapter and MiSTer profile requirements
still apply. See **QUICK_START.txt** for details.

## Controller mapping and clock

Use **System → Define NDS buttons**. Each input needs a full press and release
before advancing. **Esc/OSD** cancels; **Space/USER** skips. Existing maps remain
valid. **Cycle Video Layout** changes the layout once per press; **Screen Peek**
shows the other screen only while held. Choose the intended action when mapping.

Set MiSTer's local date, time and timezone before launching. The DS clock is
seeded once per session and continues through menus, reset and lid sleep.
Clock edits made inside DS firmware persist automatically in the hidden kit's
**NDS_rtc.cfg**; keep it during upgrades. If MiSTer synchronizes time after the
core starts, exit and relaunch to adopt the correction. See **GAME_CLOCK.md**
for timezone behavior and how to return to the default clock.

## Scope

RTC alarms/periodic interrupts and save-state clock restoration are unsupported.
Static FPGA timing still reports violations. Physical controllers, CRTs/adapters,
long sessions and all game-specific timed events are not fully qualified.
Games may slow down, hitch, glitch or crash; this is not a 60 FPS guarantee.

Read **RELEASE_NOTES.md** and the accompanying qualification report. Licenses
and third-party notices are included. ROMs, BIOS, user firmware, saves, maps,
settings and a Linux kernel are not included. Source and issue reporting:
[NDS4MiSTer](https://github.com/SplashDev88/NDS4MiSTer).
