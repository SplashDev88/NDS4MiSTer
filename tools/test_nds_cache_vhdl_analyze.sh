#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cache-vhdl.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    nvc --std=2008 --work=MEM -a "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
    nvc --std=2008 -L . -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_cache9.vhd"
else
    docker run --rm \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
            nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_cache9.vhd
        '
fi

echo "PASS: packed ARM9 cache VHDL analyzes with the portable MEM boundary"
