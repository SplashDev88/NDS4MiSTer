#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare actual accepted/candidate sound readback and complete sound modules."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

BASE = 'tools/fixtures/beta14/nds_sound_before_readback.vhd'
RTL = 'third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd'
IMAGE = 'nds4mister-nvc-arm64:1.22.1'
ROOT = Path(__file__).resolve().parents[1]
START = '   -- ================= read data =================\n'
END = '   -- ================= state: registers, decode, fetch =================\n'

def sha(value):
    return hashlib.sha256(value).hexdigest()

def once(source, old, new):
    assert source.count(old) == 1, (old, source.count(old))
    return source.replace(old, new, 1)

def split(source):
    prefix, body = source.split(START)
    block, suffix = body.split(END)
    return prefix, block, suffix

def channel(expr):
    return (f'{expr}.busy & {expr}.format & {expr}.repeatm & {expr}.duty & '
            f"'0' & {expr}.pan & '0' & {expr}.hold & \"0000\" & "
            f"{expr}.voldiv & '0' & {expr}.volmul")

def injected_state():
    assignments = []
    fields = {'volmul':(6,0), 'voldiv':(9,8), 'hold':(15,15), 'pan':(22,16),
              'duty':(26,24), 'repeatm':(28,27), 'format':(30,29), 'busy':(31,31)}
    for i in range(16):
        for name, (hi,lo) in fields.items():
            rhs=f'image({32*i+lo})' if hi==lo else f'image({32*i+hi} downto {32*i+lo})'
            assignments.append(f'   chan({i}).{name} <= {rhs};')
    for name,lo,hi in [('soundcnt',512,527),('soundbias',528,537),
                       ('cap(0).cnt',538,545),('cap(1).cnt',546,553),
                       ('cap(0).dad',554,580),('cap(1).dad',581,607),
                       ('cap(0).len',608,623),('cap(1).len',624,639)]:
        assignments.append(f'   {name} <= image({hi} downto {lo});')
    return '\n'.join(assignments)

def wrapper(source, name):
    channels = re.search(r'   type t_chan is record.*?   signal chan : t_chans;',source,re.S)[0]
    captures = re.search(r'   type t_cap is record.*?   signal cap : t_caps;',source,re.S)[0]
    block=split(source)[1]
    return f'''-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test wrapper: readback process and record types copied verbatim from source.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity {name} is
   port(bus7 : in proc_bus_gb_type; image : in std_logic_vector(639 downto 0);
        wired_out7 : out std_logic_vector(31 downto 0); wired_done7 : out std_logic);
end entity;
architecture test of {name} is
{channels}
{captures}
   signal soundcnt : std_logic_vector(15 downto 0);
   signal soundbias : std_logic_vector(9 downto 0);
begin
{injected_state()}
{block}
end architecture;
'''

def instrument(source, name):
    source=once(source,'entity nds_sound is',f'entity {name} is')
    source=once(source,'architecture arch of nds_sound is',f'architecture arch of {name} is')
    source=once(source,'snd_active  : out std_logic_vector(15 downto 0)',
                'snd_active  : out std_logic_vector(15 downto 0);\n      audit : out std_logic_vector(639 downto 0)')
    probes=[f'   audit({i*32+31} downto {i*32}) <= {channel(f"chan({i})")};' for i in range(16)]
    probes += ['   audit(639 downto 512) <= cap(1).len & cap(0).len & cap(1).dad & cap(0).dad & cap(1).cnt & cap(0).cnt & soundbias & soundcnt;']
    return once(source,'\nbegin\n','\nbegin\n'+'\n'.join(probes)+'\n')

def docker_case(output, tag, commands, expect_failure=False):
    script=output/(tag+'.sh')
    script.write_text('set -euo pipefail\n'+'\n'.join(commands)+'\n')
    command=['docker','run','--rm','--network','none','-v',str(ROOT)+':/workspace:ro',
             '-v',str(output)+':/test','-w','/test',IMAGE,'bash',script.name]
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=240)
    (output/(tag+'.driver.log')).write_text(result.stdout)
    runtime=output/(tag+'.run.log')
    text=runtime.read_text() if runtime.exists() else ''
    passed=(result.returncode!=0 and 'readback equivalence mismatch' in text) if expect_failure else (result.returncode==0 and 'PASS:' in text)
    record={'name':tag,'expected_failure':expect_failure,'exit_code':result.returncode,'passed':passed,'command':command,'runtime_log':text}
    print(json.dumps(record,indent=2),flush=True)
    if not passed:
        raise RuntimeError(f'{tag} failed; see {output}/{tag}.driver.log and .run.log\n'+result.stdout[-3000:]+text[-2500:])
    return record

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--negative-controls',action='store_true')
args=parser.parse_args()
output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
original=(ROOT / 'tools/fixtures/beta14/nds_sound_before_readback.vhd').read_text()
candidate=(ROOT/RTL).read_text()
op,ob,os=split(original);cp,cb,cs=split(candidate)
assert op==cp and os==cs, 'Changes outside the authorized readback block'
assert ob!=cb
assert set(re.findall(r'bus7\.(\w+)',ob))=={'Adr'}
assert set(re.findall(r'bus7\.(\w+)',cb))=={'Adr'}
for label,source in [('reference',original),('candidate',candidate)]:
    (output/('readback_'+label+'.vhd')).write_text(wrapper(source,'sound_readback_'+label))
    (output/('unit_'+label+'.vhd')).write_text(instrument(source,'sound_unit_'+label))
    (output/('source_'+label+'.vhd')).write_text(source)
base_commands=['nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd']
runs=[]
try:
    runs.append(docker_case(output,'readback',base_commands+[
        'nvc --std=2008 -L . -a readback_reference.vhd readback_candidate.vhd /workspace/rtl/tb_nds_sound_readback_equivalence.vhd',
        'nvc --std=2008 -L . -e tb_nds_sound_readback_equivalence',
        'nvc --std=2008 -L . -r tb_nds_sound_readback_equivalence --ieee-warnings=off --exit-severity=error > readback.run.log 2>&1']))
    for mode in (0,1):
        tag=f'full-table{mode}'
        runs.append(docker_case(output,tag,[
            'nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd',*base_commands,
            'nvc --std=2008 -L . -a /workspace/rtl/tb_nds_sound_fetch_state_ram.vhd unit_reference.vhd unit_candidate.vhd /workspace/rtl/tb_nds_sound_unit_equivalence.vhd',
            f'nvc --std=2008 -L . -e -gTABLE_MODE={mode} tb_nds_sound_unit_equivalence',
            f'nvc --std=2008 -L . -r tb_nds_sound_unit_equivalence --ieee-warnings=off --exit-severity=error > {tag}.run.log 2>&1']))
    if args.negative_controls:
        mutations=[
            ('wrong_channel',"channel_select(n) := '1';","channel_select((n+1) mod 16) := '1';"),
            ('lost_alias',"control_select(0) := '1';","if bus7.Adr(7 downto 5)=\"000\" then control_select(0) := '1'; end if;"),
            ('writeonly_reads',"when others => null;  -- SAD/TMR/PNT/LEN write-only","when others => channel_select(n) := '1';  -- deliberately broken"),
        ]
        # Scope the mutation to readback so identical write-side decode does
        # not accidentally become the mutation under test.
        for name,needle,replacement in mutations:
            mutant=cp+START+once(cb,needle,replacement)+END+cs
            filename='mutant_'+name+'.vhd'
            (output/filename).write_text(wrapper(mutant,'sound_readback_candidate'))
            tag='mutant-'+name
            runs.append(docker_case(output,tag,base_commands+[
                f'nvc --std=2008 -L . -a readback_reference.vhd {filename} /workspace/rtl/tb_nds_sound_readback_equivalence.vhd',
                'nvc --std=2008 -L . -e tb_nds_sound_readback_equivalence',
                f'nvc --std=2008 -L . -r tb_nds_sound_readback_equivalence --ieee-warnings=off --exit-severity=error > {tag}.run.log 2>&1'],True))
finally:
    report={'baseline_fixture':BASE,'baseline_sha256':sha(original.encode()),'candidate_sha256':sha(candidate.encode()),
            'outside_readback_byte_identical':op==cp and os==cs,
            'prefix_sha256':sha(op.encode()),'suffix_sha256':sha(os.encode()),
            'test_source_sha256':{str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in
                                 [Path(__file__).resolve(),ROOT/'rtl/tb_nds_sound_readback_equivalence.vhd',ROOT/'rtl/tb_nds_sound_unit_equivalence.vhd']},
            'image':IMAGE,'image_id':subprocess.check_output(['docker','image','inspect',IMAGE,'--format','{{.Id}}'],text=True).strip(),
            'runs':runs,'passed':len(runs)==(6 if args.negative_controls else 3) and all(r['passed'] for r in runs),
            'limits':'Finite actual-process and actual-module simulation, not formal proof or physical speed/timing validation. Stored data is binary; selected H/L/Z/W/- simulation strength preservation is outside this physical-register domain. Nonbinary address values are tested. Full units use unchanged existing portable RAM stand-ins and passive readback probes; real vendor RAM and playback performance require the FPGA build and user testing.'}
    (output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: sound readback and full-unit equivalence; evidence '+str(output))
