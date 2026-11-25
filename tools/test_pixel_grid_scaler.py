#!/usr/bin/env python3
"""Check real ascal nearest-neighbor edges at every supported integer scale."""
from pathlib import Path
import argparse
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]
def run(out):
    out.mkdir(parents=True,exist_ok=True)
    source=(ROOT/'fpga/mister_nitro_console_island/sys/ascal.vhd').read_text()
    # The baseline scaler relies on 4-bit hardware wrap for an idle/terminal
    # shift count. NVC rejects the natural-range underflow. Make those two
    # wraps explicit in the simulation copy only; no product RTL is changed.
    adaptations=[('o_pshift<=o_off(0) -1;','o_pshift<=(o_off(0)+15) MOD 16;'),
                 ('o_pshift<=o_pshift-1;','o_pshift<=(o_pshift+15) MOD 16;')]
    for before,after in adaptations:
        assert source.count(before)==1
        source=source.replace(before,after)
    (out/'ascal_sim.vhd').write_text(source)
    (out/'SIMULATION_ADAPTATIONS.json').write_text(json.dumps(dict(
        reason='Explicit four-bit counter wrap for strict NVC range checks',
        product_rtl_changed=False,replacements=adaptations),indent=2)+'\n')
    command='''set -eu
nvc --std=2008 -a ascal_sim.vhd /src/rtl/tb_nds_pixel_grid_scaler.vhd
for scale in 2 3 4 5; do
 nvc --std=2008 -e -gSCALE="$scale" tb_nds_pixel_grid_scaler
 nvc --std=2008 -r tb_nds_pixel_grid_scaler --ieee-warnings=off
done
'''
    r=subprocess.run(['docker','run','--rm','--network','none','-v',str(ROOT)+':/src:ro',
        '-v',str(out)+':/out','-w','/out','nds4mister-nvc-arm64:1.22.1','sh','-c',command],capture_output=True,text=True)
    (out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,end='');r.check_returncode()
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    run(p.parse_args().output.resolve())
