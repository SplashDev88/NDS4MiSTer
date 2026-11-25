#!/usr/bin/env python3
"""Build this isolated worktree with the existing local Quartus toolchain."""
import pathlib,subprocess,datetime,json,sys
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'build-fpga3d/quartus';out.mkdir(parents=True,exist_ok=True)
stages=sys.argv[1:] or ['map','fit','asm','sta']
results={}
if 'map' in stages:
    # Different fitted revisions must not share derived multi-corner HPS node
    # caches: Quartus 17 can otherwise retain incompatible physical node IDs.
    db=root/'fpga/mister_nitro_console_island/db'
    backup=out/('timing-cache-before-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    for pattern in ['NDS4MiSTer.tiscmp.*.ddb','NDS4MiSTer.tis_db_list.ddb',
                    'NDS4MiSTer.sta_cmp.*.tdb','NDS4MiSTer.cyclonev_io_sim_cache.*.hsd']:
        for path in db.glob(pattern):
            backup.mkdir(exist_ok=True);path.rename(backup/path.name)
for stage in stages:
    # Use explicit four-corner path reports, including the accelerator's
    # boundaries, instead of launching a second analyzer against the same DB.
    args=['-t','../../tools/fpga3d/report_timing.tcl'] if stage=='sta' else ['NDS4MiSTer']
    if stage!='sta':args+=['--write_settings_files=off']
    if stage=='fit':args+=['--parallel=4']
    cmd=['docker','run','--rm','--name','nds-fpga3d-'+root.name,'--platform','linux/amd64',
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
