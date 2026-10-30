#!/usr/bin/env python3
"""Package the accepted cumulative SoulSilver Beta2 as RC13; never publish."""
from pathlib import Path
import argparse, ast, json, stat, zipfile
import package_rc11_release as common

ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v0.9.0-rc.13'
PREFIX = 'Scripts/.NDS_Standalone/'
BETA_PREFIX = 'Scripts/.NDS_SoulSilver_Beta2_20261029/'
BETA_SHA = '21c4cc3b5cd6cdb00e902d6fa7de009cdf9c204d2ddb53ddf64c3ef1e821f5b3'
BETA_REV = 'c24fddcc9cc2299babfce1cdfcf3ecd6f34bcab7'
PINS = {
    'NDS_Standalone.rbf': '876ec97a6044191515a0fea910eb1359417a466fdd0a23e31e0cca2a069a08fa',
    'support/nds_hybrid_3d_service': '8da111f3b9ad9ea1d55b12f9b76be8687d37a50a4d1bde7482b2e98a76c4c313',
    'nds_standalone_host': '7126bc4b5356d4aa33830baab47e3ff70047e6c2a414d825fc803c6e0ea23515',
}
need, sha, js, git = common.need, common.sha, common.js, common.git
common.ROOT = ROOT
common.PINS = PINS
DOCS = {
    'README.md':'docs/STANDALONE_INSTALL_README.md',
    'RELEASE_NOTES.md':'docs/RELEASE_NOTES_V090_RC13.md',
    'QUICK_START.txt':'docs/STANDALONE_QUICK_START.txt',
    'LICENSE.txt':'LICENSE.txt', 'GAME_CLOCK.md':'docs/GAME_CLOCK.md',
    'VALIDATION_RC13.md':'docs/release/VALIDATION_RC13.md',
    'VERSION_COVERAGE.md':'docs/release/VERSION_COVERAGE_RC13.md',
    'RETROTINK_DS_LITE.md':'docs/release/RETROTINK_DS_LITE.md',
}


def label_only(old,new):
    a,b = common.elf_sections(old),common.elf_sections(new)
    need(set(a)==set(b),'ELF section set changed')
    changed=[n for n in a if a[n]!=b[n]]
    need(set(changed)<={'.rodata','.note.gnu.build-id'},'Host executable code changed')
    need(a['.rodata'].replace(b'NDS4MiSTer v0.9.0-rc12',b'NDS4MiSTer v0.9.0-rc13')==b['.rodata'],'Host data change exceeds release label')
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
        if n == 'fmv/guest_trial_manifest.json':
            continue
        if n in common.ROOT_RUNTIME or n.startswith(('support/','fmv/','licenses/')):
            files[PREFIX+n]=b;modes[PREFIX+n]=original_modes[BETA_PREFIX+n] or 0o644
    host=(ROOT/'tools/standalone_host/nds_standalone_host').read_bytes()
    changed=label_only(beta['nds_standalone_host'],host)
    files[PREFIX+'nds_standalone_host']=host
    supervisor=(ROOT/'tools/standalone_host/supervisor.py').read_bytes()
    need(supervisor==beta['supervisor.py'].replace(b'v0.9.0-rc.12',VERSION.encode()),'Supervisor change exceeds release label')
    files[PREFIX+'supervisor.py']=supervisor
    for n,b in files.items():
        rel=n[len(PREFIX):]
        if rel.startswith('fmv/') or rel in ['Kickstart.sh','auto_movies.py','clock_control.py','video_target.py']:
            source=ROOT/'tools/standalone_host'/rel
            need(source.is_file() and source.read_bytes()==b,'Source/runtime mismatch: '+rel)
    for n,h in PINS.items():need(sha(files[PREFIX+n])==h,'Pinned runtime mismatch: '+n)
    launcher='Scripts/NDS4MiSTer.sh';files[launcher]=(ROOT/'tools/standalone_host/NDS4MiSTer.sh').read_bytes()
    need(files[launcher].splitlines()[2:] == original['Scripts/NDS_SoulSilver_Beta2.sh'].replace(b'.NDS_SoulSilver_Beta2_20261029', b'.NDS_Standalone').splitlines()[2:], 'Launcher selection differs from qualified beta')
    modes[launcher]=modes[PREFIX+'nds_standalone_host']=0o755
    for n,p in DOCS.items():files[n]=(ROOT/p).read_bytes()
    source_name='source/NDS4MiSTer-rc13-source.tar.gz'
    files[PREFIX+source_name]=git('archive','--format=tar.gz','HEAD')
    for n in ['side-native-fpga-inputs.tar.gz','ffmpeg-7.1.1.tar.xz','portrait-combo3-pgo.tar.gz','RC11_FPGA_INPUTS.json','RC11_FPGA_BUILD.json']:
        files[PREFIX+'source/'+n]=beta['source/'+n]
    for n in ['FFTA2_Beta2_source.tar.gz','FFTA2_Beta2_inputs.json','FFTA2_Beta2_build.json','FFTA2_Beta2_RENDERER_BUILD.sh']:
        files[PREFIX+'source/'+n]=beta['source/'+n]
    for n in ['BUILD_RC13.md','RC13_HOST_BUILD.sh']:
        files[PREFIX+'source/'+n]=(ROOT/'docs/release'/n).read_bytes()
    for n in ['RC13_HOST_LABEL_VALIDATION.json','RC13_EVIDENCE_INDEX.json','RC13_OFFLINE_VALIDATION.json']:
        files[PREFIX+'source/validation/'+n]=(ROOT/'docs/release'/n).read_bytes()
    # Preserve already-public bounded evidence for unchanged rc12 components.
    keep=['nino-story-fix-validation.json','ni-no-kuni-all-movies-report.txt',
          'ecclesia-regions-REGIONAL_VALIDATION.json','ecclesia-regions-SOFTWARE_QUALIFICATION.json',
          'ecclesia-regions-EU_RAW_AUDIO_CHECK.json','ecclesia-regions-VERSION_COVERAGE.json',
          'ecclesia-regions-CUMULATIVE_REGRESSION_AUDIT.json','ecclesia-fmv-NATIVE_PAIRED_PACING.json',
          'RC12_ENGLISH_NINO_HARDWARE.json']
    for n in keep:files[PREFIX+'source/validation/'+n]=beta['source/validation/'+n]
    for n,b in beta.items():
        if n.startswith('source/validation/') and Path(n).name.startswith(('RC11_','PORTRAIT_FMV_','REGRESSION_')):
            files[PREFIX+n]=b
    for n in ['ECCLESIA_FMV_20261026.md','ECCLESIA_REGIONS_20261026.md']:
        files[PREFIX+'source/'+n]=(ROOT/'docs'/n).read_bytes()
    fpga=json.loads(files[PREFIX+'source/RC11_FPGA_INPUTS.json'])
    checked=common.check_fpga(files[PREFIX+'source/side-native-fpga-inputs.tar.gz'],fpga)
    files[PREFIX+'fpga-source-manifest.json']=js(dict(core_sha256=PINS['NDS_Standalone.rbf'],source_revision=old['core_source_revision'],packaged_fpga_source='source/side-native-fpga-inputs.tar.gz',frozen_input_sha256=fpga['all_build_inputs'],static_timing_closed=False))
    provenance=dict(version=VERSION,packaging_source_revision=revision,baseline_source_revision=BETA_REV,baseline_archive_sha256=BETA_SHA,runtime_pins=PINS,runtime_changes=['Host rc13 menu/footer label','Supervisor release text','Normal standalone launcher path','Omit unused trial manifest from install tree'],host_changed_sections=changed,host_executable_code_identical=True,renderer_and_fpga_byte_identical=True,movie_profiles_and_hooks_byte_identical=True,frozen_fpga_inputs_checked=checked,published=False,validation_scope='Tested cumulative beta runtime; release-specific offline checks; final release archive not launched on hardware; no full-playthrough certification')
    provenance.update(rc12_source_revision='9a661c8b66615afd711cad294a57f07c1d1d5309', guest_catalog_byte_identical=True, guest_catalog_sha256='f92998bc27562fbe33c46ed27d50680f88ef1022e97b324dd6d411188883d1ee', publication_authorized=False)
    files[PREFIX+'BUILD_PROVENANCE.json']=js(provenance)
    profiles=json.loads(files[PREFIX+'fmv/profiles.json'])['profiles']
    m={k:old[k] for k in ['hps_clock_khz','required_firmware_capability','kernel_module_sha256','runtime_environment','nsmb_default','nsmb_regions','nsmb_validation','prepared_cache_budget_bytes','shared_saves','rtc_alarm_interrupts','rtc_snapshot_signature','rtc_snapshot_version','core_source_revision','portrait_fmv_variants']}
    runtime={n[len(PREFIX):]:sha(b) for n,b in files.items() if n.startswith(PREFIX) and not n.startswith((PREFIX+'source/',PREFIX+'licenses/')) and not n.endswith('BUILD_PROVENANCE.json')}
    m.update(name='NDS4MiSTer',version=VERSION,menu_version='v0.9.0-rc13',release_channel='release candidate',package_revision=1,remote_kit='/media/fat/Scripts/.NDS_Standalone',packaging_source_revision=revision,source_revision=revision,source_commit=revision,runtime_source_archive=source_name,runtime_source_revision=revision,source_archive_sha256=sha(files[PREFIX+source_name]),core_sha256=PINS['NDS_Standalone.rbf'],host_sha256=PINS['nds_standalone_host'],host_source_revision=revision,helper_sha256=PINS['support/nds_hybrid_3d_service'],helper_source_revision=old['helper_source_revision'],renderer_source_revision=old['renderer_source_revision'],loader_source_revision=old['loader_source_revision'],supervisor_source_revision=revision,supervisor_sha256=sha(supervisor),launcher_sha256=sha(files[launcher]),automatic_movie_files=runtime,automatic_movie_scope='21 exact registered movie identities; includes Ecclesia USA/EU/JP/KR revision 0 and Ni no Kuni Japanese/English v1.0 story fix',prepared_cache_profiles=len(profiles),ecclesia_fmv_and_gameplay_variants=['YR9E0','YR9P0','YR9J0','YR9K0'],nino_story_variants=['NINO','NINO_EN10'],static_timing_clean=False,public_release_qualified=False,public_release_scope='Prepared unpublished candidate; bounded perceptual/functional qualification, not full-playthrough or bit-exact certification',guest_catalog_sha256='f92998bc27562fbe33c46ed27d50680f88ef1022e97b324dd6d411188883d1ee',guest_optimization_variants=['CPUE1','IPKE0','IPGE0'],publication_authorized=False,published=False,user_dumps_included=False,user_settings_included=False,speed_hacks_menu=False,dx_experiment_included=False,release_performance_preset_included=True,installation_scope='Normal standalone kit; existing settings and saves retained',source_and_validation_sha256={n[len(PREFIX):]:sha(b) for n,b in files.items() if n.startswith(PREFIX+'source/')})
    files[PREFIX+'manifest.json']=js(m)
    files[PREFIX+'SHA256SUMS']=''.join(sha(b)+'  '+n[len(PREFIX):]+'\n' for n,b in sorted(files.items()) if n.startswith(PREFIX)).encode()
    files['SHA256SUMS']=''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
    return files,modes,provenance


def audit(files):
    result=common.audit(files)
    m=json.loads(files[PREFIX+'manifest.json'])
    need(m['version']==VERSION and m['menu_version']=='v0.9.0-rc13','Wrong release version')
    need(m['prepared_cache_profiles']==len(json.loads(files[PREFIX+'fmv/profiles.json'])['profiles'])==21,'Wrong movie-profile count')
    need(b'NDS4MiSTer v0.9.0-rc13' in files[PREFIX+'nds_standalone_host'],'Wrong host label')
    need(b'NDS4MiSTer v0.9.0-rc12' not in files[PREFIX+'nds_standalone_host'],'Stale host label')
    need(m['ecclesia_fmv_and_gameplay_variants']==['YR9E0','YR9P0','YR9J0','YR9K0'],'Incomplete Ecclesia coverage')
    catalog=json.loads(files[PREFIX+'fmv/guest_catalog.json'])
    need(sha(files[PREFIX+'fmv/guest_catalog.json'])==m['guest_catalog_sha256']=='f92998bc27562fbe33c46ed27d50680f88ef1022e97b324dd6d411188883d1ee','Catalog changed')
    identities=[e['manifest']['game_code']+str(e['manifest']['revision']) for e in catalog['entries']]
    need(identities==['CPUE1','IPKE0','IPGE0'],'Unexpected admitted identity')
    need(PREFIX+'fmv/guest_trial_manifest.json' not in files,'Unused trial manifest shipped')
    launcher=files['Scripts/NDS4MiSTer.sh']
    for line in [b'NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS_Standalone/fmv/guest_catalog.json',b'NDS_GUEST_PATCH_IDS=@catalog',b'NDS_GUEST_PATCH_FALLBACK_FMV=1',('NDS_GUEST_PATCH_SHA256='+m['guest_catalog_sha256']).encode()]:
        need(b'export '+line in launcher,'Launcher guard missing')
    need(m['publication_authorized'] is False and m['published'] is False,'Unexpected publication state')
    result.update(movie_profiles=21,ecclesia_regions=4,version_labels='passed',guest_catalog_identities=identities,guest_catalog_byte_identical=True)
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
            info=zipfile.ZipInfo(name,(2026,10,30,0,0,0));info.create_system=3;info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=(stat.S_IFREG|modes.get(name,0o644))<<16;z.writestr(info,body)
    reloaded,_=common.read_zip(target);audit(reloaded);digest=sha(target.read_bytes())
    target.with_suffix('.zip.sha256').write_text(digest+'  '+target.name+'\n')
    result.update(archive=target.name,sha256=digest,bytes=target.stat().st_size,provenance=provenance)
    (a.out_dir/'RC13_PACKAGE_VALIDATION.json').write_bytes(js(result));print(json.dumps(result,indent=2))


if __name__=='__main__':main()
