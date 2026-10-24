#!/usr/bin/env python3
"""Package rc.10 from its pinned, already qualified runtime; never rebuild gameplay."""
from pathlib import Path, PurePosixPath
import argparse, ast, hashlib, io, json, re, stat, subprocess, tarfile, zipfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Scripts/.NDS_Standalone/'
VERSION = 'v0.9.0-rc.10'
PINS = {
    'nds_standalone_host': 'c9e4f3a6b4aa1ec4bad8a120fc4c21229dc6ab92dfeef4d7db6206bc3661e118',
    'NDS_Standalone.rbf': '4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26',
    'support/nds_hybrid_3d_service': '1ad26b0fefaba899227b200c63983c70c5da49f6752c18cc3f19ad9bbf51d1cc',
    'supervisor.py': '92ebab31844c099f818e7734a2fc7b35cc1a6460ebe8bf461d67c3e30c7d52aa',
}
DOCS = {'README.md': 'docs/STANDALONE_INSTALL_README.md',
        'RELEASE_NOTES.md': 'docs/RELEASE_NOTES_V090_RC10.md',
        'QUICK_START.txt': 'docs/STANDALONE_QUICK_START.txt',
        'GAME_CLOCK.md': 'docs/GAME_CLOCK.md',
        'VALIDATION_RC10.md': 'docs/release/VALIDATION_RC10.md',
        'RC10_LOADING_FOLLOWUP.md': 'docs/release/RC10_LOADING_FOLLOWUP.md',
        'RC10_LOADING_VALIDATION.json': 'docs/release/RC10_LOADING_VALIDATION.json',
        'RC10_MOVIE_ASSETS.json': 'docs/release/RC10_MOVIE_ASSETS.json',
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
    source_files = {'auto_movies.py','supervisor.py','Kickstart.sh','clock_control.py','video_target.py'}
    source_files.update(n for n in inputs if n.startswith('fmv/') and n.endswith('.py'))
    for n in sorted(source_files):
        need(files[PREFIX+n]==(ROOT/'tools/standalone_host'/n).read_bytes(), 'Source differs: '+n)
    need(b'Speed hacks' not in files[PREFIX+'nds_standalone_host'], 'Visible speed menu')
    need(files[PREFIX+'NDS_speed.cfg']==b'NDS-SpeedHacks-v1\n5\n', 'Wrong automatic preset')
    for out, source in DOCS.items(): files[out] = (ROOT/source).read_bytes(); modes[out]=0o644
    approved_notes = '371d7f991f2b448c0af60532d132147fe7debba4c66029d8b9c5d7092ba2f4a9'
    for n in ('README.md','RELEASE_NOTES.md'):
        need(sha(files[n])==approved_notes, 'Approved release text changed: '+n)
    need(sha((ROOT/'README.md').read_bytes())==approved_notes, 'Repository README changed')
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

The FPGA and renderer are unchanged from the original rc.10 release. The host
adds loading activity and elapsed time, with bounded framed-stream completion
before CPU release. The loader streams qualified relocated cartridges, keeps a
verified local cache and avoids recompressing NSMB's patched ARM9 image.
Rebuild the renderer using `RC10-renderer-build.json`, the supplied profile archive
and FFmpeg build instructions. Build the loading-progress host from
`NDS4MiSTer-rc10-source.tar.gz` with tools/standalone_host/build.sh.
The recorded GCC 13.3 Cortex-A9 static command is unchanged.

- `NDS4MiSTer-rc10-source.tar.gz`: release documentation, packaging recipe and
  current host, loader and renderer source, including guarded whole-movie-inventory
  support and the loading/cache follow-up. The existing menu layout is retained.
- `NDS4MiSTer-Performance-RC1-runtime.tar.gz`: exact prior host/renderer source used
  for the earlier accepted build; the current host is in the rc.10 source archive. Follow `BUILD_PERFORMANCE_RC.md`, compiler profile
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
             remote_kit='/media/fat/Scripts/.NDS_Standalone',package_revision=10,
             packaging_source_revision=revision,helper_source_revision=revision,
             source_revision=revision,source_commit=revision,runtime_source_revision=revision,
             supervisor_source_revision=revision,loader_source_revision=revision,
             runtime_source_archive=source_name,source_archive_sha256=sha(files[PREFIX+source_name]),
             baseline_runtime_source_archive="source/NDS4MiSTer-Performance-RC1-runtime.tar.gz",
             launcher_sha256=sha(files[launcher]),
             installation_scope='Normal standalone kit; ordinary saves shared; existing display/input/clock settings retained.',
             hardware_validation='Original rc.10 validation plus loading/cache image equivalence, fault recovery, both Ni no Kuni openings and a short NSMB regression check; see VALIDATION_RC10.md and RC10_LOADING_VALIDATION.json.',
             public_release_qualified=False,
             public_release_scope='Prepared release candidate with documented bounded validation and unresolved timing; publication is a separate action.',
             dx_experiment_included=False,
             launcher_change='Public wrapper selects the paired automatic movie launcher and streaming/cache modules in .NDS_Standalone.',
             user_settings_included=False,
             release_performance_preset_included=True)
    for name in [source_name,fpga_name,'source/BUILD_RC10.md']:
        m['source_and_validation_sha256'][name]=sha(files[PREFIX+name])
    files[PREFIX+'manifest.json']=js(m)
    provenance={'version':VERSION,'packaging_source_revision':revision,
                'runtime_binaries_changed_for_packaging':['nds_standalone_host (loading progress and bounded framed-stream completion)'],'runtime_pins':PINS,
                'compared_with':'Original rc.10 package revision 9',
                'host_source_revision':'a5ee96647e00c0fe912e2e3dad95a4de8db7301d',
                'baseline_package':'Performance RC1 revision 2',
                'host_change':'Loading ROM activity and elapsed time; validate framed writes and final completion before CPU/save commit; existing menu retained',
                'renderer_change':'None from original rc.10 revision 9; identical binary and PGO settings',
                'loader_change':'Single-pass source hashing and relocated streaming, SHA256-verified prepared-ROM cache, uncompressed patched NSMB ARM9',
                'renderer_build_recipe':'source/RC10-renderer-build.json',
                'baseline_zip_sha256':'a77fefbec42327d01fd92805b9c924056c638d52e2fa7698b2da69e41880c967',
                'frozen_fpga_inputs_checked':checked,'fpga_code_commit':fm['code_commit'],
                'dx_experiment_included':False,'static_timing_clean':False,
                'validation':'VALIDATION_RC10.md, RC10_LOADING_FOLLOWUP.md, RC10_LOADING_VALIDATION.json and external RC10_INSTALL_VALIDATION.json receipt'}
    files[PREFIX+'BUILD_PROVENANCE.json']=js(provenance)
    files[PREFIX+'SHA256SUMS']=''.join(sha(b)+'  '+n[len(PREFIX):]+'\n' for n,b in sorted(files.items()) if n.startswith(PREFIX)).encode()
    files['SHA256SUMS']=''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
    return files,modes,provenance

def audit(files):
    need(len(files)==len(set(files)), 'Duplicate archive names')
    for name,data in files.items():
        need(safe(name),'Unsafe package name: '+name)
        ext=PurePosixPath(name).suffix.lower()
        need(not any(p in ('.cache','prepared-roms','__pycache__') for p in PurePosixPath(name).parts), 'Cache directory: '+name)
        need(ext not in ('.data','.tmp','.pyc'), 'Cache/temporary data: '+name)
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
