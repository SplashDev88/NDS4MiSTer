# NDS4MiSTer v0.9.0-rc.14

Fixes Y/C output over CRT-targeted Direct Video 1 and adds optional RetroTINK-4K profiles courtesy of Mr. Moro.

Fixes the reported black-and-white output when using a compatible Direct Video DAC with the MiSTer Addons YC Active Encoder Board for S-Video or composite.
Existing RGB configurations remain unchanged.

A separate optional download, courtesy of Mr. Moro, includes NDS Default and NDS Rotate RetroTINK-4K profiles and a custom background. The Rotate profile is for a physically rotated display: choose the core’s Scaler target and 90 CW/CCW rotation, with RT4K Pro RoTATE off.

To install or update:

1. Exit via **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, `Scripts/.NDS_Standalone`, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract the **Standalone ZIP** at the SD-card root, including hidden files, and merge/overwrite the program files.
4. Run **Scripts → NDS4MiSTer → Load *.NDS**.

Use the complete matching package. Saves and existing display/controller settings carry over. The install ZIP contains runtime files and license notices; corresponding sources and build records are a separate optional download for developers.

Known issues:

- Slowdown, audio hitches and graphical glitches remain possible. Full-speed gameplay and full-playthrough coverage are not guaranteed.
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz output are not supported. FPGA static timing remains unresolved.

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend, Corn, skmp, apeekaboo and everyone testing these builds.

No ROMs, BIOS files, saves or personal configuration are included.
