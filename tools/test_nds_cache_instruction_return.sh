#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cache-return.XXXXXX")"
    trap 'rm -rf "$test_tmp"' EXIT
    if command -v nvc >/dev/null 2>&1; then
        cd "$test_tmp"
        bash "$repo_dir/tools/test_nds_cache_instruction_return.sh" --inside
    else
        docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
            nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_cache_instruction_return.sh --inside
    fi
    exit
fi
p="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" "$p/nds_cache9.vhd" "$p/nds_mainram.vhd" \
    "$repo_dir/rtl/nds_nitro_membus9.vhd" "$repo_dir/rtl/tb_nds_cache_instruction_return.vhd"
for delay in 0 2 17 31; do
    nvc --std=2008 -L . -e -gmemory_delay="$delay" tb_nds_cache_instruction_return
    nvc --std=2008 -L . -r tb_nds_cache_instruction_return --ieee-warnings=off --exit-severity=error
done

# Fault injection verifies the data scoreboard and same-cycle invalidation
# check, rather than accepting a test that merely reaches its final message.
python3 - "$p/nds_cache9.vhd" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
old = "resp_rdata <= id_q(ihway_c) when i_hit_return = '1' else"
assert s.count(old) == 1
Path('wrong-instruction.vhd').write_text(s.replace(old,
    "resp_rdata <= (id_q(ihway_c) xor x\"00000001\") when i_hit_return = '1' else"))
old = "op_ena = '0' and op_pending = '0' and op_active = '0' and\n      req_ena = '1'"
assert s.count(old) == 2
Path('missing-invalidation-gate.vhd').write_text(s.replace(old,
    "op_pending = '0' and op_active = '0' and\n      req_ena = '1'", 1))
PY
for fault in wrong-instruction missing-invalidation-gate; do
    nvc --std=2008 -L . -a "$fault.vhd" "$repo_dir/rtl/nds_nitro_membus9.vhd" \
        "$repo_dir/rtl/tb_nds_cache_instruction_return.vhd"
    nvc --std=2008 -L . -e tb_nds_cache_instruction_return
    if nvc --std=2008 -L . -r tb_nds_cache_instruction_return --ieee-warnings=off --exit-severity=error > "$fault.log" 2>&1; then
        cat "$fault.log"
        echo "FAIL: $fault negative control unexpectedly passed" >&2
        exit 1
    fi
    if [[ "$fault" == wrong-instruction ]]; then
        grep -E 'read mismatch|instruction stream data mismatch' "$fault.log"
    else
        grep -F 'I invalidation did not suppress speculative response' "$fault.log"
    fi
done
echo "PASS: cache instruction return, streaming, ordering and both detecting negative controls"
