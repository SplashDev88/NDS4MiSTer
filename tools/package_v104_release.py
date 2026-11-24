#!/usr/bin/env python3
"""Package the qualified Pixel Grid FPGA in the permanent public install layout."""
from pathlib import Path
import argparse, ast, hashlib, json, os, re, stat, subprocess, tempfile, zipfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Scripts/.NDS/'
VERSION = 'v1.0.4'
BASE_REV = '6eadde791669feef6cdbbcfb1be36403519ab23c'
BASE_SHA = '52fddd009ca0dc7509eb56ec0f2241c3e9472901824aa3ee42d97128579264b9'
TEST_SHA = 'e717671d0b7d7942646b69e6dabf6a282862c18164a8f01a2fdca4c88bab3666'
CORE_SHA = '0a6909e73f96d5f8503edc18f397019dd8e8fce4c93bf70738552a3d768983fa'
TEST_HOST_SHA = 'aceb83bb346338882588ffa4f30d1cf5edb19fc03207233aa168eb190fbbd7ea'
FPGA_REV = '098030083e1ae8dab7c5fe110d4328325a1fd276'
FFIII_SHA = '4fc65bf8dddc2c400a7d30c6ce424132778246806fc626f07519cfbad27e2b3a'
RENDERER_SHA = '25eaa2e829d619d4a1fe792013d93b88129b454a3940761f012bb3a15bc28898'
OLD_RENDERER_SHA = 'f8e484b2eea0b7849e18b9f8a04c3dae6393acd33652d3f23606e898e3494437'
OLD_CORE_SHA = 'df7d7097eafdf4249cfcdffe5dc0e82e3a0a7e5ce3c9bce52b6647c69735be8c'
FFIII_HOOK = 'fmv/guest/packed_vx_ffiii_color.bin'

def sha(data): return hashlib.sha256(data).hexdigest()
def js(data): return (json.dumps(data, indent=2) + '\n').encode()
def sums(files): return ''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
def git(*args): return subprocess.check_output(['git',*args],cwd=ROOT)

def read_zip(path, digest):
    assert sha(path.read_bytes()) == digest
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        names=z.namelist();assert len(names)==len(set(names))
        assert all(not n.startswith('/') and all(p not in ('','.','..') for p in n.split('/')) for n in names)
        return {n:z.read(n) for n in names},{i.filename:stat.S_IMODE(i.external_attr>>16) for i in z.infolist()}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline',type=Path,required=True)
    ap.add_argument('--qualified',type=Path,required=True)
    ap.add_argument('--ffiii',type=Path,required=True)
    ap.add_argument('--ffiii-validation',type=Path,required=True)
    ap.add_argument('--version-proof',type=Path,required=True)
    ap.add_argument('--host-validation',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    assert not args.out.exists(), 'Preserve previous artifacts'
    assert not git('status','--porcelain').strip(), 'Commit source before packaging'
    revision=git('rev-parse','HEAD').decode().strip()
    original,modes=read_zip(args.baseline,BASE_SHA)
    qualified,_=read_zip(args.qualified,TEST_SHA)
    ffiii,ffiii_modes=read_zip(args.ffiii,FFIII_SHA)
    ffiii_manifest=json.loads(ffiii[PREFIX+'manifest.json'])
    ffiii_validation=json.loads(args.ffiii_validation.read_text())
    assert ffiii_validation['status']=='passed'
    assert ffiii_validation['qualified_archive_sha256']==FFIII_SHA
    assert ffiii_validation['renderer_sha256']==RENDERER_SHA
    for n,d in ffiii_validation['source_sha256'].items():assert sha((ROOT/n).read_bytes())==d,n
    private='Scripts/.NDS_PixelGrid_v103_Test3/'
    hardware=json.loads(qualified['PIXEL_GRID_HARDWARE.json'])
    validation=json.loads(qualified['PIXEL_GRID_VALIDATION.json'])
    inputs=json.loads(qualified['PIXEL_GRID_BUILD_INPUTS.json'])
    assert hardware['status']=='passed' and hardware['protected_files_unchanged'] is True
    assert hardware['core_sha256']==CORE_SHA and hardware['host_sha256']==TEST_HOST_SHA
    assert inputs['source_revision']==FPGA_REV
    for n,d in inputs['source_sha256'].items():assert sha((ROOT/n).read_bytes())==d,n
    proof=json.loads(args.version_proof.read_text())
    host_validation=json.loads(args.host_validation.read_text())
    host=(ROOT/'tools/standalone_host/nds_standalone_host').read_bytes()
    assert proof['baseline_sha256']==TEST_HOST_SHA
    assert proof['version_only_semantic_change'] is True
    assert host_validation['version_control_sha256']==proof['release_sha256']
    assert host_validation['host_sha256']==sha(host) and host_validation['build_exit_code']==0
    assert host_validation['status']=='passed'
    assert set(host_validation['passed_suites'])=={'test_host_display_menu','test_host_pixel_grid'}
    for n,d in host_validation['source_sha256'].items():assert sha((ROOT/n).read_bytes())==d,n
    assert b'NDS4MiSTer v1.0.4\0' in host
    files=dict(original)
    for name in ['NDS_Standalone.rbf','install_layout.py','video_target.py']:
        data=qualified[private+name]
        if name.endswith('.py'):assert data==(ROOT/'tools/standalone_host'/name).read_bytes()
        files[PREFIX+name]=data
    files[PREFIX+'nds_standalone_host']=host
    files[PREFIX+'nds_standalone_host.sha256']=(sha(host)+'  nds_standalone_host\n').encode()
    ffiii_overlay=['fmv/guest_byte_patch.py','fmv/guest_catalog.json',FFIII_HOOK,
                   'support/nds_hybrid_3d_service','support/nds_hybrid_3d_service.sha256']
    for n in ffiii_overlay:
        files[PREFIX+n]=ffiii[PREFIX+n]
        modes[PREFIX+n]=ffiii_modes[PREFIX+n]
        if n.startswith('fmv/') and n!=FFIII_HOOK:
            assert files[PREFIX+n]==(ROOT/'tools/standalone_host'/n).read_bytes()
    assert sha(files[PREFIX+'support/nds_hybrid_3d_service'])==RENDERER_SHA
    assert sha(files[PREFIX+FFIII_HOOK])==ffiii_validation['hook_sha256']
    files['Scripts/NDS.sh']=ffiii['Scripts/NDS.sh']
    supervisor=(ROOT/'tools/standalone_host/supervisor.py').read_bytes()
    assert supervisor==qualified[private+'supervisor.py'].replace(OLD_RENDERER_SHA.encode(),RENDERER_SHA.encode())
    assert supervisor==ffiii[PREFIX+'supervisor.py'].replace(OLD_CORE_SHA.encode(),CORE_SHA.encode())
    files[PREFIX+'supervisor.py']=supervisor
    assert sha(files[PREFIX+'NDS_Standalone.rbf'])==CORE_SHA
    assert files['Scripts/NDS.sh']==(ROOT/'tools/standalone_host/NDS.sh').read_bytes()
    base=json.loads(original[PREFIX+'manifest.json']);m=dict(base)
    m.update(name='NDS4MiSTer '+VERSION,version=VERSION,menu_version=VERSION,
        package_revision=base['package_revision']+1,release_channel='release-candidate',
        source_revision=revision,packaging_source_revision=revision,runtime_source_revision=revision,
        host_source_revision=revision,supervisor_source_revision=revision,
        renderer_source_revision=revision,helper_sha256=RENDERER_SHA,
        launcher_sha256=sha(files['Scripts/NDS.sh']),
        guest_catalog_sha256=sha(files[PREFIX+'fmv/guest_catalog.json']),
        automatic_movie_scope=ffiii_manifest['automatic_movie_scope'],
        ffiii_movie_color=ffiii_manifest['ffiii_movie_color'],
        qualified_ffiii_archive_sha256=FFIII_SHA,
        fpga_source_revision=FPGA_REV,core_source_revision=FPGA_REV,
        host_sha256=sha(host),core_sha256=CORE_SHA,supervisor_sha256=sha(supervisor),
        base_version='v1.0.3',base_source_revision=BASE_REV,base_zip_sha256=BASE_SHA,
        base_manifest_sha256=sha(original[PREFIX+'manifest.json']),
        packager_sha256=sha(Path(__file__).read_bytes()),
        tested_runtime_source_revision=hardware['runtime_source_revision'],
        qualified_test_archive_sha256=TEST_SHA,qualified_test_host_sha256=TEST_HOST_SHA,
        release_host_change='v1.0.4 label and one blank row between FPS and anti-aliasing when Direct Video Target is hidden',
        hardware_qualified=False,public_release_qualified=False,published=False,publication_authorized=False,
        hardware_qualified_components=['Pixel Grid Test 3 FPGA','Final Fantasy III regional movie beta'],
        validation_scope='Separately tested Test 3 FPGA and FFIII regional movie beta; combined software and package checks, no combined hardware rerun; see VALIDATION.json',
        combined_hardware_retested=False,
        source_reconstruction='Apply NDS4MiSTer_v1.0.4_Source.patch to the v1.0.3 tag; see SOURCE.md.',
        pixel_grid=dict(values=['Off','Light','Medium','Strong'],default='Off',
            modes=['1280x720','1920x1080'],integer_scales=[2,3,4,5],
            menu='Display options > Pixel Grid',persistence='System > Save settings',
            pipeline_cycles=4,dsp_blocks=3,ram_blocks=0),
        video_setup='Existing MiSTer.ini and user preferences retained; standard 720p/1080p HDMI required for grid')
    m['automatic_movie_files']={n:sha(files[PREFIX+n]) for n in sorted(set(base['automatic_movie_files'])|{FFIII_HOOK})}
    files[PREFIX+'manifest.json']=js(m)
    files[PREFIX+'SHA256SUMS']=sums({n[len(PREFIX):]:b for n,b in files.items() if n.startswith(PREFIX) and n!=PREFIX+'SHA256SUMS'})
    assert set(files)==set(original)|{PREFIX+FFIII_HOOK} and len(files)==86
    allowed={PREFIX+n for n in ['NDS_Standalone.rbf','nds_standalone_host','nds_standalone_host.sha256','supervisor.py','install_layout.py','video_target.py','manifest.json','SHA256SUMS']}
    allowed.update(PREFIX+n for n in ffiii_overlay)
    allowed.add('Scripts/NDS.sh')
    assert all(n in allowed or b==original[n] for n,b in files.items())
    for n,b in files.items():
        assert n=='Scripts/NDS.sh' or n.startswith(PREFIX)
        assert not n.lower().endswith(('.nds','.sav','.dsv','.ini'))
        assert not n.lower().endswith('.cfg') or n==PREFIX+'defaults/NDS_speed.cfg'
        assert not re.search(rb'/Users/[^/]+/|/home/[^/]+/|-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}',b),n
        if n.endswith('.py'):ast.parse(b,filename=n)
        relative=n[len(PREFIX):] if n.startswith(PREFIX) else None
        if relative in m['automatic_movie_files']:assert sha(b)==m['automatic_movie_files'][relative]
    # Reconstruct the exact release tree in a separate Git index, without a checkout.
    patch=git('diff','--binary',BASE_REV,revision)
    with tempfile.TemporaryDirectory(prefix='nds104-index-') as temp:
        env=dict(os.environ,GIT_INDEX_FILE=str(Path(temp)/'index'))
        subprocess.run(['git','read-tree',BASE_REV],cwd=ROOT,env=env,check=True)
        subprocess.run(['git','apply','--cached','--binary','-'],input=patch,cwd=ROOT,env=env,check=True)
        reconstructed=subprocess.check_output(['git','write-tree'],cwd=ROOT,env=env).strip()
        assert reconstructed==git('rev-parse',revision+'^{tree}').strip()
    summary=dict(version=VERSION,published=False,fpga_sha256=CORE_SHA,fpga_source_revision=FPGA_REV,
        host_sha256=sha(host),host_validation=host_validation,version_control_equivalence=proof,
        ffiii_validation=ffiii_validation,combined_hardware_retested=False,
        qualified_test_archive_sha256=TEST_SHA,
        hardware_games=[{k:g[k] for k in ['game','startup','gameplay','grid_strengths','checks'] if k in g} for g in hardware['games']],
        pixel_checks=validation['pixel_oracle']['checks'],layout_combinations=192,
        scaler_scales=[2,3,4,5],osd_checks=validation['integration']['pixels'],
        fit=validation['fit'],static_timing_clean=False,
        grid_worst_setup_slack_ns=min(v for k,v in validation['grid_timing_slacks_ns'].items() if 'hold' not in k),
        global_worst_setup_slack_ns=min(v for k,v in validation['global_timing_slacks_ns'].items() if 'setup' in k),
        limitations='Short gameplay checks, not full-game reliability; full core has static timing violations. Final host has the v1.0.4 label and menu spacing change; it passed host tests but has not been retested on hardware.',
        user_preferences_bundled=False,ffiii_renderer_and_hook_reused_from_qualified_beta=True,
        other_guest_payloads_unchanged_from_v103=True,
        publication_authorized=False)
    args.out.mkdir(parents=True)
    archive=args.out/f'NDS4MiSTer_{VERSION}_Standalone.zip'
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for n,b in files.items():
            info=zipfile.ZipInfo(n,(2026,11,24,0,0,0));info.create_system=3
            info.external_attr=(stat.S_IFREG|modes[n])<<16
            z.writestr(info,b,compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert {n:z.read(n) for n in z.namelist()}==files
        stage=args.out/'stage';z.extractall(stage)
    kit=stage/PREFIX
    for n in m['automatic_movie_files']:assert sha((kit/n).read_bytes())==m['automatic_movie_files'][n]
    for n,d in files.items():
        (stage/n).chmod(modes[n])
    subprocess.run([os.sys.executable,'-B','auto_movies.py','--validate-only'],cwd=kit,check=True)
    (args.out/'README.md').write_bytes((ROOT/'README.md').read_bytes())
    (args.out/'RELEASE_NOTES.md').write_bytes((ROOT/'docs/RELEASE_NOTES_V104.md').read_bytes())
    (args.out/'VALIDATION.json').write_bytes(js(summary))
    (args.out/f'NDS4MiSTer_{VERSION}_Source.patch').write_bytes(patch)
    (args.out/'SOURCE.md').write_text(f'Base: https://github.com/SplashDev88/NDS4MiSTer/tree/{BASE_REV}\n\nApply NDS4MiSTer_{VERSION}_Source.patch with `git apply --binary` to the v1.0.3 tag.\n\nResulting source revision: `{revision}`. The reconstructed Git tree was verified exactly.\nFPGA source: `{FPGA_REV}`; qualified RBF is reused unchanged.\nSource and binary licenses remain in the repository and runtime licenses directory.\n')
    (args.out/(archive.name+'.sha256')).write_text(sha(archive.read_bytes())+'  '+archive.name+'\n')
    receipt=dict(version=VERSION,archive=archive.name,sha256=sha(archive.read_bytes()),files=len(files),
        source_revision=revision,source_tree=reconstructed.decode(),source_patch_reconstruction_passed=True,
        runtime_validation_passed=True,checksums_passed=True,published=False,
        changed_runtime_files=[n for n in files if files[n]!=original.get(n)],
        executable_modes_preserved=True,private_paths_secrets_roms_saves_and_preferences_absent=True)
    (args.out/'PACKAGE_VALIDATION.json').write_bytes(js(receipt))
    print(json.dumps(receipt,indent=2))

if __name__=='__main__':main()
