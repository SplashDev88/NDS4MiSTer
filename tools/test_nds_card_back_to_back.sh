#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-card-back-to-back.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT INT TERM HUP

run_nvc() {
    local root=$1
    local out=$2
    nvc --work="$out/work" -a --relaxed --check-synthesis \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd" \
        "$root/rtl/tb_nds_card_back_to_back.vhd"
    nvc --work="$out/work" -e -O2 tb_nds_card_back_to_back
    for owner in 0 1; do
        for irq in false true; do
            for gap in 0 1 2 4 8; do
                nvc --work="$out/work" -e -O2 -gowner_cpu="$owner" \
                    -genable_irq="$irq" -gnext_gap="$gap" tb_nds_card_back_to_back
                nvc --work="$out/work" -r tb_nds_card_back_to_back \
                    --ieee-warnings=off --exit-severity=failure
            done
        done
    done
}

if command -v nvc >/dev/null 2>&1; then
    run_nvc "$repo_root" "$test_tmp"
else
    image=${NVC_IMAGE:-nds4mister-nvc-arm64:1.22.1}
    docker run --rm --network none \
        -v "$repo_root:/repo:ro" -v "$test_tmp:/out" -w /out \
        "$image" /bin/sh -lc '
            set -eu
            nvc --work=/out/work -a --relaxed --check-synthesis \
                /repo/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd \
                /repo/third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd \
                /repo/rtl/tb_nds_card_back_to_back.vhd
            nvc --work=/out/work -e -O2 tb_nds_card_back_to_back
            for owner in 0 1; do
                for irq in false true; do
                    for gap in 0 1 2 4 8; do
                        nvc --work=/out/work -e -O2 -gowner_cpu="$owner" \
                            -genable_irq="$irq" -gnext_gap="$gap" tb_nds_card_back_to_back
                        nvc --work=/out/work -r tb_nds_card_back_to_back \
                            --ieee-warnings=off --exit-severity=failure
                    done
                done
            done
        '
fi
