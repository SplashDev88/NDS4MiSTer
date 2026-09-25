#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-sdram-wide.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# Model the Cyclone V flow's zero power-up for the three request flops that
# have no explicit reset in the supplied controller. No transition, handshake,
# data-path or output expression is changed in this simulation copy.
python3 - "$repo" "$tmp" <<'PYPOWER'
from pathlib import Path
import sys
p=Path(sys.argv[1])/'third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv'
s=p.read_text(); old='reg       ch1_rq, ch2_rq, ch3_rq;'
assert s.count(old)==1
Path(sys.argv[2]+'/sdram.sv').write_text(s.replace(old,'reg ch1_rq=0, ch2_rq=0, ch3_rq=0;'))
PYPOWER
iverilog -g2012 -s tb_nds_sdram_wide -o "$tmp/test" "$tmp/sdram.sv" "$repo/rtl/tb_nds_sdram_wide.sv"
vvp "$tmp/test"
