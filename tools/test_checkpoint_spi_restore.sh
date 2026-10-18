#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-spi-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show 'a5bbabcac194b8e3a5f35dd8129a711efc3da326:rtl/nds_nitro_spi.vhd' > "$test_tmp/spi-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  -e SPI_SCENARIOS="${SPI_SCENARIOS:-0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17}" \
  -e SPI_NEGATIVES="${SPI_NEGATIVES:-1}" \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_spi_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PYCODE'
from pathlib import Path
import re
s=Path('spi-baseline.vhd').read_text()
Path('spi-reference.vhd').write_text(re.sub(r'\bnds_nitro_spi\b','nds_nitro_spi_reference',s))
PYCODE
nvc --std=2008 -a "$p/proc_bus_gba.vhd" spi-reference.vhd "$repo/rtl/nds_nitro_spi.vhd" "$repo/rtl/tb_nds_checkpoint_spi_restore.vhd"
for scenario in $SPI_SCENARIOS; do
 baud=$((scenario % 2 * 3))
 nvc --std=2008 -e -gSCENARIO="$scenario" -gBAUD="$baud" tb_nds_checkpoint_spi_restore
 nvc --std=2008 -r tb_nds_checkpoint_spi_restore --exit-severity=error
 cp spi.state "spi-$scenario.state"; cp spi.trace "spi-$scenario.trace"
 for gap in 0 7; do
  nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gBAUD="$baud" -gGAP="$gap" tb_nds_checkpoint_spi_restore
  nvc --std=2008 -r tb_nds_checkpoint_spi_restore --exit-severity=error
 done
done
echo 'PASS: product SPI fresh-process continuations and pinned/default-disabled baseline comparisons'
if [[ $SPI_NEGATIVES == 0 ]]; then exit; fi
python3 - "$repo/rtl/nds_nitro_spi.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-command': ('fw_cmd <= checkpoint_write_data(31 downto 24);', "fw_cmd <= (others => '0');"),
 'lost-address': ('fw_a <= unsigned(checkpoint_write_data(23 downto 0));', "fw_a <= (others => '0');"),
 'lost-touch': ('tsc_conv <= unsigned(checkpoint_write_data(29 downto 18));', "tsc_conv <= (others => '0');"),
 'lost-mic': ('mic_noise <= unsigned(checkpoint_write_data(15 downto 0));', 'mic_noise <= x"ACE1";'),
 'lost-lid': ('lid_was_closed <= checkpoint_write_data(16);', "lid_was_closed <= '0';"),
 'lost-pm': ('pm_hold <= checkpoint_write_data(18);', "pm_hold <= '0';"),
 'partial-ready': ('restore_count = 9 and restore_error', 'restore_count > 0 and restore_error'),
 'lost-order': ('checkpoint_address = restore_count and', 'true and'),
 'invalid-busy': ('and x"34FC"', 'and x"347C"'),
 'live-write': ("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'", "EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
}
for name,(old,new) in mutations.items():
 assert s.count(old)==1,(name,s.count(old))
 Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in lost-command lost-address lost-touch lost-mic lost-lid lost-pm partial-ready lost-order invalid-busy live-write; do
 case "$mutation" in
  lost-touch) scenario=11;; lost-mic) scenario=13;; lost-pm) scenario=1;; *) scenario=7;;
 esac
 check_image=true
 case "$mutation" in lost-command|lost-address|lost-touch|lost-mic|lost-lid|lost-pm) check_image=false;; esac
 mkdir "negative-$mutation"
 cp "spi-$scenario.state" "negative-$mutation/spi.state"
 cp "spi-$scenario.trace" "negative-$mutation/spi.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/spi-reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_spi_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gBAUD=3 -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_spi_restore
 if nvc --std=2008 -r tb_nds_checkpoint_spi_restore --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'SPI restored word mismatch|SPI continuation mismatch|SPI partial restore accepted|SPI invalid restore accepted|SPI live restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
