#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
source_list="$repo_root/third_party/melonDS/src/ROMList.cpp"
output="$repo_root/fpga/mister_nitro_console_island/nds_save_profiles.hex"
tmp="${output}.tmp"

# SaveMemType 1 (512-byte tiny EEPROM) is the lookup default. Store explicit
# no-save entries plus every retail entry using types 2..7; this covers regular
# EEPROM/FRAM-compatible and flash parts in 4057 rows of a 4096x36 M10K ROM.
awk -F'[,{} ]+' '
  BEGIN { count = 0 }
  /^\t\{0x/ {
    type = substr($4, length($4), 1) + 0
    if ($4 == "0x00000000" || $4 ~ /0[2-7]$/) {
      code = substr($2, 3)
      printf "%s%X\n", code, type
      count++
    }
  }
  END {
    if (count > 4096) {
      print "save profile table exceeds 4096 entries" > "/dev/stderr"
      exit 1
    }
    while (count < 4096) {
      print "000000000"
      count++
    }
  }
' "$source_list" > "$tmp"

mv "$tmp" "$output"
echo "generated $output ($(wc -l < "$output" | tr -d ' ') entries)"
