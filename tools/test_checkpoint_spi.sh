#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-spi.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '372cba7ec2895140775b6e5e889d7001db50973a:rtl/nds_nitro_spi.vhd' > "$test_tmp/spi-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_spi.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PYCODE'
from pathlib import Path
import re
s=Path('spi-baseline.vhd').read_text()
Path('spi-reference.vhd').write_text(re.sub(r'\bnds_nitro_spi\b','nds_nitro_spi_reference',s))
PYCODE
nvc --std=2008 -a "$rtl/proc_bus_gba.vhd" spi-reference.vhd "$repo/rtl/nds_nitro_spi.vhd" "$repo/rtl/tb_nds_checkpoint_spi.vhd"
for latency in 1 97 1500; do
 for baud in 0 3; do
  for phase in 0 17 63; do
   nvc --std=2008 -e -gLATENCY=$latency -gBAUD=$baud -gPAUSE_OFFSET=$phase tb_nds_checkpoint_spi
   nvc --std=2008 -r tb_nds_checkpoint_spi --ieee-warnings=off --exit-severity=error
  done
 done
done
python3 - "$repo/rtl/nds_nitro_spi.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
for name,old,new in [
 ('lost-response',"if (fw_pend = '1' and fw_done = '1') then", "if (fw_pend = '1' and fw_done = '1' and stop_spi = '0') then"),
 ('live-lid',"if stop_spi = '0' then",'if true then'),
]:
 assert s.count(old)==1,name
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in lost-response live-lid; do
 nvc --std=2008 -a "$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_spi.vhd"
 nvc --std=2008 -e tb_nds_checkpoint_spi
 if nvc --std=2008 -r tb_nds_checkpoint_spi --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'SPI byte drain differs from baseline|SPI byte/response did not drain|lid wake escaped held SPI|SPI acknowledged outstanding work' "$mutation.log"
 echo "PASS: detected $mutation negative control"
done
