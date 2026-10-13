#!/usr/bin/env python3
"""Compare shared native menus with the frozen pre-sharing implementation."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def run(output):
    root = Path(__file__).resolve().parents[1]
    output.mkdir(parents=True, exist_ok=True)
    source = (root/'fpga/mister_nitro_console_island/sys/osd.v').read_text()
    before = 'always @(posedge clk_video) begin\n\treg        deD;'
    assert source.count(before) == 1
    source = source.replace(before, 'always @(posedge clk_video) begin : scan\n\treg        deD;')
    (output/'osd.v').write_text(source)
    reference = (root/'rtl/testdata/nds_osd_before_memory_share.v').read_text()
    reference = reference.replace('module osd\n', 'module osd_reference\n', 1)
    assert reference.count(before) == 1
    reference = reference.replace(before, 'always @(posedge clk_video) begin : scan\n\treg        deD;')
    # Verilator5.020 misclassifies an initialized static block variable as
    # a procedural assignment. Move only its declaration to module scope;
    # the initial value and all procedural assignments are identical.
    old = 'always @(posedge clk_video) begin\n\treg [OSD_COUNTER_BITS-1:0] cnt = 0;'
    assert reference.count(old) == 1
    reference = reference.replace(old, 'reg [OSD_COUNTER_BITS-1:0] cnt = 0;\nalways @(posedge clk_video) begin')
    (output/'osd_reference.v').write_text(reference)
    docker = ['docker','run','--rm','--network','none',
              '-v',str(root)+':/work:ro','-v',str(output)+':/out','-w','/out',
              os.environ.get('VERILATOR_IMAGE','nds4mister-rtl-verilator:24.04')]
    with (output/'compile.log').open('w') as log:
        result = subprocess.run(docker+['verilator','--binary','--timing','--assert','-Wno-fatal',
          '--top-module','tb_shared_osd','-j','2','--Mdir','/out/obj_dir',
          '/out/osd.v','/out/osd_reference.v','/work/rtl/nds_native_osd_memory.sv',
          '/work/rtl/tb_nds_shared_osd.sv'],stdout=log,stderr=log)
    if result.returncode:
        print((output/'compile.log').read_text())
        result.check_returncode()
    result = subprocess.run(docker+['/out/obj_dir/Vtb_shared_osd'],text=True,
                            stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (output/'test.log').write_text(result.stdout)
    print(result.stdout,flush=True)
    result.check_returncode()
    binary=output/'queue.vvp'
    subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb_osd_write_queue',
                    '-o',str(binary),str(root/'rtl/nds_native_osd_memory.sv'),
                    str(root/'rtl/tb_nds_osd_write_queue.sv')],check=True)
    result=subprocess.run([os.environ.get('VVP','vvp'),str(binary)],text=True,
                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (output/'queue.log').write_text(result.stdout)
    print(result.stdout,flush=True)
    result.check_returncode()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.output: run(args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='nds-shared-osd-') as d: run(Path(d))
