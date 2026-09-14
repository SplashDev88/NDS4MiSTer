#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-sound-dma-yield.XXXXXX")
trap 'rm -rf "$out"' EXIT
docker run --rm --network none -v "$repo:/workspace:ro" -v "$out:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -lc '
set -euo pipefail
nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd /workspace/rtl/tb_nds_sound_fetch_state_ram.vhd /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_dma7.vhd /workspace/rtl/tb_nds_sound_dma_yield.vhd
for config in "false 1 false false" "true 1 false false" "true 1 true false" "true 16 true false" "true 1 false true" "true 16 true true"; do
 read -r enabled channels pcm16 repeated <<< "$config"
 nvc --std=2008 -L . -e -gENABLE_YIELD=$enabled -gCHANNELS=$channels -gPCM16=$pcm16 -gREPEAT_TRIGGER=$repeated tb_nds_sound_dma_yield
 nvc --std=2008 -L . -r tb_nds_sound_dma_yield --ieee-warnings=off --exit-severity=error
done
'
