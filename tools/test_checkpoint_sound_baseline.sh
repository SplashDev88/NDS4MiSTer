#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-sound-baseline.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
python3 - "$repo" "$test_tmp" <<'PY'
from pathlib import Path
import sys,subprocess,hashlib
r,o=map(Path,sys.argv[1:]);file='third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd'
base=subprocess.check_output(['git','show','41d4351bd20e0d5ad97296e355cf5edd4d2b6318:'+file],cwd=r,text=True)
s=(r/file).read_text()
def once(s,a,b):
 assert s.count(a)==1,(a[:60],s.count(a));return s.replace(a,b)
def instrument(s,name):
 s=once(s,'entity nds_sound is',f'entity {name} is');s=once(s,'architecture arch of nds_sound is',f'architecture arch of {name} is')
 s=once(s,'snd_active  : out std_logic_vector(15 downto 0)','snd_active  : out std_logic_vector(15 downto 0);\n      audit : out std_logic_vector(639 downto 0)')
 probes=[]
 for i in range(16):
  c=f'chan({i})';v=f"{c}.busy & {c}.format & {c}.repeatm & {c}.duty & '0' & {c}.pan & '0' & {c}.hold & \"0000\" & {c}.voldiv & '0' & {c}.volmul"
  probes.append(f'   audit({i*32+31} downto {i*32}) <= {v};')
 probes.append('   audit(639 downto 512) <= cap(1).len & cap(0).len & cap(1).dad & cap(0).dad & cap(1).cnt & cap(0).cnt & soundbias & soundcnt;')
 return once(s,'\nbegin\n','\nbegin\n'+'\n'.join(probes)+'\n')
(o/'reference.vhd').write_text(instrument(base,'sound_unit_reference'))
for enabled in (False,True):
 candidate=s
 if enabled:candidate=once(candidate,'EXPERIMENTAL_CHECKPOINT : boolean := false','EXPERIMENTAL_CHECKPOINT : boolean := true')
 (o/f'candidate-{int(enabled)}.vhd').write_text(instrument(candidate,'sound_unit_candidate'))
for name,old,new in [('lost-output', 'sample_r <= std_logic_vector(to_signed(v_o, 16));',"sample_r <= (others => '0');"),
 ('lost-request', "snd_bus_req <= '1';", "snd_bus_req <= '0';")]:
 (o/f'{name}.vhd').write_text(instrument(once(s,old,new),'sound_unit_candidate'))
print('SOUND_BASELINE_SHA256',hashlib.sha256(base.encode()).hexdigest())
print('SOUND_CANDIDATE_SHA256',hashlib.sha256(s.encode()).hexdigest())
PY
docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 bash -c '
set -euo pipefail
p=/repo/third_party/Nitro_DarkSide/d2dabe/rtl
nvc --std=2008 --work=MEM -a /repo/rtl/tb_mem_sync_ram_dual_byte_enable.vhd
nvc --std=2008 -L . -a "$p/proc_bus_gba.vhd" /repo/rtl/tb_nds_sound_fetch_state_ram.vhd reference.vhd
for enabled in 0 1;do
 nvc --std=2008 -L . -a candidate-$enabled.vhd /repo/rtl/tb_nds_sound_unit_equivalence.vhd
 for table in 0 1;do
  nvc --std=2008 -L . -e -gTABLE_MODE=$table tb_nds_sound_unit_equivalence
  nvc --std=2008 -L . -r tb_nds_sound_unit_equivalence --ieee-warnings=off --exit-severity=error
 done
done
for mutation in lost-output lost-request;do
 nvc --std=2008 -L . -a $mutation.vhd /repo/rtl/tb_nds_sound_unit_equivalence.vhd
 nvc --std=2008 -L . -e tb_nds_sound_unit_equivalence
 if nvc --std=2008 -L . -r tb_nds_sound_unit_equivalence --ieee-warnings=off --exit-severity=error > $mutation.log 2>&1;then
  echo "FAIL: SPU baseline $mutation negative control passed" >&2;exit 1
 fi
 grep -F "full sound equivalence mismatch" $mutation.log
 echo "PASS: detected SPU baseline $mutation negative control"
done
echo "PASS: 4 default/enabled unrequested SPU baseline comparisons and2 observer negative controls"
'
