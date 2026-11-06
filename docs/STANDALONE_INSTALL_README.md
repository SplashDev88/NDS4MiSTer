# NDS4MiSTer v0.9.0-rc.14

Fixes independent Y/C output over CRT-targeted Direct Video 1 and includes
optional RetroTINK-4K profiles courtesy of Mr. Moro. Existing RC13 game
optimizations are retained.

## Direct Video Y/C

CRT-targeted DV1 can now encode its selected DS screen independently of the
native analog output. This fixes the reported black-and-white output when
using a compatible Direct Video DAC with the
[MiSTer Addons YC Active Encoder Board](https://misteraddons.com/products/yc-active-encoder-board)
for S-Video or composite. Scaler-targeted DV1 retains RGB.

For this DAC and MiSTer Addons encoder setup, select **Direct Video Target → CRT**
and keep `vga_mode=svideo`, including when using the board's composite socket.
Use the adapter's Direct Video setting and the appropriate MiSTer INI profile.
See `QUICK_START.txt` for the NTSC setup. This does not add PAL 50 Hz output.

## Optional RetroTINK-4K profiles

Includes a separate profile download courtesy of **Mr. Moro**, with
**NDS Default** and **NDS Rotate** profiles and a custom background.
The Rotate profile is for a physically rotated display: choose the core's
Scaler target and 90 CW/CCW rotation, with RT4K Pro RoTATE off.
See `RETROTINK_MR_MORO.md` for installation and the contributor's setup notes.

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
  coverage varies; see `VERSION_COVERAGE.md`.
- Slowdown, audio hitches and graphical glitches remain possible.
  Full-speed gameplay and full-playthrough coverage are not guaranteed.
- Italian, Spanish, Japanese and Korean Platinum gameplay validation remains
  incomplete.
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz output are not
  supported. FPGA static timing remains unresolved.

## Credits

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni,
InsaneFriend, Corn, skmp, apeekaboo and everyone testing these builds.
No ROMs, BIOS files, saves or personal configuration are included.
