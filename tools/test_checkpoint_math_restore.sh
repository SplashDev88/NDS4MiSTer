#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-math-restore.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
iv=${IVERILOG:-iverilog};vv=${VVP:-vvp}
git -C "$repo" show '624085aec4ef5fa166c76098e2ab2e7529dc8cf9:rtl/nds_nitro_arm9_math_unit.sv' > "$test_tmp/baseline.sv"
python3 - "$test_tmp" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1]);s=(p/'baseline.sv').read_text();(p/'reference.sv').write_text(re.sub(r'\bnds_nitro_arm9_math_unit\b','nds_nitro_arm9_math_unit_reference',s))
PY
compile() {
 "$iv" -g2012 -s tb_nds_checkpoint_math_restore -Ptb_nds_checkpoint_math_restore.PRODUCT="$2" \
  -o "$test_tmp/test" "$1" "$test_tmp/reference.sv" "$repo/rtl/tb_nds_checkpoint_math_restore.sv" 2> "$test_tmp/compile.log" || { cat "$test_tmp/compile.log";return 1; }
}
cd "$test_tmp"
for product in 0 1; do
 compile "$repo/rtl/nds_nitro_arm9_math_unit.sv" "$product"
 for scenario in {0..9};do
  "$vv" ./test +scenario="$scenario"
  cp math.state "math-$product-$scenario.state";cp math.trace "math-$product-$scenario.trace"
  for gap in 0 7;do "$vv" ./test +restore +scenario="$scenario" +gap="$gap";done
 done
done
echo 'PASS:40 fresh-process math restores with pinned-source equality, both bus modes and complete protocol coverage'
python3 - "$repo/rtl/nds_nitro_arm9_math_unit.sv" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
mutations={
 'lost-quotient':("5: div_quotient[31:0] <= checkpoint_write_data;","5: div_quotient[31:0] <= 32'd0;"),
 'lost-operand':("3: div_denominator[31:0] <= checkpoint_write_data;","3: div_denominator[31:0] <= 32'd0;"),
 'lost-sqrt':("11: sqrt_result <= checkpoint_write_data;","11: sqrt_result <= 32'd0;"),
 'lost-response':("12: registered_read_data <= checkpoint_write_data;","12: registered_read_data <= 32'd0;"),
 'partial-ready':("restore_count == 4'd13 && !checkpoint_write","restore_count > 0 && !checkpoint_write"),
 'lost-order':("checkpoint_address == restore_count &&","1'b1 &&"),
 'invalid-busy':("32'h80008000","32'h80000000"),
 'live-reset':("if (reset) begin","if (reset || checkpoint_restore) begin"),
}
for n,(a,b) in mutations.items():
 assert s.count(a)==1,(n,s.count(a));Path(n+'.sv').write_text(s.replace(a,b))
PY
for mutation in lost-quotient lost-operand lost-sqrt lost-response partial-ready lost-order invalid-busy live-reset;do
 product=1;scenario=1;args=(+no-image-check)
 case "$mutation" in
  lost-response) product=0;scenario=1;;
  partial-ready|lost-order|invalid-busy|live-reset) args=(+image-check);;
 esac
 cp "math-$product-$scenario.state" math.state;cp "math-$product-$scenario.trace" math.trace
 compile "$test_tmp/$mutation.sv" "$product"
 if "$vv" ./test +restore +scenario="$scenario" "${args[@]}" > "$mutation.log" 2>&1;then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'math continuation mismatch|math partial restore accepted|math invalid restore accepted|math restored word mismatch|math live restore accepted' "$mutation.log" || { cat "$mutation.log";exit 1; }
 echo "PASS: detected $mutation negative control"
done
