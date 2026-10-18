#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 mode=${1:-all}
 case $mode in all|baseline|devices) ;; *) echo 'Usage: test_checkpoint_console.sh [all|baseline|devices]' >&2; exit 2;; esac
 components="${ALTERA_MF_COMPONENTS:-$repo/.tooling/quartus-17.0.2/quartus/eda/sim_lib/altera_mf_components.vhd}"
 [[ -f $components ]] || { echo 'Set ALTERA_MF_COMPONENTS to Quartus altera_mf_components.vhd' >&2; exit 2; }
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-console.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 # Freeze the exact dependency closure, runner and authored ROM generator.
 # A later source edit cannot change a running matrix or its input identity.
 python3 - "$repo" "$test_tmp/source" "$components" <<'PY'
from pathlib import Path
import hashlib, json, shutil, sys
r,o,c=map(Path,sys.argv[1:]);files={Path('fpga/mister_nitro_console_island/files.qip')}
for line in (r/'fpga/mister_nitro_console_island/files.qip').read_text().splitlines():
 parts=line.split()
 if len(parts)>3 and parts[2]=='VHDL_FILE':
  name=parts[3].replace('$nitro_rtl','third_party/Nitro_DarkSide/d2dabe/rtl')
  if name.startswith('../../'): name=name[6:]
  files.add(Path(name))
files.update(Path(p) for p in ('rtl/nds_palette_readback.vhd','rtl/nds_gpu2d_register_shadow.vhd',
 'rtl/nds_h3d_query_watch.vhd','rtl/tb_nds_checkpoint_console.vhd',
 'tools/test_checkpoint_console.sh','tools/suspend_resume/console_fixture.py'))
hashes={}
for p in sorted(files):
 (o/p).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/p,o/p)
 hashes[str(p)]=hashlib.sha256((o/p).read_bytes()).hexdigest()
hashes['altera_mf_components.vhd']=hashlib.sha256(c.read_bytes()).hexdigest()
manifest=json.dumps(hashes,sort_keys=True).encode()
(o/'INPUTS.json').write_bytes(manifest)
print('CHECKPOINT_CONSOLE_INPUT_SHA256',hashlib.sha256(manifest).hexdigest())
PY
 docker run --rm --network none -v "$test_tmp:/test" -w /test \
  -e CONSOLE_TEST_LATENCIES="${CONSOLE_TEST_LATENCIES:-2 7}" \
  -e CONSOLE_TEST_HALVES="${CONSOLE_TEST_HALVES:-20 15}" \
  -v "$components:/altera_mf_components.vhd:ro" nds4mister-nvc-arm64:1.22.1 \
  bash /test/source/tools/test_checkpoint_console.sh --inside "$mode"
 exit
fi
mode=${2:-all}
nvc --std=2008 -L /test --work=altera_mf -a /altera_mf_components.vhd
while read -r file library; do
 file="${file/\$nitro_rtl/$repo/third_party/Nitro_DarkSide/d2dabe/rtl}"
 file="${file/..\/../$repo}"
 if [[ $file == */nds_nitro_console_top.vhd ]]; then
  nvc --std=2008 -L /test -a "$repo/rtl/nds_palette_readback.vhd" "$repo/rtl/nds_gpu2d_register_shadow.vhd" "$repo/rtl/nds_h3d_query_watch.vhd"
 fi
 nvc --std=2008 -L /test --work="${library:-work}" -a "$file"
done < <(awk '$3 == "VHDL_FILE" {print $4, ($5 == "-library" ? $6 : "work")}' "$repo/fpga/mister_nitro_console_island/files.qip")
variants="$mode"
if [[ $mode == all ]]; then variants='baseline devices'; fi
cases=0
for variant in $variants; do
 args=()
 if [[ $variant == devices ]]; then args=(--active-devices); fi
 python3 "$repo/tools/suspend_resume/console_fixture.py" fixture_rom.vhd "${args[@]}"
 nvc --std=2008 -L /test -a fixture_rom.vhd "$repo/rtl/tb_nds_checkpoint_console.vhd"
 latencies=${CONSOLE_TEST_LATENCIES:-2 7};halves=${CONSOLE_TEST_HALVES:-20 15}
 # The all-mode baseline smoke uses one previously qualified clock/latency;
 # the new active-device variant exercises the entire requested matrix.
 if [[ $mode == all && $variant == baseline ]]; then latencies=2;halves=20;fi
 for latency in $latencies; do
  for arm9_half in $halves; do
   echo "CONSOLE_CASE variant=$variant latency=$latency ARM9_half_ns=$arm9_half"
   nvc --std=2008 -L /test -e -O2 -gLATENCY="$latency" -gARM9_HALF_NS="$arm9_half" tb_nds_checkpoint_console
   nvc --std=2008 -L /test -H 128m -r tb_nds_checkpoint_console --ieee-warnings=off --exit-severity=error
   cases=$((cases+1))
  done
 done
done
echo "PASS: $cases enabled-console cases mode=$mode"
