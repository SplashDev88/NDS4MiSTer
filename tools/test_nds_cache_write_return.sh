#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cache-write-return.XXXXXX")"
    trap 'rm -rf "$test_tmp"' EXIT
    cp "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_cache9.vhd" "$test_tmp/cache.vhd"
    if command -v nvc >/dev/null 2>&1; then
        cd "$test_tmp"
        bash "$repo_dir/tools/test_nds_cache_write_return.sh" --inside
    else
        docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
            nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_cache_write_return.sh --inside
    fi
    exit
fi
p="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl"
# Model the worst permitted mixed-port collision explicitly. A speculative
# read sampled on the store edge must not escape as a CPU response.
python3 - "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='            dataout_a <= ram(addr_a);'
assert s.count(old)==1
Path('poison-ram.vhd').write_text(s.replace(old,'''            if ce_b='1' and we_b='1' and addr_a=addr_b and be_b/="0000" then
               dataout_a <= (others=>'X');
            else
               dataout_a <= ram(addr_a);
            end if;'''))
PY
for model in old-data poison; do
    model_file="$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
    if [[ "$model" == poison ]]; then model_file=poison-ram.vhd; fi
    nvc --std=2008 --work=MEM -a "$model_file"
    nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" cache.vhd "$p/nds_mainram.vhd" \
        "$repo_dir/rtl/nds_nitro_membus9.vhd" "$repo_dir/rtl/tb_nds_cache_write_return.vhd" \
        "$repo_dir/rtl/tb_nds_cache_data_return.vhd"
    for delay in 0 31; do
        for posted in false true; do
            echo "model=$model delay=$delay posted=$posted"
            nvc --std=2008 -L . -e -gmemory_delay="$delay" -gearly="$posted" tb_nds_cache_write_return
            nvc --std=2008 -L . -r tb_nds_cache_write_return --ieee-warnings=off --exit-severity=error
        done
        nvc --std=2008 -L . -e -gmemory_delay="$delay" tb_nds_cache_data_return
        nvc --std=2008 -L . -r tb_nds_cache_data_return --ieee-warnings=off --exit-severity=error
    done
done
python3 - <<'PY'
from pathlib import Path
s=Path('cache.vhd').read_text()
old=" and dwr_committed = '0'"
assert s.count(old)==2
Path('missing-rdw-guard.vhd').write_text(s.replace(old,''))
old="""                  if w_hit_return = '0' then
                     resp_done_reg <= '1';
                  end if;"""
assert s.count(old)==1
Path('duplicate-write-return.vhd').write_text(s.replace(old,"                  resp_done_reg <= '1';"))
a=s.index("   w_hit_return <= '1'");b=s.index('   resp_done <=',a)
part=s[a:b]
assert part.count("op_ena = '0' and ")==1
Path('missing-store-maintenance-gate.vhd').write_text(s[:a]+part.replace("op_ena = '0' and ",'')+s[b:])
assert part.count("reset = '0' and ")==1
Path('missing-store-reset-gate.vhd').write_text(s[:a]+part.replace("reset = '0' and ",'')+s[b:])
PY
for fault in missing-rdw-guard duplicate-write-return missing-store-maintenance-gate missing-store-reset-gate; do
    bench=tb_nds_cache_write_return
    if [[ "$fault" == missing-rdw-guard ]]; then bench=tb_nds_cache_data_return; fi
    nvc --std=2008 -L . -a "$fault.vhd" "$repo_dir/rtl/nds_nitro_membus9.vhd" \
        "$repo_dir/rtl/tb_nds_cache_write_return.vhd" "$repo_dir/rtl/tb_nds_cache_data_return.vhd"
    nvc --std=2008 -L . -e "$bench"
    if nvc --std=2008 -L . -r "$bench" --ieee-warnings=off --exit-severity=error > "$fault.log" 2>&1; then
        cat "$fault.log"
        echo "FAIL: $fault negative control unexpectedly passed" >&2
        exit 1
    fi
    case "$fault" in
        missing-rdw-guard) grep -F 'adjacent write/read returned stale or wrong byte lanes' "$fault.log";;
        duplicate-write-return) grep -E 'read mismatch|duplicate.*response' "$fault.log";;
        missing-store-maintenance-gate) grep -F 'maintenance did not suppress early store response' "$fault.log";;
        missing-store-reset-gate) grep -F 'reset did not suppress store completion' "$fault.log";;
    esac
    echo "PASS negative control: $fault"
done
echo 'PASS: cached-store return with old/undefined RAM collision data and four detecting negative controls'
