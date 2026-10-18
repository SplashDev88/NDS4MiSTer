#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-dma9-gx.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
cp "${NDS_DMA9_SOURCE:-$repo/third_party/Nitro_DarkSide/d2dabe/rtl/nds_dma9.vhd}" "$test_tmp/nds_dma9.vhd"
if command -v nvc >/dev/null; then
    cd "$test_tmp"
    nvc --std=2008 -a "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" nds_dma9.vhd "$repo/rtl/tb_nds_h3d_dma9_gx.vhd"
    for checkpoint in false true; do
    nvc --std=2008 -e -gCHECKPOINT="$checkpoint" tb_nds_h3d_dma9_gx
    nvc --std=2008 -r tb_nds_h3d_dma9_gx --ieee-warnings=off --exit-severity=error
    done
else
    docker run --rm --network none -v "$repo:/workspace:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -lc '
        set -eu
        nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd /test/nds_dma9.vhd /workspace/rtl/tb_nds_h3d_dma9_gx.vhd
        for checkpoint in false true; do
    nvc --std=2008 -e -gCHECKPOINT="$checkpoint" tb_nds_h3d_dma9_gx
        nvc --std=2008 -r tb_nds_h3d_dma9_gx --ieee-warnings=off --exit-severity=error
    done
    '
fi
