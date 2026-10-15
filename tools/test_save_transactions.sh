#!/usr/bin/env bash
set -euo pipefail
case "${1:-0}" in 0|1|2) ;; *) echo 'usage: test_save_transactions.sh [0|1|2]' >&2; exit 2 ;; esac
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/nds-save-transactions.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
run_test() {
    nvc --std=2008 -a "$1/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd"
    nvc --std=2008 -a "$1/rtl/tb_nds_card_save_transactions.vhd"
    nvc --std=2008 -e tb_nds_card_save_transactions -gTEST_CASE="$2"
    nvc --std=2008 -r tb_nds_card_save_transactions --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_dir"
    run_test "$repo_dir" "${1:-0}"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_dir:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc \
        "set -e; $(declare -f run_test); run_test /workspace ${1:-0}"
fi
