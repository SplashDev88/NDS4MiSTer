#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iverilog -g2012 -s tb_nds_rtc_host_bridge -o "$tmp/test" \
    "$root/rtl/nds_rtc_host_bridge.sv" "$root/rtl/tb_nds_rtc_host_bridge.sv"
vvp "$tmp/test"
