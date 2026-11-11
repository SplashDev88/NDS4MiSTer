#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --inside ]]; then
    test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-cache-line.XXXXXX")"
    trap 'rm -rf "$test_tmp"' EXIT
    if command -v nvc >/dev/null 2>&1; then
        cd "$test_tmp"
        bash "$repo_dir/tools/test_nds_cache_line_stream.sh" --inside
    else
        docker run --rm --network none -v "$repo_dir:/workspace:ro" -v "$test_tmp:/test" -w /test \
            nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_nds_cache_line_stream.sh --inside
    fi
    exit
fi
p="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 --work=MEM -a "$repo_dir/rtl/tb_mem_sync_ram_dual_byte_enable.vhd"
nvc --std=2008 -L . -a "$repo_dir/rtl/tb_lcell.vhd" "$p/nds_cache9.vhd" "$p/nds_mainram.vhd" "$repo_dir/rtl/tb_nds_cache_line_stream.vhd"
: > metrics.log
for ratio in 3 4; do
  for delay in 0 2 17 31; do
    for stream in false true; do
      nvc --std=2008 -L . -e -gline_stream="$stream" -gmem_ratio="$ratio" \
          -gmemory_delay="$delay" tb_nds_cache_line_stream
      nvc --std=2008 -L . -r tb_nds_cache_line_stream --ieee-warnings=off --exit-severity=error 2>&1 | tee -a metrics.log
    done
  done
done
python3 - <<'PY'
from pathlib import Path
import re
rows={}
for m in re.finditer(r'METRIC stream=(\w+) ratio=(\d+) delay=(\d+) code=(\d+) offset=(\d+) critical=(\d+) complete=(\d+)',Path('metrics.log').read_text()):
    stream,*v=m.groups()
    key=tuple(map(int,v[:4]))
    assert stream not in rows.setdefault(key,{}), 'duplicate measurement'
    rows[key][stream]=tuple(map(int,v[4:]))
assert len(rows)==128, f'incomplete matched measurements: {len(rows)}'
for key,v in rows.items():
    assert set(v)=={'false','true'}, f'unpaired measurement: {key}'
    assert v['true'][0]==v['false'][0], f'critical response latency changed: {key}'
    assert v['true'][1]<v['false'][1], f'full-line latency did not improve: {key}'
print('PASS: 128 matched misses preserve critical latency and reduce full-line cycles')
PY
nvc --std=2008 -L . -e -gpriority7="'0'" tb_nds_cache_line_stream
nvc --std=2008 -L . -r tb_nds_cache_line_stream --ieee-warnings=off --exit-severity=error

# Deliberate faults must be caught by the wrap and missing-beat scoreboards.
python3 - "$p/nds_mainram.vhd" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='unsigned(req9_addr(4 downto 3)) + 1'
assert s.count(old)==1
Path('wrong-wrap.vhd').write_text(s.replace(old,'unsigned(req9_addr(4 downto 3)) + 2'))
old="req9_line_next <= '1';"
assert s.count(old)==1
Path('short-line.vhd').write_text(s.replace(old,"req9_line_next <= '0';"))
PY
for fault in wrong-wrap short-line; do
    nvc --std=2008 -L . -a "$fault.vhd" "$repo_dir/rtl/tb_nds_cache_line_stream.vhd"
    nvc --std=2008 -L . -e tb_nds_cache_line_stream
    if nvc --std=2008 -L . -r tb_nds_cache_line_stream --ieee-warnings=off --exit-severity=error > "$fault.log" 2>&1; then
        cat "$fault.log"
        echo "FAIL: $fault negative control unexpectedly passed" >&2
        exit 1
    fi
    if [[ "$fault" == wrong-wrap ]]; then
        grep -E 'wrap/address order mismatch|cache stream data mismatch' "$fault.log"
    else
        grep -F 'fill never completed' "$fault.log"
    fi
done
echo "PASS: line-stream related-clock regression and detecting negative controls"
