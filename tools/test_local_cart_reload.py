#!/usr/bin/env python3
"""Verify hot cartridge replacement under real DDR contention and a broken-flush control."""
from pathlib import Path
import argparse,json,subprocess

ROOT=Path(__file__).resolve().parents[1]

def run(output):
    output.mkdir(parents=True,exist_ok=True)
    results=[]
    for bad in [0,1]:
        name='broken-flush' if bad else 'normal'
        binary=output/(name+'.vvp')
        with (output/(name+'.compile.log')).open('w') as log:
            subprocess.run(['iverilog','-g2012','-s','tb_nds_local_cart_reload',
                '-Ptb_nds_local_cart_reload.BAD_FLUSH='+str(bad),'-o',str(binary),
                *[str(ROOT/n) for n in ['rtl/tb_nds_local_cart_reload.sv',
                    'rtl/nds_h3d_ddr_fabric.sv','rtl/nds_ddram_arbiter_4client.sv',
                    'third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv']]],
                stdout=log,stderr=log,check=True)
        result=subprocess.run(['vvp',str(binary)],capture_output=True,text=True,timeout=40)
        text=result.stdout+result.stderr
        (output/(name+'.log')).write_text(text)
        if bad:
            assert result.returncode and 'replacement cartridge stale/corrupt' in text,text
        else:
            assert not result.returncode and 'PASS eight live cartridge replacements' in text,text
        results.append(dict(name=name,exit_code=result.returncode,expected_failure=bool(bad)))
        print(name,'fault detected' if bad else 'passed',flush=True)
    (output/'results.json').write_text(json.dumps(results,indent=2)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    run(parser.parse_args().output.resolve())
