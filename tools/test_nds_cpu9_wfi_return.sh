#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cpu9-wfi.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
cpu_rel=third_party/Nitro_DarkSide/d2dabe/rtl/nds_cpu9.vhd
# Optional baseline source for a failing-case negative control. The test and
# all other dependencies always come from the current checkout.
if [[ -n "${SOURCE_REVISION:-}" ]]; then
    git -C "$repo_dir" show "$SOURCE_REVISION:$cpu_rel" > "$test_tmp/cpu.vhd"
else
    cp "$repo_dir/$cpu_rel" "$test_tmp/cpu.vhd"
fi
run_tests() {
    local repo=$1 delay wake irq
    nvc --std=2008 -a \
        "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/export.vhd" \
        "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$repo/third_party/Nitro_DarkSide/d2dabe/rtl/reg_savestates.vhd" \
        cpu.vhd "$repo/rtl/tb_nds_cpu9_wfi_return.vhd"
    for delay in ${READ_DELAYS:-1 2 3 5 8}; do
        for wake in ${WAKE_DELAYS:-0 1 2 3 4 5 6 7 8 9 10 11 12}; do
            for irq in ${IRQ_MODES:-true false}; do
                nvc --std=2008 -e tb_nds_cpu9_wfi_return \
                    -gREAD_DELAY="$delay" -gWAKE_DELAY="$wake" -gIRQ_ENABLED="$irq"
                nvc --std=2008 -r tb_nds_cpu9_wfi_return --exit-severity=error
            done
        done
    done
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests "$repo_dir"
else
    docker run --rm --network none \
        -e READ_DELAYS -e WAKE_DELAYS -e IRQ_MODES \
        -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -euo pipefail; $(declare -f run_tests); run_tests /workspace"
fi
echo 'PASS: production ARM9 WFI caller return across memory and wake phases'
