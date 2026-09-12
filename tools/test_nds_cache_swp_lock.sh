#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cache-swp-lock.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
run_test() {
    nvc --std=2008 --work=mem -a "$1/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
    nvc --std=2008 -L . -a \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd" \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_cache9.vhd" \
        "$1/third_party/Nitro_DarkSide/d2dabe/rtl/nds_mainram.vhd" \
        "$1/rtl/nds_nitro_membus9.vhd" \
        "$1/rtl/tb_nds_cache_swp_lock.vhd"
    for delay in 0 1 2 7 31; do
        nvc --std=2008 -L . -e -gmemory_delay="$delay" tb_nds_cache_swp_lock
        nvc --std=2008 -L . -r tb_nds_cache_swp_lock --ieee-warnings=off --exit-severity=error
    done
    nvc --std=2008 -L . -e -glegacy_live_lock=true tb_nds_cache_swp_lock
    if nvc --std=2008 -L . -r tb_nds_cache_swp_lock --ieee-warnings=off --exit-severity=error > legacy.log 2>&1; then
        cat legacy.log
        echo "FAIL: legacy lock wiring unexpectedly passed" >&2
        return 1
    fi
    cat legacy.log
    case "$(cat legacy.log)" in *'read mismatch address=0200000C'*) ;; *) return 1;; esac
    echo "PASS: legacy negative control reproduces corrupted background fill"
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_test "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
        nds4mister-nvc-arm64:1.22.1 bash -lc "set -e; $(declare -f run_test); run_test /workspace"
fi
