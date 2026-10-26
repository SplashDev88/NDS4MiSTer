#!/usr/bin/env python3
"""Package the tested cumulative Ecclesia Beta2 as RC12 without gameplay changes."""
from pathlib import Path
import argparse, ast, json, stat, zipfile
import package_rc11_release as common

ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v0.9.0-rc.12'
PREFIX = 'Scripts/.NDS_Standalone/'
BETA_PREFIX = 'Scripts/.NDS_Ecclesia_FMV_Beta2_20261026/'
BETA_SHA = '1336ad68aa5ba09a7cf9d71f0ddcae46c6e20dbf636a1d26c3a467a7b8e1a199'
BETA_REV = 'e185470c306fee61f4b6aea3c655eeb821c3210f'
PINS = {
    'NDS_Standalone.rbf': '876ec97a6044191515a0fea910eb1359417a466fdd0a23e31e0cca2a069a08fa',
    'support/nds_hybrid_3d_service': 'a9a2c813ebaf2367306aa0fdbd454d1884f2a22f059497cec64bfa9c04c55ab8',
    'nds_standalone_host': 'd05ba202611b653dea7003e5d93dfb6ab8ae299cfe1994280d2be77611a6597d',
}
need, sha, js, git = common.need, common.sha, common.js, common.git
common.ROOT = ROOT
common.PINS = PINS
DOCS = {
    'README.md':'docs/STANDALONE_INSTALL_README.md',
    'RELEASE_NOTES.md':'docs/RELEASE_NOTES_V090_RC12.md',
    'QUICK_START.txt':'docs/STANDALONE_QUICK_START.txt',
    'LICENSE.txt':'LICENSE.txt', 'GAME_CLOCK.md':'docs/GAME_CLOCK.md',
    'VALIDATION_RC12.md':'docs/release/VALIDATION_RC12.md',
    'VERSION_COVERAGE.md':'docs/release/VERSION_COVERAGE_RC12.md',
    'RETROTINK_DS_LITE.md':'docs/release/RETROTINK_DS_LITE.md',
}


def label_only(old,new):
    a,b = common.elf_sections(old),common.elf_sections(new)
    need(set(a)==set(b),'ELF section set changed')
    changed=[n for n in a if a[n]!=b[n]]
    need(set(changed)<={'.rodata','.note.gnu.build-id'},'Host executable code changed')
    need(a['.rodata'].replace(b'NDS4MiSTer v0.9.0-rc11',b'NDS4MiSTer v0.9.0-rc12')==b['.rodata'],'Host data change exceeds release label')
    return changed


def assemble(path):
    need(sha(path.read_bytes())==BETA_SHA,'Wrong cumulative Beta2 archive')
    original,original_modes=common.read_zip(path)
    beta={n[len(BETA_PREFIX):]:b for n,b in original.items() if n.startswith(BETA_PREFIX)}
    old=json.loads(beta['manifest.json'])
    for group in ['automatic_movie_files','source_and_validation_sha256']:
        for n,h in old[group].items():need(sha(beta[n])==h,'Beta input hash mismatch: '+n)
    need(not git('status','--porcelain'),'Commit release source before packaging')
    revision=git('rev-parse','HEAD').decode().strip()
    files,modes={},{}
    for n,b in beta.items():
        if n in common.ROOT_RUNTIME or n.startswith(('support/','fmv/','licenses/')):
            files[PREFIX+n]=b;modes[PREFIX+n]=original_modes[BETA_PREFIX+n] or 0o644
    host=(ROOT/'tools/standalone_host/nds_standalone_host').read_bytes()
    changed=label_only(beta['nds_standalone_host'],host)
    files[PREFIX+'nds_standalone_host']=host
    supervisor=(ROOT/'tools/standalone_host/supervisor.py').read_bytes()
    need(supervisor==beta['supervisor.py'].replace(b'v0.9.0-rc.11',VERSION.encode()),'Supervisor change exceeds release label')
    files[PREFIX+'supervisor.py']=supervisor
    # Beta2 carried two older developer checks; ship their matching current
    # source. Neither is imported or executed by the runtime movie loader.
    developer_checks=['fmv/test_prepare.py','fmv/verify_wait_hooks.py']
    for rel in developer_checks:
        files[PREFIX+rel]=(ROOT/'tools/standalone_host'/rel).read_bytes()
    for n,b in files.items():
        rel=n[len(PREFIX):]
        if rel.startswith('fmv/') or rel in ['Kickstart.sh','auto_movies.py','clock_control.py','video_target.py']:
            source=ROOT/'tools/standalone_host'/rel
            need(source.is_file() and source.read_bytes()==b,'Source/runtime mismatch: '+rel)
    for n,h in PINS.items():need(sha(files[PREFIX+n])==h,'Pinned runtime mismatch: '+n)
    launcher='Scripts/NDS4MiSTer.sh';files[launcher]=(ROOT/'tools/standalone_host/NDS4MiSTer.sh').read_bytes()
    modes[launcher]=modes[PREFIX+'nds_standalone_host']=0o755
    for n,p in DOCS.items():files[n]=(ROOT/p).read_bytes()
    source_name='source/NDS4MiSTer-rc12-source.tar.gz'
    files[PREFIX+source_name]=git('archive','--format=tar.gz','HEAD')
    for n in ['side-native-fpga-inputs.tar.gz','ffmpeg-7.1.1.tar.xz','portrait-combo3-pgo.tar.gz','RC11_FPGA_INPUTS.json','RC11_FPGA_BUILD.json']:
        files[PREFIX+'source/'+n]=beta['source/'+n]
    for n in ['BUILD_RC12.md','RC12_RENDERER_BUILD.sh','RC12_RUNTIME_INPUTS.json','RC12_RUNTIME_BUILD.json']:
        files[PREFIX+'source/'+n]=(ROOT/'docs/release'/n).read_bytes()
    for n in ['RC12_HOST_LABEL_VALIDATION.json','RC12_OFFLINE_VALIDATION.json','RC12_ENGLISH_NINO_HARDWARE.json']:
        files[PREFIX+'source/validation/'+n]=(ROOT/'docs/release'/n).read_bytes()
    # Preserve bounded evidence for unchanged code; historical private launcher names
    # in these reports are evidence provenance, not current installation instructions.
    keep=['nino-story-fix-validation.json','ni-no-kuni-all-movies-report.txt',
          'ecclesia-regions-REGIONAL_VALIDATION.json','ecclesia-regions-SOFTWARE_QUALIFICATION.json',
          'ecclesia-regions-EU_RAW_AUDIO_CHECK.json','ecclesia-regions-VERSION_COVERAGE.json',
          'ecclesia-regions-CUMULATIVE_REGRESSION_AUDIT.json','ecclesia-fmv-NATIVE_PAIRED_PACING.json']
    for n in keep:files[PREFIX+'source/validation/'+n]=beta['source/'+n]
    for n,b in beta.items():
        if n.startswith('source/validation/') and Path(n).name.startswith(('RC11_','PORTRAIT_FMV_','REGRESSION_')):
            files[PREFIX+n]=b
    for n in ['ECCLESIA_FMV_20261026.md','ECCLESIA_REGIONS_20261026.md']:
        files[PREFIX+'source/'+n]=(ROOT/'docs'/n).read_bytes()
    fpga=json.loads(files[PREFIX+'source/RC11_FPGA_INPUTS.json'])
    checked=common.check_fpga(files[PREFIX+'source/side-native-fpga-inputs.tar.gz'],fpga)
    files[PREFIX+'fpga-source-manifest.json']=js(dict(core_sha256=PINS['NDS_Standalone.rbf'],source_revision=old['core_source_revision'],packaged_fpga_source='source/side-native-fpga-inputs.tar.gz',frozen_input_sha256=fpga['all_build_inputs'],static_timing_closed=False))
    provenance=dict(version=VERSION,packaging_source_revision=revision,baseline_source_revision=BETA_REV,baseline_archive_sha256=BETA_SHA,runtime_pins=PINS,runtime_changes=['Host rc12 menu/footer label','Supervisor release text','Normal standalone launcher path'],host_changed_sections=changed,host_executable_code_identical=True,renderer_and_fpga_byte_identical=True,movie_profiles_and_hooks_byte_identical=True,frozen_fpga_inputs_checked=checked,published=False,validation_scope='Tested cumulative beta runtime; release-specific offline checks and separately recorded package launch checks; no full-playthrough certification')
    provenance['developer_check_scripts_updated']=developer_checks
    files[PREFIX+'BUILD_PROVENANCE.json']=js(provenance)
    profiles=json.loads(files[PREFIX+'fmv/profiles.json'])['profiles']
    m={k:old[k] for k in ['hps_clock_khz','required_firmware_capability','kernel_module_sha256','runtime_environment','nsmb_default','nsmb_regions','nsmb_validation','prepared_cache_budget_bytes','shared_saves','rtc_alarm_interrupts','rtc_snapshot_signature','rtc_snapshot_version','core_source_revision','portrait_fmv_variants']}
    runtime={n[len(PREFIX):]:sha(b) for n,b in files.items() if n.startswith(PREFIX) and not n.startswith((PREFIX+'source/',PREFIX+'licenses/')) and not n.endswith('BUILD_PROVENANCE.json')}
    m.update(name='NDS4MiSTer',version=VERSION,menu_version='v0.9.0-rc12',release_channel='release candidate',package_revision=1,remote_kit='/media/fat/Scripts/.NDS_Standalone',packaging_source_revision=revision,source_revision=revision,source_commit=revision,runtime_source_archive=source_name,runtime_source_revision=revision,source_archive_sha256=sha(files[PREFIX+source_name]),core_sha256=PINS['NDS_Standalone.rbf'],host_sha256=PINS['nds_standalone_host'],host_source_revision=revision,helper_sha256=PINS['support/nds_hybrid_3d_service'],helper_source_revision=BETA_REV,renderer_source_revision=BETA_REV,loader_source_revision=BETA_REV,supervisor_source_revision=revision,supervisor_sha256=sha(supervisor),launcher_sha256=sha(files[launcher]),automatic_movie_files=runtime,automatic_movie_scope='21 exact registered movie identities; includes Ecclesia USA/EU/JP/KR revision 0 and Ni no Kuni Japanese/English v1.0 story fix',prepared_cache_profiles=len(profiles),ecclesia_fmv_and_gameplay_variants=['YR9E0','YR9P0','YR9J0','YR9K0'],nino_story_variants=['NINO','NINO_EN10'],static_timing_clean=False,public_release_qualified=False,public_release_scope='Prepared release candidate; bounded validation and known limitations documented',user_dumps_included=False,user_settings_included=False,speed_hacks_menu=False,dx_experiment_included=False,release_performance_preset_included=True,installation_scope='Normal standalone kit; existing settings and saves retained',source_and_validation_sha256={n[len(PREFIX):]:sha(b) for n,b in files.items() if n.startswith(PREFIX+'source/')})
    files[PREFIX+'manifest.json']=js(m)
    files[PREFIX+'SHA256SUMS']=''.join(sha(b)+'  '+n[len(PREFIX):]+'\n' for n,b in sorted(files.items()) if n.startswith(PREFIX)).encode()
    files['SHA256SUMS']=''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
    return files,modes,provenance


def audit(files):
    result=common.audit(files)
    m=json.loads(files[PREFIX+'manifest.json'])
    need(m['version']==VERSION and m['menu_version']=='v0.9.0-rc12','Wrong release version')
    need(m['prepared_cache_profiles']==len(json.loads(files[PREFIX+'fmv/profiles.json'])['profiles'])==21,'Wrong movie-profile count')
    need(b'NDS4MiSTer v0.9.0-rc12' in files[PREFIX+'nds_standalone_host'],'Wrong host label')
    need(b'NDS4MiSTer v0.9.0-rc11' not in files[PREFIX+'nds_standalone_host'],'Stale host label')
    need(m['ecclesia_fmv_and_gameplay_variants']==['YR9E0','YR9P0','YR9J0','YR9K0'],'Incomplete Ecclesia coverage')
    result.update(movie_profiles=21,ecclesia_regions=4,version_labels='passed')
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--beta-zip',type=Path);p.add_argument('--out-dir',type=Path);p.add_argument('--audit',type=Path);a=p.parse_args()
    if a.audit:
        files,_=common.read_zip(a.audit);print(json.dumps(audit(files),indent=2));return
    need(a.beta_zip is not None and a.out_dir is not None,'--beta-zip and --out-dir required')
    files,modes,provenance=assemble(a.beta_zip);result=audit(files);a.out_dir.mkdir(parents=True,exist_ok=True)
    target=a.out_dir/('NDS4MiSTer_'+VERSION+'_Standalone.zip');need(not target.exists(),'Output archive exists')
    with zipfile.ZipFile(target,'x',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for name,body in sorted(files.items()):
            info=zipfile.ZipInfo(name,(2026,10,26,0,0,0));info.create_system=3;info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=(stat.S_IFREG|modes.get(name,0o644))<<16;z.writestr(info,body)
    reloaded,_=common.read_zip(target);audit(reloaded);digest=sha(target.read_bytes())
    target.with_suffix('.zip.sha256').write_text(digest+'  '+target.name+'\n')
    result.update(archive=target.name,sha256=digest,bytes=target.stat().st_size,provenance=provenance)
    (a.out_dir/'RC12_PACKAGE_VALIDATION.json').write_bytes(js(result));print(json.dumps(result,indent=2))


if __name__=='__main__':main()
