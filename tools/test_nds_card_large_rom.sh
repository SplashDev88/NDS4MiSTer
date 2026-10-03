#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-card-large-rom.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT INT TERM HUP

run_nvc() {
    local root=$1
    local out=$2
    nvc --work="$out/work" -a --relaxed --check-synthesis \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd" \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd" \
        "$root/rtl/tb_nds_card_large_rom.vhd" \
        "$root/rtl/tb_nds_loader_large_rom.vhd"
    for owner in 0 1; do
        for depth in 1 4 7; do
            for delay in 0 3 11; do
                nvc --work="$out/work" -e -O2 -gowner_cpu="$owner" \
                    -gprefetch_depth="$depth" -gmemory_delay="$delay" tb_nds_card_large_rom
                nvc --work="$out/work" -r tb_nds_card_large_rom \
                    --ieee-warnings=off --exit-severity=failure
            done
        done
    done
    for mode in 0 1 2; do
        for scenario in 0 1 2 3 4 5 6 7; do
            nvc --work="$out/work" -e -O2 -gscenario="$scenario" \
                -gboot_mode="$mode" tb_nds_loader_large_rom
            nvc --work="$out/work" -r tb_nds_loader_large_rom \
                --ieee-warnings=off --exit-severity=failure
        done
    done
}

if command -v nvc >/dev/null 2>&1; then
    run_nvc "$repo_root" "$test_tmp"
else
    image=${NVC_IMAGE:-nds4mister-nvc-arm64:1.22.1}
    docker run --rm --network none \
        -v "$repo_root:/repo:ro" -v "$test_tmp:/out" -w /out \
        "$image" /bin/bash -euo pipefail -c "$(declare -f run_nvc); run_nvc /repo /out"
fi
