#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-math.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iverilog_bin=${IVERILOG:-iverilog}
vvp_bin=${VVP:-vvp}
git -C "$repo" show '62a5907ed2417f394c00720f8924604abd32d142:rtl/nds_nitro_arm9_math_unit.sv' > "$test_tmp/baseline.sv"
python3 - "$test_tmp" "$repo" <<'PYCODE'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]);r=Path(sys.argv[2]);s=(p/'baseline.sv').read_text()
(p/'reference.sv').write_text(re.sub(r'\bnds_nitro_arm9_math_unit\b','nds_nitro_arm9_math_unit_reference',s))
s=(r/'rtl/nds_nitro_arm9_math_unit.sv').read_text()
for name,old,new in [
 ('early-reply','!bus_active &&\n        !bus_response_pending && !done && !product_signature_valid &&',''),
 ('early-work','!div_running && !sqrt_running && !div_busy && !sqrt_busy',"1'b1"),
]:
 assert s.count(old)==1,name
 (p/(name+'.sv')).write_text(s.replace(old,new))
PYCODE
run_case() {
 local source=$1 product=$2
 "$iverilog_bin" -g2012 -s tb_nds_checkpoint_math -Ptb_nds_checkpoint_math.PRODUCT="$product" \
  -o "$test_tmp/test" "$source" "$test_tmp/reference.sv" "$repo/rtl/tb_nds_checkpoint_math.sv" 2> "$test_tmp/compile.log" || { cat "$test_tmp/compile.log";return 1; }
 "$vvp_bin" "$test_tmp/test"
}
for product in 0 1; do run_case "$repo/rtl/nds_nitro_arm9_math_unit.sv" "$product";done
for mutation in early-reply early-work; do
 if run_case "$test_tmp/$mutation.sv" 1 > "$test_tmp/$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'math idle before MMIO reply retired|math idle before arithmetic retired|math idle was not a stable capture boundary' "$test_tmp/$mutation.log"
 echo "PASS: detected math $mutation negative control"
done
"$iverilog_bin" -g2012 -s tb_nds_nitro_arm9_math_unit -o "$test_tmp/regression" \
 "$repo/rtl/nds_nitro_arm9_math_unit.sv" "$repo/rtl/tb_nds_nitro_arm9_math_unit.sv" 2> "$test_tmp/compile.log"
"$vvp_bin" "$test_tmp/regression"
