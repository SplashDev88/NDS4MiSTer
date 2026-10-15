# NDS4MiSTer v0.9.0-rc.8

**Separate screen layouts on HDMI and analog outputs, better controller mapping and persistent RTC / DS clock support.**

Back up your installation and saves before updating.

## What's new

- **Separate screen layouts on HDMI and analog outputs.** HDMI and the analog RCA outputs can show different screens, such as Main on HDMI and Touch on analog. HDMI can also show both screens together while analog shows one. Analog runs at native 240p automatically. With `vga_scaler=1`, analog copies HDMI instead.
- **Reorganized core menu.** Rotation and Direct Video Target are now under **Display options**. **Digital Layout** sets what HDMI shows. **Analog Screen** sets which screen goes to the RCA outputs.
- **Controller mapping waits for button release.** You must release each button before the next button is mapped. This prevents duplicate mappings. Cancelling or disconnecting keeps your old map. Existing maps still work.
- **Persistent RTC / DS clock support.** The clock starts from MiSTer's local time and keeps any date and time you set on the DS, including time that passes between sessions. Set MiSTer's date, time and timezone first. If you correct MiSTer's time later, relaunch.

Keep all files from this package together.

## Install or update

1. Exit the core with **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, the hidden `Scripts/.NDS_Standalone` folder, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract **NDS4MiSTer_v0.9.0-rc.8_Standalone.zip** to the SD card root. Include hidden files, merge the `Scripts` folder and overwrite program files. Your settings and maps are kept.
4. Run **Scripts → NDS4MiSTer**, then **Load \*.NDS**.

Saves stay in `saves/NDS`, including for games loaded from USB or a network share. Don't rename ROMs. No ROMs, BIOS/firmware, settings or kernel are included. Support modules are included for Linux 6.18.38-MiSTer and 5.15.1-MiSTer.

**Rollback:** Exit the core. Move the new launcher and `.NDS_Standalone` folder aside, then restore your backed-up launcher and folder together. Keep your current saves. To return to this release's clock settings later, keep a copy of `NDS_rtc.cfg`.

## Display tips

Put these settings in an `[NDS]` section of `MiSTer.ini` so they only apply to this core. Relaunch after changing them.

- **HDMI:**

  ```ini
  [NDS]
  direct_video=0
  ```

- **Direct Video (DV1):**

  ```ini
  [NDS]
  direct_video=1
  dvi_mode=0
  vga_scaler=0
  ```

  Direct Video Target defaults to **CRT** (one screen). For both screens, set it to **Scaler** and set the RetroTINK's aspect correction to **1:1 (Sq. Pixel)**. If something goes wrong, connect directly to the RetroTINK-4K.
- **Rotation:** in single-screen native modes, rotate on your scaler or TV.
- **Black screen:** switch between Main and Touch, or hold **F10** (Screen Peek). Some games leave one screen blank.
- **PAL TVs:** analog output is about 59.64 Hz, so your TV must support it. There is no 50 Hz mode.

## Testing and known limits

Tested: fresh install, upgrade and rollback; HDMI, DV1 and analog output through a RetroTINK-4K, including audio; short runs of NSMB and Fire Emblem with no crashes, plus Fire Emblem suspend, save and reload; clock edge cases (invalid time, late correction, DST, offline time); in-game clocks in Animal Crossing and Pokémon White 2.

- Not implemented: clock alarms and interrupts, save states, wireless multiplayer.
- Slowdown, stutter, audio hitches, graphical errors and crashes can happen. Strange Journey can freeze in its intro. GTA: Chinatown Wars can clip near the camera.

[Validation details](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.8/docs/release/VALIDATION_SPLIT86.md) · [Clock behavior](https://github.com/SplashDev88/NDS4MiSTer/blob/v0.9.0-rc.8/docs/GAME_CLOCK.md) · [Report a bug](https://github.com/SplashDev88/NDS4MiSTer/issues/new?template=bug_report.yml)

## Files and credits

Download the **Standalone ZIP** and its **SHA-256 checksum** below. GitHub's **Source code** archives are for developers, not for installing.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend (saneFriend), Corn and skmp. Full credits and licenses are in the source tree.
