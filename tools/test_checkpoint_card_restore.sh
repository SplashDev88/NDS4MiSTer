#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-card-restore.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 git -C "$repo" show '8485564d63e50b0ff8466fc9dce5e08bdacb4aab:third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd' > "$test_tmp/card-baseline.vhd"
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  -e CARD_SCENARIOS="${CARD_SCENARIOS:-0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23}" \
  -e CARD_PROFILES="${CARD_PROFILES:-0,1,1 1,4,17 0,7,97}" -e CARD_NEGATIVES="${CARD_NEGATIVES:-1}" \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_card_restore.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
python3 - <<'PYCODE'
from pathlib import Path
import re
s=Path('card-baseline.vhd').read_text()
Path('card-reference.vhd').write_text(re.sub(r'\bnds_card\b','nds_card_reference',s))
PYCODE
nvc --std=2008 -a "$p/proc_bus_gba.vhd" card-reference.vhd "$p/nds_card.vhd" "$repo/rtl/tb_nds_checkpoint_card_restore.vhd"
for profile in $CARD_PROFILES; do
 IFS=, read -r owner prefetch latency <<< "$profile"
 for scenario in $CARD_SCENARIOS; do
  args=(-gSCENARIO="$scenario" -gOWNER="$owner" -gPREFETCH="$prefetch" -gLATENCY="$latency")
  nvc --std=2008 -e "${args[@]}" tb_nds_checkpoint_card_restore
  nvc --std=2008 -r tb_nds_checkpoint_card_restore --ieee-warnings=off --exit-severity=error
  if [[ $profile == 1,4,17 ]]; then cp card.state "card-$scenario.state";cp card.trace "card-$scenario.trace";fi
  for gap in 0 7; do
   nvc --std=2008 -e "${args[@]}" -gRESTORING=true -gGAP="$gap" tb_nds_checkpoint_card_restore
   nvc --std=2008 -r tb_nds_checkpoint_card_restore --ieee-warnings=off --exit-severity=error
  done
 done
done
echo 'PASS: cartridge fresh-process continuations, pinned-source equality and independent ROM/save expectations'
if [[ $CARD_NEGATIVES == 0 ]]; then exit;fi
python3 - "$p/nds_card.vhd" <<'PYCODE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-prefetch': ('pf(to_integer(checkpoint_address)-15) <= checkpoint_write_data;', "pf(to_integer(checkpoint_address)-15) <= (others => '0');"),
 'lost-word': ('romdata <= checkpoint_write_data;', "romdata <= (others => '0');"),
 'lost-pacing': ('delay_cnt <= unsigned(checkpoint_write_data(19 downto 0));', "delay_cnt <= (others => '0');"),
 'lost-state': ("state <= tstate'val(to_integer(unsigned(checkpoint_write_data(18 downto 16))));", 'state <= IDLE;'),
 'lost-toggle': ('backup_write_toggle <= checkpoint_write_data(30);', "backup_write_toggle <= '0';"),
 'lost-command': ('sram_cmd <= checkpoint_write_data(19 downto 12);', "sram_cmd <= (others => '0');"),
 'lost-save-address': ('sram_addr <= unsigned(checkpoint_write_data(19 downto 0));', "sram_addr <= (others => '0');"),
 'lost-ir': ('ir_cmd <= checkpoint_write_data(27 downto 20);', "ir_cmd <= (others => '0');"),
 'lost-mode': ('cmd_mode <= unsigned(checkpoint_write_data(25 downto 24));', 'cmd_mode <= "10";'),
 'lost-erase-count': ('erase_remaining <= unsigned(checkpoint_write_data(16 downto 0));', "erase_remaining <= (others => '0');"),
 'partial-ready': ('restore_count = CHECKPOINT_WORDS and checkpoint_write', 'restore_count > 0 and checkpoint_write'),
 'lost-order': ('checkpoint_address = restore_count and', 'true and'),
 'invalid-reserved': ('d(31 downto 30) = "00"', "d(30) = '0'"),
 'live-write': ("EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0'", "EXPERIMENTAL_CHECKPOINT and checkpoint_restore = '1' else '0'"),
}
for name,(old,new) in mutations.items():
 assert s.count(old)==1,(name,s.count(old));Path(name+'.vhd').write_text(s.replace(old,new))
PYCODE
for mutation in lost-prefetch lost-word lost-pacing lost-state lost-toggle lost-command lost-save-address lost-ir lost-mode lost-erase-count partial-ready lost-order invalid-reserved live-write; do
 check_image=false
 case "$mutation" in
  lost-prefetch|lost-word|lost-state) scenario=3;; lost-pacing) scenario=1;;
  lost-toggle|lost-command|lost-save-address) scenario=13;; lost-ir) scenario=18;;
  lost-mode) scenario=10;; lost-erase-count) scenario=19;; *) scenario=3;check_image=true;;
 esac
 mkdir "negative-$mutation"
 cp "card-$scenario.state" "negative-$mutation/card.state";cp "card-$scenario.trace" "negative-$mutation/card.trace"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/proc_bus_gba.vhd" /test/card-reference.vhd "/test/$mutation.vhd" "$repo/rtl/tb_nds_checkpoint_card_restore.vhd"
 nvc --std=2008 -e -gRESTORING=true -gSCENARIO="$scenario" -gOWNER=1 -gPREFETCH=4 -gLATENCY=17 -gCHECK_IMAGE="$check_image" tb_nds_checkpoint_card_restore
 if nvc --std=2008 -r tb_nds_checkpoint_card_restore --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'card restored word mismatch|card continuation mismatch|card resumed ROM word wrong|card partial restore accepted|card invalid restore accepted|card live restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
