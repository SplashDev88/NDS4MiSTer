#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-obj-priority.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    python3 "$1/tools/gen_nds_obj_priority.py"
    nvc --std=2008 -a \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_drawer_obj.vhd" \
        "$1/rtl/tb_nds_obj_priority.vhd"
    nvc --std=2008 -e tb_nds_obj_priority
    nvc --std=2008 -r tb_nds_obj_priority --ieee-warnings=off --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
