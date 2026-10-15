#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-swap-retirement.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
iverilog -g2012 -s tb_nds_gx_swap_retirement -o "$tmp/frontend" \
    "$root/rtl/nds_gx_fifo_packet_frontend.sv" "$root/rtl/tb_nds_gx_swap_retirement.sv"
vvp "$tmp/frontend"
# Negative control: the transport-only implementation must fail the actual
# SWAP occupancy assertion, not a compile error or unrelated test failure.
iverilog -g2012 -s tb_nds_gx_swap_retirement \
    -Ptb_nds_gx_swap_retirement.ENABLE=0 -o "$tmp/negative" \
    "$root/rtl/nds_gx_fifo_packet_frontend.sv" "$root/rtl/tb_nds_gx_swap_retirement.sv"
if vvp "$tmp/negative" > "$tmp/negative.log" 2>&1; then
    echo "FAIL: transport-only negative control passed"; exit 1
fi
grep -q 'SWAP must retain 256 credits after transport drains' "$tmp/negative.log"
echo 'PASS: transport-only negative control reproduces missing SWAP credits'
iverilog -g2012 -s tb_nds_h3d_swap_retirement -o "$tmp/cdc" \
    "$root/rtl/nds_h3d_event_async_fifo.sv" \
    "$root/rtl/nds_gx_fifo_packet_frontend.sv" "$root/rtl/nds_h3d_frame_record_cdc.sv" \
    "$root/rtl/tb_nds_h3d_swap_retirement.sv"
vvp "$tmp/cdc"
# Check both preprocessed product configurations. Hardware rejected the first
# enabled candidate; normal builds must retain the transport-only behavior.
python3 - "$root" <<'PYCODE'
from pathlib import Path
import re
import subprocess
import sys
root = Path(sys.argv[1])
island = root / "rtl/nds_nitro_console_island.sv"
for enabled in (0, 1):
    command = ["iverilog", "-g2012", "-DNDS_HYBRID_3D=1", "-E", "-o", "-"]
    if enabled:
        command.append("-DNDS_GX_SWAP_RETIREMENT_EXPERIMENT=1")
    command.append(str(island))
    s = subprocess.check_output(command, text=True)
    instance = re.search(r"nds_h3d_frame_record_cdc #\((.*?)\) h3d_record_cdc", s, re.S)
    assert instance and f".SWAP_VBLANK_RETIREMENT(1'b{enabled})" in instance[1]
    assert ".lcd_vblank(h3d_lcd_vblank)" in s
    assert ".vblank_out(h3d_lcd_vblank)" in s
qsf = (root / "fpga/mister_nitro_console_island/NDS4MiSTer.qsf").read_text()
assert not re.search(r"^\s*set_global_assignment.*NDS_GX_SWAP_RETIREMENT_EXPERIMENT", qsf, re.M)
print("PASS: normal product disables the rejected SWAP candidate; explicit experiment uses native VBlank")
PYCODE
