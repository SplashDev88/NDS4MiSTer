#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-h3d-event-gate.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    nvc --std=2008 -a "$1/rtl/nds_hblank_run_queue.vhd" "$1/rtl/nds_h3d_console_event_gate.vhd"
    nvc --std=2008 -a "$1/rtl/tb_nds_h3d_console_event_gate.vhd"
    for local_credit in false true; do
        nvc --std=2008 -e -O2 -gLOCAL_GPU_CREDIT="$local_credit" tb_nds_h3d_console_event_gate
        nvc --std=2008 -r tb_nds_h3d_console_event_gate --exit-severity=error
    done
    # The local-credit test must detect reinstating the downstream-ready cone.
    python3 - "$1/rtl/nds_h3d_console_event_gate.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old="(not GPU_LOCAL_CREDIT and gpu_queue_pop = '1')"
assert s.count(old)==1
Path('borrowed-credit.vhd').write_text(s.replace(old,"gpu_queue_pop = '1'"))
PY
    nvc --std=2008 -a borrowed-credit.vhd "$1/rtl/tb_nds_h3d_console_event_gate.vhd"
    nvc --std=2008 -e -O2 -gLOCAL_GPU_CREDIT=true tb_nds_h3d_console_event_gate
    if nvc --std=2008 -r tb_nds_h3d_console_event_gate --exit-severity=error > negative.log 2>&1; then
        echo "FAIL: downstream pop-credit negative control unexpectedly passed" >&2
        return 1
    fi
    grep -F 'local GPU credit borrowed a combinational full-queue pop' negative.log
    echo "PASS: both GPU credit modes retain CPU and held DMA writes; pop-credit negative control detected"
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
