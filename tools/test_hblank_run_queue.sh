#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-hblank-run.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    nvc --std=2008 -a "$1/rtl/nds_hblank_run_queue.vhd" \
        "$1/rtl/tb_nds_hblank_run_queue.vhd" \
        "$1/rtl/nds_h3d_console_event_gate.vhd" \
        "$1/rtl/tb_nds_h3d_hblank_run_gate.vhd"
    nvc --std=2008 -e -gBOUNDARY_BITS=3 -gINDEX_BITS=6 -O2 tb_nds_hblank_run_queue
    nvc --std=2008 -r tb_nds_hblank_run_queue --exit-severity=error
    nvc --std=2008 -e -gBOUNDARY_BITS=9 -gINDEX_BITS=17 -O2 tb_nds_hblank_run_queue
    nvc --std=2008 -r tb_nds_hblank_run_queue --exit-severity=error
    nvc --std=2008 -e -O2 tb_nds_h3d_hblank_run_gate
    nvc --std=2008 -r tb_nds_h3d_hblank_run_gate --exit-severity=error
    nvc --std=2008 -e -gCOMPRESS_TEST=false -O2 tb_nds_h3d_hblank_run_gate
    if nvc --std=2008 -r tb_nds_h3d_hblank_run_gate --exit-severity=error > negative.log 2>&1; then
        echo "FAIL: legacy 512-line queue unexpectedly retained the backlog"
        exit 1
    fi
    if [[ "$(cat negative.log)" != *"REGULAR_HBLANK_BACKLOG_OVERFLOW index=512"* ]]; then
        cat negative.log
        exit 1
    fi
    echo "PASS: legacy negative control fails on the 513th retained scanline"
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
