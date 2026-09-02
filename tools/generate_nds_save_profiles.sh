#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
source_list="$repo_root/third_party/melonDS/src/ROMList.cpp"
prefix_output="$repo_root/fpga/mister_nitro_console_island/nds_save_profile_prefix.hex"
entry_output="$repo_root/fpga/mister_nitro_console_island/nds_save_profile_entries.hex"

# SaveMemType 1 (512-byte tiny EEPROM) is the lookup default. Store explicit
# no-save entries plus every retail type 2..7. A compact prefix ROM locates a
# short bucket in the low-code/type ROM; this preserves exact lookup behavior
# while reducing the physical table from roughly sixteen to ten M10Ks.
python3 "$repo_root/tools/generate_nds_save_profiles.py" \
    "$source_list" "$prefix_output" "$entry_output"
