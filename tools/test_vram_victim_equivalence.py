#!/usr/bin/env python3
"""Compare complete accepted/candidate VRAM instances with passive state probes."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

BASE = 'tools/fixtures/beta14/nds_vram_before_victim.vhd'
IMAGE = 'nds4mister-nvc-arm64:1.22.1'
ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--seeds', default='1,29,137')
ap.add_argument('--cycles', type=int, default=12000)
ap.add_argument('--mutant', action='store_true')
args = ap.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
original = (ROOT / 'tools/fixtures/beta14/nds_vram_before_victim.vhd').read_text()
candidate = (ROOT / 'rtl/nds_nitro_vram.vhd').read_text()
assert 'adglobal2_mru' in candidate
assert 'adglobal2_mru' not in original
entity = original.split('   port\n', 1)[1].split('end entity;', 1)[0]
entity = re.sub(r'--[^\n]*', '', entity)
ports = re.findall(r'(\w+)\s*:\s*(in|out)\s+((?:std_logic_vector|unsigned)\([^\n;]+?\)|std_logic)(?:\s*:=\s*[^;\n]+)?\s*[;\n]', entity)
assert len(ports) >= 75, len(ports)
ports += [('audit_victims', 'out', 'std_logic_vector(161 downto 0)'),
          ('audit_primary', 'out', 'std_logic_vector(647 downto 0)'),
          ('audit_events', 'out', 'std_logic_vector(11 downto 0)')]

def once(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new)

def instrument(text, name, physical):
    text = once(text, 'entity nds_vram is', f'entity {name} is')
    text = once(text, 'architecture arch of nds_vram is', f'architecture arch of {name} is')
    text = once(text, 'dbg_rbusy    : out std_logic',
                "dbg_rbusy : out std_logic;\n      audit_victims : out std_logic_vector(161 downto 0);\n      audit_primary : out std_logic_vector(647 downto 0);\n      audit_events : out std_logic_vector(11 downto 0) := (others => '0')")
    probes = []
    def record(expr):
        return f'{expr}.valid & std_logic_vector(to_unsigned({expr}.bank,2)) & std_logic_vector({expr}.line) & {expr}.data'
    for i in range(2):
        idx = str(i) if not physical else ('adglobal2_mru' if i == 0 else '1-adglobal2_mru')
        probes.append(f'   audit_victims({81*i+80} downto {81*i}) <= {record("adglobal2("+idx+")")};')
    for i in range(8):
        probes.append(f'   audit_primary({81*i+80} downto {81*i}) <= {record("adline("+str(i)+")")};')
    text = once(text, '\nbegin\n', '\nbegin\n' + '\n'.join(probes) + '\n')
    text = once(text, "         rdone_int <= (others => '0');", "         audit_events <= (others => '0');\n         rdone_int <= (others => '0');")
    text = once(text, '                  v_old_line := v_adl(v_adq(v_adh).chan);',
                "                  audit_events(0) <= '1';\n                  v_old_line := v_adl(v_adq(v_adh).chan);")
    text = once(text, '                  if v_g2_hit >= 0 then', "                  if v_g2_hit >= 0 then\n                     audit_events(9) <= '1';")
    text = once(text, '                     if v_direct_hit then', "                     if v_direct_hit then\n                        audit_events(3) <= '1';")
    anchor = re.search(r'^\s*v_line_data := v_g2\([^\n]+\)\.data;', text, re.M)[0]
    text = once(text, anchor, "\n                        if v_g2_hit=0 then audit_events(1)<='1'; else audit_events(2)<='1'; end if;" + anchor)
    text = once(text, '                  elsif v_pair_index >= 0 then', "                  elsif v_pair_index >= 0 then\n                     audit_events(4) <= '1';")
    text = once(text, '                  v_pair_returning := true;', "                  v_pair_returning := true;\n                  audit_events(5) <= '1';")
    anchor = "                     v_g2(i).valid := '0';"
    assert text.count(anchor) == 2
    text = text.replace(anchor, "                     if v_g2(i).valid='1' then audit_events(6)<='1'; end if;\n"+anchor, 1)
    pos = text.rfind(anchor)
    text = text[:pos] + "                     if v_g2(i).valid='1' then audit_events(7)<='1'; end if;\n" + text[pos:]
    text = once(text, "               v_slot := v_adq(v_adh).slot;", "               if v_adq(v_adh).cacheable='0' then audit_events(8)<='1'; end if;\n               v_slot := v_adq(v_adh).slot;")
    text = once(text, "                     rsrv_req  <= '1';", "                     audit_events(10) <= '1';\n                     rsrv_req  <= '1';")
    return text

ref = instrument(original, 'nds_vram_reference', False)
can = instrument(candidate, 'nds_vram_candidate', True)
if args.mutant:
    can = once(can, 'idx := 1 - mru;', 'idx := mru;') if 'idx := 1 - mru;' in can else can
    # Corrupt a real reset-independent operation, not the passive observation.
    anchor = 'mru := 1 - mru;'
    assert anchor in can, 'Locate candidate MRU flip before defining mutant'
    can = can.replace(anchor, 'mru := mru;', 1)
(out / 'reference.vhd').write_text(ref)
(out / 'candidate.vhd').write_text(can)
decl = []
maps = [[], []]
checks = []
for name, direction, typ in ports:
    if direction == 'in':
        init = "'0'" if typ == 'std_logic' else "(others=>'0')"
        if name == 'reset': init = "'1'"
        decl.append(f'   signal {name} : {typ} := {init};')
        for side in range(2): maps[side].append(name + '=>' + name)
    else:
        decl.append(f'   type pair_{name} is array(0 to 1) of {typ};\n   signal {name} : pair_{name};')
        for side in range(2): maps[side].append(f'{name}=>{name}({side})')
        checks.append(f'      assert {name}(0)={name}(1) report "equivalence mismatch: {name}, phase=" & integer\'image(phase) & ", cycle=" & integer\'image(cycles) severity failure;')
instances = '\n'.join(f'   dut{side}: entity work.nds_vram_{name} generic map(is_simu=>\'1\', POSTED_WRITES=>POSTED) port map(\n      '+',\n      '.join(maps[side])+');' for side,name in enumerate(['reference','candidate']))
channels = ['bg','obj','bgep','objep','bgb','objb','bgepb','objepb']
wiring = '\n'.join(f'   rdr_{ch}_req <= requests({i}); rdr_{ch}_addr <= resize(addresses({i}),rdr_{ch}_addr\'length);\n   accepts({i}) <= rdr_{ch}_accept(0); dones({i}) <= rdr_{ch}_done(0); words({i}) <= rdr_{ch}_dout(0);' for i,ch in enumerate(channels))
bench = (ROOT / 'rtl/tb_nds_vram_victim_equivalence.vhd').read_text()
for token, value in [('DECLARATIONS', '\n'.join(decl)), ('INSTANCES', instances), ('CHECKS', '\n'.join(checks)), ('WIRING', wiring)]:
    bench = once(bench, '-- @'+token+'@', value)
(out / 'bench.vhd').write_text(bench)
commands = ["nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd",
            "nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd reference.vhd candidate.vhd bench.vhd"]
runs = []
for seed in args.seeds.split(','):
    for posted in (['true'] if args.mutant else ['true','false']):
        tag=f'seed{seed}-posted{posted}'
        commands += [f'nvc --std=2008 -L . -e -g SEED={int(seed)} -g POSTED={posted} -g RANDOM_CYCLES={args.cycles} tb_nds_vram_victim_equivalence',
                     f'nvc --std=2008 -L . -r tb_nds_vram_victim_equivalence --ieee-warnings=off --exit-severity=error > {tag}.log 2>&1']
        runs.append(tag)
(out/'run.sh').write_text('set -euo pipefail\n'+'\n'.join(commands)+'\n')
command=['docker','run','--rm','--network','none','-v',str(ROOT)+':/workspace:ro','-v',str(out)+':/test','-w','/test',IMAGE,'bash','run.sh']
completed=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'driver.log').write_text(completed.stdout)
result={'command':command,'baseline_fixture':BASE,'baseline_rtl_sha256':hashlib.sha256(original.encode()).hexdigest(),
        'candidate_rtl_sha256':hashlib.sha256(candidate.encode()).hexdigest(),'mutant':args.mutant,'returncode':completed.returncode,
        'port_count':len(ports)-3,'runs':{tag:(out/(tag+'.log')).read_text() if (out/(tag+'.log')).exists() else None for tag in runs},
        'limits':'Simulation uses the existing portable dual-port RAM model. Passive test-only probes and event pulses observe canonical caches; product RTL has no test ports. The synthetic shared backing model preloads nonzero fixture data only after the complete real reset-clear pass.'}
result['passed'] = completed.returncode == 0 and all(v and 'PASS: full VRAM' in v for v in result['runs'].values())
if args.mutant:
    result['passed'] = completed.returncode != 0 and any(v and 'equivalence mismatch:' in v for v in result['runs'].values())
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
raise SystemExit(0 if result['passed'] else 1)
