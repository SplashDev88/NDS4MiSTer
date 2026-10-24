#!/usr/bin/env python3
"""Package rc.10 from its pinned, already qualified runtime; never rebuild gameplay."""
from pathlib import Path, PurePosixPath
import argparse, ast, hashlib, io, json, re, stat, subprocess, tarfile, zipfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Scripts/.NDS_Standalone/'
VERSION = 'v0.9.0-rc.10'
PINS = {
    'nds_standalone_host': 'e8dfbbd4c8b721e01db07bcf0d482701f180d857483229020de48a769fbf2301',
    'NDS_Standalone.rbf': '4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26',
    'support/nds_hybrid_3d_service': '78384aacd738bfbacdc50bd9ceb336a2704042e94f09da2b5e0c843caccde35d',
    'supervisor.py': '2a94d422e213c71aee3741be5589003376cc0058428a1e0ac4a05579f1df25fc',
}
DOCS = {'README.md': 'docs/STANDALONE_INSTALL_README.md',
        'RELEASE_NOTES.md': 'docs/RELEASE_NOTES_V090_RC10.md',
        'QUICK_START.txt': 'docs/STANDALONE_QUICK_START.txt',
        'GAME_CLOCK.md': 'docs/GAME_CLOCK.md',
        'VALIDATION_RC10.md': 'docs/release/VALIDATION_RC10.md',
        'LICENSE.txt': 'LICENSE.txt'}

def sha(data): return hashlib.sha256(data).hexdigest()
def js(value): return (json.dumps(value, indent=2, sort_keys=True)+'\n').encode()
def need(ok, message):
    if not ok: raise ValueError(message)
def safe(name):
    return bool(name) and not name.startswith('/') and '\\' not in name and ':' not in name and all(x not in ('','.','..') for x in name.split('/'))
def git(*args): return subprocess.check_output(['git','-C',str(ROOT),*args])

def assemble(kit):
    inputs = json.loads((ROOT/'docs/release/RC10_INPUTS.json').read_text())
    files, modes = {}, {}
    for name, record in inputs.items():
        need(safe(name), 'Unsafe input name')
        p = kit/name
        need(p.is_file() and not p.is_symlink(), 'Missing/nonregular input: '+name)
        data = p.read_bytes()
        need(sha(data)==record['sha256'], 'Changed qualified input: '+name)
        files[PREFIX+name] = data; modes[PREFIX+name] = record['mode']
    for n,h in PINS.items(): need(sha(files[PREFIX+n])==h, 'Runtime pin mismatch: '+n)
    for n in ('auto_movies.py','supervisor.py','Kickstart.sh','clock_control.py','video_target.py'):
        need(files[PREFIX+n]==(ROOT/'tools/standalone_host'/n).read_bytes(), 'Source differs: '+n)
    need(b'Speed hacks' not in files[PREFIX+'nds_standalone_host'], 'Visible speed menu')
    need(files[PREFIX+'NDS_speed.cfg']==b'NDS-SpeedHacks-v1\n5\n', 'Wrong automatic preset')
    for out, source in DOCS.items(): files[out] = (ROOT/source).read_bytes(); modes[out]=0o644
    launcher='Scripts/NDS4MiSTer.sh'
    files[launcher]=(ROOT/'tools/standalone_host/NDS4MiSTer.sh').read_bytes(); modes[launcher]=0o755
    need(b'/media/fat/Scripts/.NDS_Standalone/auto_movies.py' in files[launcher], 'Wrong launch path')
    revision=git('rev-parse','HEAD').decode().strip()
    need(not git('status','--porcelain'), 'Commit release source before packaging')
    source_name='source/NDS4MiSTer-rc10-source.tar.gz'
    files[PREFIX+source_name]=git('archive','--format=tar.gz','HEAD')
    fpga_name='source/NDS4MiSTer-rc10-fpga-5924000.tar.gz'
    files[PREFIX+fpga_name]=git('archive','--format=tar.gz','5924000f9d422fc624fdc0aecad424eab5ca9325')
    fm=json.loads(files[PREFIX+'fpga-source-manifest.json'])
    # Confirm every RTL, constraint and FPGA build source in the frozen manifest.
    checked=0
    with tarfile.open(fileobj=io.BytesIO(files[PREFIX+fpga_name]),mode='r:gz') as t:
        for name,h in fm['frozen_input_sha256'].items():
            if not (name.startswith(('rtl/','fpga/')) or Path(name).suffix in ('.qsf','.sdc','.qip')): continue
            data=t.extractfile(name).read()
            if name=='fpga/mister_nitro_console_island/NDS4MiSTer.qsf': data+=fm['build_override'].encode()
            need(sha(data)==h,'FPGA frozen source mismatch: '+name); checked+=1
    source_readme='''# rc.10 corresponding source

The renderer and FPGA are unchanged from Performance RC1 revision 2.
The host is rebuilt solely for the requested menu spacing. Build it from
`NDS4MiSTer-rc10-source.tar.gz` with tools/standalone_host/build.sh.
The recorded GCC 13.3 Cortex-A9 static command is unchanged.

- `NDS4MiSTer-rc10-source.tar.gz`: release documentation, packaging recipe and
  current launcher scripts. The host source includes menu removal and the two retained blank rows.
- `NDS4MiSTer-Performance-RC1-runtime.tar.gz`: exact prior host/renderer source used
  for the accepted build; the menu-spacing host is in the rc.10 source archive. Follow `BUILD_PERFORMANCE_RC.md`, compiler profile
  archive, `RC1-build-provenance.json` and `RC1-r2-host-provenance.json`.
- `NDS4MiSTer-rc10-fpga-5924000.tar.gz`: FPGA source at the exact selected
  commit. Append `build_override` from `../fpga-source-manifest.json` to
  `fpga/mister_nitro_console_island/NDS4MiSTer.qsf` before building. The packaging
  audit compares all frozen RTL/FPGA inputs. Static timing is not closed.
- Other archives and documents are historical corresponding-source records.
  Their old private launcher instructions do not apply to this release.

To reproduce the distribution, extract this release source and run
`python3 tools/package_rc10_release.py --runtime-kit /path/to/extracted/Scripts/.NDS_Standalone --out-dir /path/to/output`
from its Git checkout. The recipe accepts only hash-pinned qualified runtime
inputs; no cartridge, save, controller map or BIOS/firmware dump is needed.
The repository commit is recorded in `../BUILD_PROVENANCE.json`. Binary rebuild
instructions and dependency licenses are retained alongside the source.
'''
    files[PREFIX+'source/BUILD_RC10.md']=source_readme.encode()
    m=json.loads((ROOT/'docs/release/RC10_RUNTIME_MANIFEST.json').read_text())
    m.update(name='NDS4MiSTer',version=VERSION,release_channel='release candidate',
             remote_kit='/media/fat/Scripts/.NDS_Standalone',package_revision=3,
             packaging_source_revision=revision,launcher_sha256=sha(files[launcher]),
             installation_scope='Normal standalone kit; ordinary saves shared; existing display/input/clock settings retained.',
             hardware_validation='Inherited Performance RC1 r2 validation; separate rc.10 package launch receipt.',
             public_release_qualified=False,
             public_release_scope='Prepared release candidate with documented bounded validation and unresolved timing; publication is a separate action.',
             dx_experiment_included=False,
             launcher_change='Public wrapper selects the unchanged automatic movie launcher in .NDS_Standalone.',
             user_settings_included=False,
             release_performance_preset_included=True)
    for name in [source_name,fpga_name,'source/BUILD_RC10.md']:
        m['source_and_validation_sha256'][name]=sha(files[PREFIX+name])
    files[PREFIX+'manifest.json']=js(m)
    provenance={'version':VERSION,'packaging_source_revision':revision,
                'runtime_binaries_changed_for_packaging':['nds_standalone_host (menu spacing only)'],'runtime_pins':PINS,
                'baseline_package':'Performance RC1 revision 2',
                'host_change':'Blank rows before Right Stick Range and Reset; Right Stick Range and Lid are adjacent; renderer/FPGA/runtime settings unchanged',
                'baseline_zip_sha256':'a77fefbec42327d01fd92805b9c924056c638d52e2fa7698b2da69e41880c967',
                'frozen_fpga_inputs_checked':checked,'fpga_code_commit':fm['code_commit'],
                'dx_experiment_included':False,'static_timing_clean':False,
                'validation':'VALIDATION_RC10.md and external RC10_INSTALL_VALIDATION.json receipt'}
    files[PREFIX+'BUILD_PROVENANCE.json']=js(provenance)
    files[PREFIX+'SHA256SUMS']=''.join(sha(b)+'  '+n[len(PREFIX):]+'\n' for n,b in sorted(files.items()) if n.startswith(PREFIX)).encode()
    files['SHA256SUMS']=''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
    return files,modes,provenance

def audit(files):
    need(len(files)==len(set(files)), 'Duplicate archive names')
    for name,data in files.items():
        need(safe(name),'Unsafe package name: '+name)
        ext=PurePosixPath(name).suffix.lower()
        need(ext not in ('.nds','.sav','.dsv','.ini','.map','.rom','.mp4','.png','.jpg'), 'User/media content: '+name)
        need(ext!='.cfg' or name==PREFIX+'NDS_speed.cfg','Personal configuration: '+name)
        need(ext!='.bin' or name.startswith(PREFIX+'fmv/guest/'),'Unexpected binary asset: '+name)
        if ext in ('.py','.sh','.json','.md','.txt'):
            need(b'/Users/' not in data and b'192.168.' not in data, 'Private path/address: '+name)
    for root, sums in [('', 'SHA256SUMS'), (PREFIX,PREFIX+'SHA256SUMS')]:
        entries={}
        for line in files[sums].decode().splitlines():
            h,n=line.split('  ',1);need(n not in entries,'Duplicate checksum');entries[n]=h
        expected={n[len(root):] for n in files if n.startswith(root) and n!=sums}
        need(set(entries)==expected,'Incomplete checksums')
        for n,h in entries.items():need(sha(files[root+n])==h,'Checksum mismatch: '+n)
    m=json.loads(files[PREFIX+'manifest.json'])
    for group in ('automatic_movie_files','source_and_validation_sha256'):
        for n,h in m[group].items():need(sha(files[PREFIX+n])==h,'Manifest mismatch: '+n)
    need(sha(files['Scripts/NDS4MiSTer.sh'])==m['launcher_sha256'],'Launcher checksum')
    for n,h in PINS.items():need(sha(files[PREFIX+n])==h,'Runtime changed: '+n)
    # Verify upgrading leaves arbitrary existing preferences/saves intact.
    sentinels={PREFIX+'NDS_v1.CFG':b'old display',PREFIX+'NDS_rtc.cfg':b'old clock',
               PREFIX+'NDS_stick.cfg':b'old range',PREFIX+'inputs/pad.map':b'old map',
               'saves/NDS/test.sav':b'old progress','config/NDS_storage.cfg':b'old location'}
    installed=dict(sentinels);installed.update(files)
    need(all(installed[n]==b for n,b in sentinels.items()),'Upgrade overwrites user data')
    return {'status':'passed','files':len(files),'runtime_pins':PINS,'checksums':'complete',
            'upgrade_preserves_settings_and_saves':True,'dx_experiment_included':False}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime-kit',type=Path);p.add_argument('--out-dir',type=Path)
    p.add_argument('--audit',type=Path)
    a=p.parse_args()
    if a.audit:
        with zipfile.ZipFile(a.audit) as z:
            need(z.testzip() is None,'Corrupt ZIP')
            need(len(z.namelist())==len(set(z.namelist())),'Duplicate archive paths')
            need(all(stat.S_IFMT(i.external_attr>>16) in (0,stat.S_IFREG) for i in z.infolist()),'Nonregular archive member')
            files={n:z.read(n) for n in z.namelist()}
        print(json.dumps(audit(files),indent=2));return
    need(a.runtime_kit is not None and a.out_dir is not None,'--runtime-kit and --out-dir required')
    files,modes,provenance=assemble(a.runtime_kit);receipt=audit(files)
    a.out_dir.mkdir(parents=True,exist_ok=True)
    out=a.out_dir/('NDS4MiSTer_'+VERSION+'_Standalone.zip')
    need(not out.exists(),'Output already exists')
    with zipfile.ZipFile(out,'x',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for n,b in sorted(files.items()):
            i=zipfile.ZipInfo(n,(2026,10,23,0,0,0));i.create_system=3;i.compress_type=zipfile.ZIP_DEFLATED
            i.external_attr=(stat.S_IFREG|modes.get(n,0o644))<<16;z.writestr(i,b)
    with zipfile.ZipFile(out) as z:need(z.testzip() is None,'ZIP CRC failure')
    h=sha(out.read_bytes());out.with_suffix('.zip.sha256').write_text(h+'  '+out.name+'\n')
    receipt.update(archive=out.name,sha256=h,bytes=out.stat().st_size,provenance=provenance)
    (a.out_dir/'RC10_PACKAGE_VALIDATION.json').write_bytes(js(receipt))
    print(json.dumps(receipt,indent=2))
if __name__=='__main__':main()
