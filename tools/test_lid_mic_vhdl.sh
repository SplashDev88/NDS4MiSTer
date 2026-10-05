#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-lid-mic.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
if ! command -v nvc >/dev/null 2>&1; then
  docker run --rm --network none -v "$root:/workspace:ro" -v "$tmp:/test" -e TMPDIR=/test \
    nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_lid_mic_vhdl.sh
  exit
fi
cd "$tmp"
nvc --std=2008 -a "$root/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
  "$root/third_party/Nitro_DarkSide/d2dabe/rtl/nds_irq.vhd" \
  "$root/rtl/nds_nitro_spi.vhd" "$root/rtl/tb_nds_lid_mic.vhd"
nvc --std=2008 -e tb_nds_lid_mic
nvc --std=2008 -r tb_nds_lid_mic --exit-severity=error
