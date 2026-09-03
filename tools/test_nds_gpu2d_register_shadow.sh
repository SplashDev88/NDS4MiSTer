#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-gpu2d-shadow.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

run_test() {
    nvc --std=2008 -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/nds_gpu2d_register_shadow.vhd"
    nvc --std=2008 -a "$repo_dir/rtl/tb_nds_gpu2d_register_shadow.vhd"
    nvc --std=2008 -e tb_nds_gpu2d_register_shadow
    nvc --std=2008 -r tb_nds_gpu2d_register_shadow
}

if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test
else
    docker run --rm \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd
            nvc --std=2008 -a /workspace/rtl/nds_gpu2d_register_shadow.vhd
            nvc --std=2008 -a /workspace/rtl/tb_nds_gpu2d_register_shadow.vhd
            nvc --std=2008 -e tb_nds_gpu2d_register_shadow
            nvc --std=2008 -r tb_nds_gpu2d_register_shadow
        '
fi

echo "PASS: Engine B register shadow matches disabled-renderer readback contract"
