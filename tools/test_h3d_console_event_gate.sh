#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-h3d-event-gate.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    nvc --std=2008 -a "$1/rtl/nds_h3d_console_event_gate.vhd"
    nvc --std=2008 -a "$1/rtl/tb_nds_h3d_console_event_gate.vhd"
    nvc --std=2008 -e -O2 tb_nds_h3d_console_event_gate
    nvc --std=2008 -r tb_nds_h3d_console_event_gate --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
