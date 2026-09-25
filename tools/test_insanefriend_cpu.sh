#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-if-cpu.XXXXXX")
 trap 'rm -rf "$tmp"' EXIT
 python3 "$repo/tools/test_insanefriend_cpu.py" "$tmp"
 docker run --rm --network none -v "$repo:/workspace:ro" -v "$tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash /workspace/tools/test_insanefriend_cpu.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" tb_if_cpu.vhd
for cpu in true false; do
 for delay in 1 3 11; do
  for step in 1 3 5; do
   echo "CPU9=$cpu delay=$delay step=$step"
   nvc --std=2008 -e -gCPU9="$cpu" -gREAD_DELAY="$delay" -gSTEP_PERIOD="$step" tb_if_cpu
   nvc --std=2008 -r tb_if_cpu --ieee-warnings=off --exit-severity=error
  done
 done
done
# Undo each fix independently: a passing negative control would invalidate coverage.
python3 - "$p" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
for cpu in ('nds_cpu9','gba_cpu'):
 s=(p/(cpu+'.vhd')).read_text()
 for fix in ('thumb','stm'):
  bad=s
  if fix=='thumb':
   a=bad.index('case (decode_data(9 downto 6)) is')
   b=bad.index('when x"1"',a)
   bad=bad[:a]+re.sub(r'^\s*when x"[04]"[^\n]*\n','',bad[a:b],flags=re.M)+bad[b:]
  elif cpu=='nds_cpu9':
   a=bad.index('         -- STM with the base register in the list:');b=bad.index("         if (execute_stall = '0') then",a)
   bad=bad[:a]+"         if (execute_stall = '1' and decode_RM_op2 = decode_Rn_op1) then\n            execute_RW_data <= std_logic_vector(execute_blockRW_endaddr);\n         end if;\n"+bad[b:]
  else:
   bad=bad.replace("decode_RM_op2 = decode_Rn_op1 and\n             decode_datatransfer_writeback = '1'",'decode_RM_op2 = decode_Rn_op1')
  assert bad!=s
  Path(cpu+'-'+fix+'.vhd').write_text(bad)
PY
for cpu in nds_cpu9 gba_cpu; do
 for fix in thumb stm; do
  nvc --std=2008 -a "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" "$cpu-$fix.vhd" tb_if_cpu.vhd
  is9=false; [[ $cpu != nds_cpu9 ]] || is9=true
  nvc --std=2008 -e -gCPU9="$is9" tb_if_cpu
  if nvc --std=2008 -r tb_if_cpu --ieee-warnings=off --exit-severity=error > "$cpu-$fix.log" 2>&1; then
   echo "FAIL: $cpu $fix negative control passed";exit 1
  fi
  cat "$cpu-$fix.log"
  grep -E 'Failure:.*(store|should never happen|decode: unhandled opcode)' "$cpu-$fix.log"
  echo "PASS negative control: $cpu $fix"
 done
done
echo 'PASS: both CPU instruction fixes at nine bus timings, four negative controls'
