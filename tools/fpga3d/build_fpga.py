#!/usr/bin/env python3
"""Build this isolated worktree with the existing local Quartus toolchain."""
import pathlib,subprocess,datetime,json,sys
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'build-fpga3d/quartus';out.mkdir(parents=True,exist_ok=True)
stages=sys.argv[1:] or ['map','fit','asm','sta']
results={}
for stage in stages:
    args=['NDS4MiSTer']
    if stage!='sta':args+=['--write_settings_files=off']
    if stage=='fit':args+=['--parallel=4']
    cmd=['docker','run','--rm','--name','nds-fpga3d-build','--platform','linux/amd64',
         '-v',str(root)+':/workspace','-v','nds4mister_quartus17_native:/quartus-runtime:ro',
         '-v',str(out/'quartus_udev_compat.so')+':/usr/lib/x86_64-linux-gnu/libudev.so.1:ro',
         '-e','LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1',
         '-w','/workspace/fpga/mister_nitro_console_island','--entrypoint',
         '/quartus-runtime/quartus/bin/quartus_'+stage,'nds4mister-quartus-runtime:17.0.2',*args]
    print(datetime.datetime.now().isoformat(),stage,'BEGIN',flush=True)
    with (out/(stage+'.log')).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
    results[stage]=r.returncode;(out/'status.json').write_text(json.dumps(results,indent=2))
    print(datetime.datetime.now().isoformat(),stage,'END',r.returncode,flush=True)
    if r.returncode:sys.exit(r.returncode)
