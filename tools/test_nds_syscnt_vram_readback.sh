#!/usr/bin/env bash
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-syscnt-readback.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
run_test() {
    nvc --std=2008 -a "$1/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_syscnt.vhd" \
        "$1/rtl/tb_nds_syscnt_vram_readback.vhd"
    nvc --std=2008 -e tb_nds_syscnt_vram_readback
    nvc --std=2008 -r tb_nds_syscnt_vram_readback --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$tmp"; run_test "$repo"
else
    docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -c "set -e; $(declare -f run_test); run_test /workspace"
fi
