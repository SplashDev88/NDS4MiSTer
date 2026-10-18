#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 components="${ALTERA_MF_COMPONENTS:-$repo/.tooling/quartus-17.0.2/quartus/eda/sim_lib/altera_mf_components.vhd}"
 [[ -f $components ]] || { echo 'Set ALTERA_MF_COMPONENTS to Quartus altera_mf_components.vhd' >&2; exit 2; }
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-console.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  -v "$components:/altera_mf_components.vhd:ro" nds4mister-nvc-arm64:1.22.1 \
  bash /repo/tools/test_checkpoint_console.sh --inside
 exit
fi
nvc --std=2008 -L /test --work=altera_mf -a /altera_mf_components.vhd
while read -r file library; do
 file="${file/\$nitro_rtl/$repo/third_party/Nitro_DarkSide/d2dabe/rtl}"
 file="${file/..\/../$repo}"
 if [[ $file == */nds_nitro_console_top.vhd ]]; then
  nvc --std=2008 -L /test -a "$repo/rtl/nds_palette_readback.vhd" "$repo/rtl/nds_gpu2d_register_shadow.vhd" "$repo/rtl/nds_h3d_query_watch.vhd"
 fi
 nvc --std=2008 -L /test --work="${library:-work}" -a "$file"
done < <(awk '$3 == "VHDL_FILE" {print $4, ($5 == "-library" ? $6 : "work")}' "$repo/fpga/mister_nitro_console_island/files.qip")
python3 "$repo/tools/suspend_resume/console_fixture.py" fixture_rom.vhd
nvc --std=2008 -L /test -a fixture_rom.vhd "$repo/rtl/tb_nds_checkpoint_console.vhd"
# 20 ns is the current 1.5x ARM9 clock; 15 ns covers the older 2x ratio.
# Vary actual accepted-request latency without forcing any internal status.
for latency in 2 7; do
 for arm9_half in 20 15; do
  nvc --std=2008 -L /test -e -O2 -gLATENCY="$latency" -gARM9_HALF_NS="$arm9_half" tb_nds_checkpoint_console
  nvc --std=2008 -L /test -H 128m -r tb_nds_checkpoint_console --ieee-warnings=off --exit-severity=error
 done
done
echo 'PASS: 4 enabled-console cases; 16 double-read CPU images, 8 acquisition timeouts and 4 lease expiries'
