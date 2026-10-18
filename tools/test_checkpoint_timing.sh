#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 out=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-timing.XXXXXX")
 trap 'rm -rf "$out"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$out:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_timing.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$rtl/proc_bus_gba.vhd" "$rtl/reg_savestates.vhd" "$rtl/reggba_timer.vhd" "$rtl/gba_timer_module.vhd" "$rtl/gba_timer.vhd" "$rtl/reg_nds_display.vhd" "$rtl/nds_gpu_timing.vhd" "$repo/rtl/tb_nds_checkpoint_timing.vhd"
for prescaler in 0 1 2 3; do
 nvc --std=2008 -e -gPRESCALER=$prescaler tb_nds_checkpoint_timing
 nvc --std=2008 -r tb_nds_checkpoint_timing --ieee-warnings=off --exit-severity=error
done

python3 - "$rtl" <<'PYCODE'
from pathlib import Path
import sys
root=Path(sys.argv[1])
s=(root/'gba_timer_module.vhd').read_text()
for name,old,new in [
 ('unmasked-irq',"if (stop_count = '0') then",'if true then'),
 ('running-counter',"if stop_count = '0' then",'if true then'),
]:
 assert s.count(old)==1
 Path(name+'.vhd').write_text(s.replace(old,new))
s=(root/'nds_gpu_timing.vhd').read_text()
old="irq9_hblank <= '0';"
assert s.count(old)==1
Path('stuck-raster-pulse.vhd').write_text(s.replace(old,"if stop_timing = '0' then "+old+' end if;'))
PYCODE
for mutation in unmasked-irq running-counter stuck-raster-pulse; do
 # Restore the unmutated sources before each independent fault injection.
 nvc --std=2008 -a "$rtl/gba_timer_module.vhd" "$rtl/nds_gpu_timing.vhd" "$mutation.vhd" "$rtl/gba_timer.vhd" "$repo/rtl/tb_nds_checkpoint_timing.vhd"
 nvc --std=2008 -e tb_nds_checkpoint_timing
 if nvc --std=2008 -r tb_nds_checkpoint_timing --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'timer event escaped|timer counter changed|raster events or phase changed|events did not stop' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
