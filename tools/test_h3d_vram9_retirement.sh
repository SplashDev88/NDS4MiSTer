#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-vram9-retirement.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
generator_args=("$test_tmp/test.vhd")
if [[ -n "${SOURCE_REVISION:-}" ]]; then generator_args+=(--revision "$SOURCE_REVISION"); fi
python3 "$repo_dir/tools/generate_h3d_vram9_retirement_test.py" "${generator_args[@]}"
run_tests() {
    nvc --std=2008 -a \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_dma9.vhd" \
        "$1/rtl/nds_h3d_console_event_gate.vhd" test.vhd
    for engine_b in false true; do
    for local_only in false true; do
      for id in 0 1 2 3 4; do
        for stall in false true; do
            nvc --std=2008 -e -g CASE_ID="$id" -g STALL_SINK="$stall" -g LOCAL_ONLY="$local_only" -g ENGINE_B="$engine_b" tb_nds_h3d_vram9_retirement
            nvc --std=2008 -r tb_nds_h3d_vram9_retirement --exit-severity=error
        done
      done
    done
    done
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests "$repo_dir"
else
    export -f run_tests
    docker run --rm -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_tests); run_tests /workspace"
fi
echo "PASS: VRAM9 LCDC local/event acceptance, Off local-only BG / On mirrored BG, DMA reads, unposted pulses, backpressure and service-off"
