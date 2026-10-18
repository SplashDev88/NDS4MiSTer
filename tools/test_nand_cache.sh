#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-nand-cache.XXXXXX")
trap 'rm -rf "$out"' EXIT
iverilog -g2012 -s tb_nds_nitro_save_bridge -Ptb_nds_nitro_save_bridge.SAVE_ADDR_BITS=24 \
 -o "$out/bridge" "$repo/rtl/nds_nitro_save_bridge.sv" "$repo/rtl/tb_nds_nitro_save_bridge.sv"
vvp "$out/bridge"
