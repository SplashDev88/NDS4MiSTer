# NDS4MiSTer v0.9.0-rc.13

Modest speed improvements for **Final Fantasy Tactics A2**, **Pokémon Platinum**, **Pokémon HeartGold** and **Pokémon SoulSilver** (USA). Patches apply automatically to verified ROMs; your ROM files are never modified.

All rc12 improvements are retained. No FPGA changes.

## Install or update

1. Exit via **System → Reboot**.
2. Back up `Scripts/NDS4MiSTer.sh`, `Scripts/.NDS_Standalone`, `saves/NDS` and `config/NDS_storage.cfg`.
3. Extract the ZIP to the SD-card root (including hidden files) and overwrite.
4. Run **Scripts → NDS4MiSTer → Load *.NDS**.

Saves and settings carry over.

## Known issues

- Pokémon patches can cause minor timing or RNG differences; battles have had less testing.
- These new optimizations cover only verified USA revisions of the games listed above — see `VERSION_COVERAGE.md`.
- Slowdown and glitches are still possible in demanding scenes.
- Save states, wireless multiplayer, DSi mode and PAL 50 Hz output are not supported.

## Credits

Thanks to the MiSTer community, FPGAzumSpass, Nitro_DarkSide, melonDS, heni, InsaneFriend, Corn and skmp. No ROMs, BIOS files or saves are included.
