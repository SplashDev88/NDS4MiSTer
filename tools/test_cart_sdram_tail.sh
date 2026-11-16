#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iverilog -g2012 -s tb_nds_cart_sdram_tail -o "$tmp/tail" "$repo/rtl/nds_cart_sdram_tail.sv" "$repo/rtl/tb_nds_cart_sdram_tail.sv"
vvp "$tmp/tail"
python3 - "$repo" "$tmp" <<'PY'
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv').read_text()
s=s.replace('reg       ch1_rq, ch2_rq, ch3_rq;', 'reg ch1_rq=0, ch2_rq=0, ch3_rq=0;')
Path(sys.argv[2]+'/sdram.sv').write_text(s)
PY
for pipe in 0 1; do
  iverilog -g2012 -s tb_nds_sdram_linear -Ptb_nds_sdram_linear.PIPE="$pipe" -o "$tmp/linear" "$tmp/sdram.sv" "$repo/rtl/tb_nds_sdram_linear.sv" "$repo/rtl/tb_nds_sdram_wide.sv"
  vvp "$tmp/linear"
done
