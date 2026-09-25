#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-pu-store.XXXXXX")"
    trap 'rm -rf "$test_tmp"' EXIT
    if command -v nvc >/dev/null 2>&1; then
        cd "$test_tmp"
        bash "$repo_dir/tools/test_nds_pu_store_permissions.sh" --inside
    else
        docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
            nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_pu_store_permissions.sh --inside
    fi
    exit
fi
p="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
    "$p/nds_cpu9.vhd" "$repo_dir/rtl/tb_nds_cpu9_pu_permissions.vhd"
for delay in 1 3 11; do
    for step in 1 5; do
        for dma in false true; do
            echo "CP15 delay=$delay step=$step dma=$dma"
            nvc --std=2008 -e -gREAD_DELAY="$delay" -gSTEP_PERIOD="$step" -gDMA_OVERLAP="$dma" tb_nds_cpu9_pu_permissions
            nvc --std=2008 -r tb_nds_cpu9_pu_permissions --ieee-warnings=off --exit-severity=error
        done
    done
done
nvc --std=2008 --work=MEM -a "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$p/nds_cache9.vhd" "$repo_dir/rtl/nds_nitro_membus9.vhd" "$repo_dir/rtl/tb_nds_membus9_pu_store.vhd"
nvc --std=2008 -L . -e tb_nds_membus9_pu_store
nvc --std=2008 -L . -r tb_nds_membus9_pu_store --ieee-warnings=off --exit-severity=error
# Each negative control removes one safety gate; the test must observe it.
python3 - "$repo_dir" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);s=(r/'rtl/nds_nitro_membus9.vhd').read_text()
for name,old,new in [
 ('no-itcm-gate','itcm_sel       <= accept_now and cpu_ena and itcm_hit and not store_denied;', 'itcm_sel       <= accept_now and cpu_ena and itcm_hit;'),
 ('no-dtcm-gate','dtcm_sel       <= accept_now and cpu_ena and dtcm_hit and not itcm_hit and not store_denied;', 'dtcm_sel       <= accept_now and cpu_ena and dtcm_hit and not itcm_hit;'),
 ('no-external-gate',"if (cpu_ena = '1' and store_denied = '1') then", "if false then")]:
 assert s.count(old)==1;Path(name+'.vhd').write_text(s.replace(old,new))
s=(r/'third_party/Nitro_DarkSide/d2dabe/rtl/nds_cpu9.vhd').read_text()
a=s.index('            -- Legacy MRC c5,c0,0/1');b=s.index('         when x"6" =>',a)
s=s[:a]+'''            if (decode_cp15_op2(0) = '1') then
               cp15_rdata <= cp15_pu_iperm;
            else
               cp15_rdata <= cp15_pu_dperm;
            end if;
'''+s[b:]
Path('bad-legacy-readback.vhd').write_text(s)
PY
for fault in no-itcm-gate no-dtcm-gate no-external-gate; do
    nvc --std=2008 -L . -a "$fault.vhd" "$repo_dir/rtl/tb_nds_membus9_pu_store.vhd"
    nvc --std=2008 -L . -e tb_nds_membus9_pu_store
    if nvc --std=2008 -L . -r tb_nds_membus9_pu_store --ieee-warnings=off --exit-severity=error > "$fault.log" 2>&1; then
        cat "$fault.log"; echo "FAIL: $fault unexpectedly passed" >&2;exit 1
    fi
    grep -F 'denied store leaked' "$fault.log"
    echo "PASS negative control: $fault"
done
nvc --std=2008 -a bad-legacy-readback.vhd "$repo_dir/rtl/tb_nds_cpu9_pu_permissions.vhd"
nvc --std=2008 -e tb_nds_cpu9_pu_permissions
if nvc --std=2008 -r tb_nds_cpu9_pu_permissions --ieee-warnings=off --exit-severity=error > bad-legacy-readback.log 2>&1; then
    cat bad-legacy-readback.log;echo 'FAIL: bad legacy readback unexpectedly passed' >&2;exit 1
fi
grep -F 'CP15 readback 0 got 00003210 expected 000000E4' bad-legacy-readback.log
echo 'PASS: CPU PU permissions, dropped-store routing, and four detecting negative controls'
