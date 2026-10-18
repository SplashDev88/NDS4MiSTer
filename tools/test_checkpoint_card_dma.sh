#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-card-dma.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_card_dma.sh --inside
 exit
fi
rtl="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$rtl/proc_bus_gba.vhd" "$rtl/nds_card.vhd" "$rtl/nds_dma7.vhd" "$rtl/nds_dma9.vhd" "$repo/rtl/tb_nds_checkpoint_card_dma.vhd"
for arm9 in true false; do
 for latency in 1 17 97; do
  nvc --std=2008 -e -gARM9=$arm9 -gLATENCY=$latency tb_nds_checkpoint_card_dma
  nvc --std=2008 -r tb_nds_checkpoint_card_dma --ieee-warnings=off --exit-severity=error
 done
done
# Deliberately bypass the ordering used by the actual console and verify the
# held DMA response scenario rejects the premature cartridge acknowledgement.
sed 's/card_hold<=hold and dma_held;/card_hold<=hold;/' "$repo/rtl/tb_nds_checkpoint_card_dma.vhd" > wrong-order.vhd
nvc --std=2008 -a wrong-order.vhd
nvc --std=2008 -e tb_nds_checkpoint_card_dma
if nvc --std=2008 -r tb_nds_checkpoint_card_dma --ieee-warnings=off --exit-severity=error > wrong-order.log 2>&1; then
 echo 'FAIL: premature card stop negative control passed' >&2;exit 1
fi
grep 'card stopped before active DMA drained' wrong-order.log
echo 'PASS: detected premature card stop negative control'
