#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cpu9-load.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
cpu_rel=third_party/Nitro_DarkSide/d2dabe/rtl/nds_cpu9.vhd
if [[ -n "${SOURCE_REVISION:-}" ]]; then
    git -C "$repo_dir" show "$SOURCE_REVISION:$cpu_rel" > "$test_tmp/cpu.vhd"
else
    cp "$repo_dir/$cpu_rel" "$test_tmp/cpu.vhd"
fi
run_tests() {
    local repo=$1 delay step dma irq
    local p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
    nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
        "$p/reg_savestates.vhd" cpu.vhd "$repo/rtl/tb_nds_cpu9_load_retire.vhd"
    for delay in 1 3 11; do
        for step in 1 2 5; do
            for dma in false true; do
                for irq in false true; do
                    echo "delay=$delay step=$step dma=$dma irq=$irq"
                    nvc --std=2008 -e -gREAD_DELAY="$delay" -gSTEP_PERIOD="$step" \
                        -gDMA_OVERLAP="$dma" -gIRQ_OVERLAP="$irq" tb_nds_cpu9_load_retire
                    nvc --std=2008 -r tb_nds_cpu9_load_retire \
                        --ieee-warnings=off --exit-severity=error
                done
            done
        done
    done
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -euo pipefail; $(declare -f run_tests); run_tests /workspace"
fi
echo 'PASS: ARM9 scalar-load values, dependencies, fallbacks, DMA, CE and IRQ'
