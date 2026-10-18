#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-nand-card.XXXXXX")
trap 'rm -rf "$out"' EXIT
docker run --rm --network none -v "$repo:/workspace:ro" -v "$out:/test" -w /test nds4mister-nvc-arm64:1.22.1 sh -c '
set -e
nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd /workspace/rtl/tb_nds_card_nand.vhd
for kind in 8 9; do
for period in 1 5; do
 nvc --std=2008 -e tb_nds_card_nand -gCE_PERIOD=$period -gSAVE_TYPE=$kind
 nvc -H 256m --std=2008 -r tb_nds_card_nand --exit-severity=error
done
done'
