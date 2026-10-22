#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-rom-464.XXXXXX")
trap 'rm -rf "$out"' EXIT
python3 "$root/tools/test_nds_cart_large_rom.py"
python3 "$root/tools/test_nds_cart_session_reset.py"
for wide in 0 1; do
  iverilog -g2012 -s tb_nds_ddram_cart_bank -Ptb_nds_ddram_cart_bank.WIDE="$wide" -o "$out/bank.vvp" \
    "$root/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" "$root/rtl/tb_nds_ddram_cart_bank.sv"
  vvp "$out/bank.vvp"
  iverilog -g2012 -s tb_nds_host_save_control -Ptb_nds_host_save_control.CART_464="$wide" \
    -Ptb_nds_host_save_control.NAND_SAVES=1 -o "$out/control.vvp" \
    "$root/rtl/nds_firmware_control.sv" "$root/rtl/tb_nds_host_save_control.sv"
  vvp "$out/control.vvp"
done
