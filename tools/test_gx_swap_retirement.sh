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
# Guard the native-clock connection and product opt-in; a passing standalone
# frontend fixture alone does not establish that the core enables the barrier.
python3 - "$root" <<'PYCODE'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = (root / "rtl/nds_nitro_console_island.sv").read_text()
assert ".SWAP_VBLANK_RETIREMENT(1'b1)" in s
assert ".lcd_vblank(h3d_lcd_vblank)" in s
assert ".vblank_out(h3d_lcd_vblank)" in s
print("PASS: product uses the native console VBlank for SWAP retirement")
PYCODE
