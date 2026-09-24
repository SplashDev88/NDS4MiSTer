#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-gx-reply.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    for clock_case in 0 1 2; do
        iverilog -g2012 -Wall -s tb_nds_h3d_gx_readback_reply \
            -Ptb_nds_h3d_gx_readback_reply.CLOCK_CASE="$clock_case" \
            -o "$2/reply.vvp" \
            "$1/rtl/nds_h3d_gx_readback_reply.sv" \
            "$1/rtl/tb_nds_h3d_gx_readback_reply.sv"
        vvp "$2/reply.vvp"
    done
}
if command -v iverilog >/dev/null 2>&1; then
    run_test "$repo_dir" "$test_tmp"
else
    docker run --rm --network none \
        -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        "${IMAGE:-nds4mister-rtl-sim:24.04}" \
        bash -lc "set -e; $(declare -f run_test); run_test /workspace /test"
fi
