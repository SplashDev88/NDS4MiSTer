#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 out=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-sound.XXXXXX")
 trap 'rm -rf "$out"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$out:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_sound.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$rtl/proc_bus_gba.vhd" "$repo/rtl/tb_nds_sound_fetch_state_ram.vhd" "$rtl/nds_sound.vhd" "$repo/rtl/tb_nds_checkpoint_sound.vhd"
for config in "1 0 0 1" "16 0 1 4" "16 1 1 31" "16 2 0 4" "16 2 1 1" "16 2 1 31" "16 3 1 4"; do
 read -r channels format table latency <<< "$config"
 nvc --std=2008 -L . -e -gCHANNELS=$channels -gFORMAT=$format -gTABLE_RAM=$table -gLATENCY=$latency tb_nds_checkpoint_sound
 nvc --std=2008 -L . -r tb_nds_checkpoint_sound --ieee-warnings=off --exit-severity=error
done

python3 - "$rtl/nds_sound.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
changes={
 'lost-response': ("if (mb_done = '1') then", "if (mb_done = '1' and stop_playback = '0') then"),
 'running-mixer': ("elsif (ce = '1' and stop_playback = '0') then", "elsif (ce = '1') then"),
}
for name,(old,new) in changes.items():
 assert s.count(old)==1
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in lost-response running-mixer; do
 nvc --std=2008 -L . -a "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_sound.vhd"
 nvc --std=2008 -L . -e tb_nds_checkpoint_sound
 if nvc --std=2008 -L . -r tb_nds_checkpoint_sound --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 if [[ $mutation == lost-response ]]; then
  grep -F 'sound failed to drain before deadline' "$mutation.log"
 else
  grep -E 'sound playback advanced during hold|resumed stereo sample differs|sound sample cadence advanced' "$mutation.log"
 fi
 echo "PASS: detected $mutation negative control"
done
