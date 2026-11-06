# NDS4MiSTer v0.9.0-rc.14

[Download ZIP](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.14/NDS4MiSTer_v0.9.0-rc.14_Standalone.zip) · [Release page](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.14)

Adds Mario Kart DS gameplay optimizations and fixes independent Y/C output
over CRT-targeted Direct Video 1.

## Mario Kart DS

- Optimizes 31 racing courses for the exact retail revision-0 USA, Europe,
  Japan and Korea versions. Improvements vary by course and scene.
- Preserves the original ROM and normal save identity. Unknown or modified
  versions keep the original game stream.
- The first uncached preparation can take about 12 minutes on MiSTer.
  Later loads reuse verified prepared assets.
- GBA Sky Garden keeps its original course data. The shared helper can still
  slow its race-clock advancement slightly; no Sky Garden speedup is claimed.

## Direct Video Y/C

CRT-targeted DV1 can now encode its selected DS screen independently of the
native analog output. This fixes the missing-color case with compatible
Direct Video DACs and active Y/C adapters. Scaler-targeted DV1 retains RGB.

For a compatible DAC and active Y/C board, select **Direct Video Target → CRT**
and keep `vga_mode=svideo`, including when using the board's composite socket.
Use the adapter's Direct Video setting and the appropriate MiSTer INI profile.
See [Quick start](docs/STANDALONE_QUICK_START.txt) for the NTSC setup. This does not add PAL 50 Hz output.

## Optional RetroTINK-4K profiles

Includes a separate profile download courtesy of **Mr. Moro**, with
**NDS Default** and **NDS Rotate** profiles and a custom background.
The Rotate profile is for a physically rotated display: choose the core's
Scaler target and 90 CW/CCW rotation, with RT4K Pro RoTATE off.
See [Mr. Moro profile guide](docs/release/RETROTINK_MR_MORO.md) for installation and the contributor's setup notes.

## Install or update

1. Exit via **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, `Scripts/.NDS_Standalone`, `saves/NDS`
   and `config/NDS_storage.cfg`.
3. Extract the **Standalone ZIP** at the SD-card root, including hidden files,
   and merge/overwrite the program files.
4. Run **Scripts → NDS4MiSTer → Load *.NDS**.

Use the complete matching package. Saves and existing display/controller
settings carry over. The install ZIP contains runtime files and license
notices; corresponding sources and build records are a separate optional
download for developers.

## Known issues

- Existing RC13 game and FMV optimizations are retained. Exact version
  coverage varies; see [version coverage](docs/release/VERSION_COVERAGE_RC14.md).
- Slowdown, audio hitches and graphical glitches remain possible. Mario Kart
  results do not establish full-speed gameplay or full-playthrough coverage.
- Italian, Spanish, Japanese and Korean Platinum gameplay validation remains
  incomplete. The full Mario Kart course campaign was not repeated in each
  region, and all mission/battle modes remain unqualified.
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz output are not
  supported. FPGA static timing remains unresolved.

## Credits

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni,
InsaneFriend, Corn, skmp, apeekaboo and everyone testing these builds.
No ROMs, BIOS files, saves or personal configuration are included.
