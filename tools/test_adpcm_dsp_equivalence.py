#!/usr/bin/env python3
"""Exhaust the actual ADPCM arithmetic and compare complete sound modules."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RTL = 'third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd'
IMAGE = 'nds4mister-nvc-arm64:1.22.1'


def once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)


def arithmetic(text):
    start = text.index('                                    v_diff := v_step / 8;') if 'v_diff := v_step / 8;' in text else text.index('                                    v_product :=')
    end = text.index('                                    v_smp :=', start)
    return text[start:end]


def instrument(text, name):
    text = once(text, 'entity nds_sound is', 'entity ' + name + ' is')
    text = once(text, 'architecture arch of nds_sound is', 'architecture arch of ' + name + ' is')
    text = once(text, 'snd_active  : out std_logic_vector(15 downto 0)',
                'snd_active  : out std_logic_vector(15 downto 0);\n      audit : out std_logic_vector(639 downto 0)')
    probes = []
    for i in range(16):
        c = f'chan({i})'
        probes.append(f"audit({32*i+31} downto {32*i}) <= {c}.busy & {c}.format & {c}.repeatm & {c}.duty & '0' & {c}.pan & '0' & {c}.hold & \"0000\" & {c}.voldiv & '0' & {c}.volmul;")
    probes.append('audit(639 downto 512) <= cap(1).len & cap(0).len & cap(1).dad & cap(0).dad & cap(1).cnt & cap(0).cnt & soundbias & soundcnt;')
    return once(text, '\nbegin\n', '\nbegin\n' + '\n'.join(probes) + '\n')


def exhaustive(reference, candidate):
    functions = []
    for name, body in [('reference', reference), ('candidate', candidate)]:
        functions.append(f'''
function {name}(v_step : integer; v_nib : unsigned(3 downto 0)) return integer is
    variable v_product : unsigned(15 downto 0);
    variable v_fraction : integer range 0 to 11;
    variable v_diff : integer range 0 to 65535;
begin
{body}
    return v_diff;
end function;
''')
    return '''library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_adpcm_arithmetic is end;
architecture test of tb_adpcm_arithmetic is
''' + '\n'.join(functions) + '''
begin
process
    variable got, expected : integer;
begin
    for step in 0 to 32767 loop
        for nib in 0 to 15 loop
            expected := reference(step, to_unsigned(nib,4));
            got := candidate(step, to_unsigned(nib,4));
            assert got=expected report "ADPCM arithmetic mismatch step=" & integer'image(step) & " nib=" & integer'image(nib) severity failure;
        end loop;
    end loop;
    report "PASS: 524288 ADPCM step/nibble combinations; exact integer rounding";
    std.env.stop;
    wait;
end process;
end;
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--reference', default='5b734b990d352f308ce75e0f513110425f6a5e5e')
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original = subprocess.check_output(['git', 'show', args.reference + ':' + RTL], cwd=ROOT, text=True)
    candidate = (ROOT/RTL).read_text()
    ref_block, new_block = arithmetic(original), arithmetic(candidate)
    assert ref_block != new_block
    for label, source in [('reference', original), ('candidate', candidate)]:
        (output/('unit_' + label + '.vhd')).write_text(instrument(source, 'sound_unit_' + label))
    (output/'arithmetic.vhd').write_text(exhaustive(ref_block, new_block))
    # Missing truncation compensation must be caught by the exhaustive check.
    mutant = once(new_block, 'v_diff := to_integer(v_product) + v_fraction;', 'v_diff := to_integer(v_product);')
    (output/'mutant.vhd').write_text(exhaustive(ref_block, mutant))
    commands = [
        'nvc --std=2008 -a arithmetic.vhd',
        'nvc --std=2008 -e tb_adpcm_arithmetic',
        'nvc --std=2008 -r tb_adpcm_arithmetic --exit-severity=error > arithmetic.log 2>&1',
        'nvc --std=2008 --work=MEM -a /workspace/rtl/tb_mem_sync_ram_dual_byte_enable.vhd',
        'nvc --std=2008 -L . -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd',
        'nvc --std=2008 -L . -a /workspace/rtl/tb_nds_sound_fetch_state_ram.vhd unit_reference.vhd unit_candidate.vhd /workspace/rtl/tb_nds_sound_unit_equivalence.vhd',
    ]
    for mode in (0, 1):
        commands += [f'nvc --std=2008 -L . -e -gTABLE_MODE={mode} tb_nds_sound_unit_equivalence',
                     f'nvc --std=2008 -L . -r tb_nds_sound_unit_equivalence --ieee-warnings=off --exit-severity=error > full-table{mode}.log 2>&1']
    (output/'run.sh').write_text('set -euo pipefail\n'+'\n'.join(commands)+'\n')
    docker = ['docker', 'run', '--rm', '--network', 'none', '--cpus', '2', '-v', str(ROOT)+':/workspace:ro',
              '-v', str(output)+':/test', '-w', '/test', IMAGE, 'bash']
    with (output/'driver.log').open('w') as log:
        result = subprocess.run(docker + ['run.sh'], stdout=log, stderr=subprocess.STDOUT)
    assert result.returncode == 0, (result.returncode, output/'driver.log')
    negative = subprocess.run(docker + ['-lc', 'nvc --std=2008 -a mutant.vhd && nvc --std=2008 -e tb_adpcm_arithmetic && nvc --std=2008 -r tb_adpcm_arithmetic --exit-severity=error'], capture_output=True, text=True)
    (output/'mutant.log').write_text(negative.stdout + negative.stderr)
    assert negative.returncode != 0 and 'ADPCM arithmetic mismatch' in negative.stdout + negative.stderr
    for name in ('arithmetic', 'full-table0', 'full-table1'):
        log = (output/(name+'.log')).read_text()
        assert 'PASS:' in log, log[-2000:]
        print(name + ': ' + next(line for line in log.splitlines() if 'PASS:' in line), flush=True)
    report = dict(passed=True, reference=args.reference, candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
                  exhaustive_combinations=524288, full_sound_table_modes=[0,1], missing_remainder_mutant_detected=True,
                  limits='Arithmetic exhaustive for binary inputs; finite full-module simulation. FPGA mapping, routing and hardware playback remain unqualified.')
    (output/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS: arithmetic and full sound equivalence; broken rounding detected', flush=True)


if __name__ == '__main__':
    main()
