#!/usr/bin/env python3
"""Prepare the accepted Mario Kart/Y-C beta as separate runtime and source ZIPs."""
from pathlib import Path
import argparse
import ast
import io
import json
import shutil
import stat
import tarfile
import zipfile
import package_rc11_release as common

ROOT = Path(__file__).resolve().parents[1]
common.ROOT = ROOT
VERSION = 'v0.9.0-rc.14'
PREFIX = 'Scripts/.NDS_Standalone/'
BETA_PREFIX = 'Scripts/.NDS_MarioKart_RegionalYCBeta5_20261106/'
BETA_LAUNCHER = 'Scripts/NDS_MarioKart_Regional_YC_Beta5.sh'
BETA_SHA = 'be0c12ea4923e570c546d3b174ceae9c79357e26136f6a163285b11680ce396c'
YC_PREFIX = 'Scripts/.NDS_DV1_YC_Beta2_20261103/'
YC_SHA = 'c4e74bda8f5da1c9d34f22d28af13bad5574765ca30c29556e04511d4756b9c8'
PROFILE_SHA = 'ea1ca681eceffae91a1702aaa6e3e53319ce9a82b9aa5d532e00bf731ed6b3ad'
PROFILE_NAME = 'NDS4MiSTer_RetroTINK4K_MrMoro_Profiles.zip'
PINS = {
    'NDS_Standalone.rbf': 'e297b21a877b41128f7762e54907ba460c49e43d294ece5a32e550784651f5da',
    'support/nds_hybrid_3d_service': '9090782e550b963ed752f60da2a449803c5912a73e0f8ded5caebe8695c18fca',
    'fmv/guest_catalog.json': '43062a4782cbc16f55843f9e09babdf2fe00488f43c6f2308ff308210e117598',
}
DOCS = {
    'README.md': 'docs/STANDALONE_INSTALL_README.md',
    'QUICK_START.txt': 'docs/STANDALONE_QUICK_START.txt',
    'VERSION_COVERAGE.md': 'docs/release/VERSION_COVERAGE_RC14.md',
    'RELEASE_NOTES.md': 'docs/RELEASE_NOTES_V090_RC14.md',
    'VALIDATION_RC14.md': 'docs/release/VALIDATION_RC14.md',
    'GAME_CLOCK.md': 'docs/GAME_CLOCK.md',
    'RETROTINK_DS_LITE.md': 'docs/release/RETROTINK_DS_LITE.md',
    'RETROTINK_MR_MORO.md': 'docs/release/RETROTINK_MR_MORO.md',
    'LICENSE.txt': 'LICENSE.txt',
}
need, sha, js = common.need, common.sha, common.js


def inventory(data, expected):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as t:
        names = [m.name for m in t.getmembers() if m.isfile()]
        need(set(names) == set(expected), 'Frozen input inventory differs')
        for name, digest in expected.items():
            need(sha(t.extractfile(name).read()) == digest, 'Frozen input mismatch: ' + name)
    return len(names)


def write_zip(path, files, modes=None):
    need(not path.exists(), 'Output already exists: ' + path.name)
    modes = modes or {}
    with zipfile.ZipFile(path, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2026, 11, 6, 0, 0, 0))
            item.create_system = 3
            item.external_attr = (stat.S_IFREG | modes.get(name, 0o644)) << 16
            z.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    path.with_suffix('.zip.sha256').write_text(sha(path.read_bytes()) + '  ' + path.name + '\n')


def checksums(files):
    return ''.join(sha(data) + '  ' + name + '\n' for name, data in sorted(files.items())).encode()


def audit(files):
    for name, data in files.items():
        common.content_audit(name, data)
        need('/source/' not in name, 'Development sources in runtime ZIP')
        need(not Path(name).name.startswith(('test_', 'verify_', 'build_')), 'Development tool in runtime ZIP')
        if name.endswith('.py'):
            ast.parse(data, filename=name)
    m = json.loads(files[PREFIX + 'manifest.json'])
    need(m['version'] == VERSION and m['menu_version'] == 'v0.9.0-rc14', 'Incorrect release label')
    need(m['automatic_movie_files'], 'Missing runtime inventory')
    for name, digest in m['automatic_movie_files'].items():
        need(sha(files[PREFIX + name]) == digest, 'Runtime pin mismatch: ' + name)
    for name, digest in PINS.items():
        need(sha(files[PREFIX + name]) == digest, 'Changed accepted component: ' + name)
    need(sha(files[PREFIX + 'nds_standalone_host']) == m['host_sha256'], 'Host hash mismatch')
    need(sha(files['Scripts/NDS4MiSTer.sh']) == m['launcher_sha256'], 'Launcher hash mismatch')
    need(sha(files[PREFIX + 'supervisor.py']) == m['supervisor_sha256'], 'Supervisor hash mismatch')
    need(b'NDS4MiSTer v0.9.0-rc14\0' in files[PREFIX + 'nds_standalone_host'], 'Host version missing')
    need(b'NDS4MiSTer v0.9.0-rc13-yc-beta2\0' not in files[PREFIX + 'nds_standalone_host'], 'Stale host version')
    catalog = json.loads(files[PREFIX + 'fmv/guest_catalog.json'])
    identities = [e['manifest']['game_code'] + str(e['manifest']['revision']) for e in catalog['entries']]
    need(len(identities) == 26 and len(set(identities)) == 26, 'Unexpected catalog coverage')
    need({'AMCE0', 'AMCP0', 'AMCJ0', 'AMCK0'} <= set(identities), 'Missing Mario Kart region')
    launcher = files['Scripts/NDS4MiSTer.sh']
    for value in [b'NDS_GX_ASSET_CACHE=1', b'NDS_GUEST_PATCH_IDS=@catalog',
                  b'NDS_GUEST_PATCH_FALLBACK_FMV=1',
                  ('NDS_GUEST_PATCH_SHA256=' + PINS['fmv/guest_catalog.json']).encode(),
                  ('NDS_GUEST_PATCH_MANIFEST=/media/fat/' + PREFIX + 'fmv/guest_catalog.json').encode()]:
        need(b'export ' + value in launcher, 'Launcher setting missing')
    need(files['SHA256SUMS'] == checksums({n: b for n, b in files.items() if n != 'SHA256SUMS'}), 'Root checksums differ')
    return dict(state='passed', files=len(files), runtime_files=len(m['automatic_movie_files']),
                catalog_entries=26, guest_identities=identities, version_labels='passed',
                no_development_sources_or_personal_data=True)


def assemble(beta_path, yc_path, profile_path, out):
    need(sha(beta_path.read_bytes()) == BETA_SHA, 'Wrong accepted Beta 5 ZIP')
    need(sha(yc_path.read_bytes()) == YC_SHA, 'Wrong Y/C source archive')
    need(sha(profile_path.read_bytes()) == PROFILE_SHA, 'Wrong contributed profile ZIP')
    profile_receipt = json.loads((ROOT / 'docs/release/RC14_RETROTINK_PROFILE.json').read_text())
    with zipfile.ZipFile(profile_path) as z:
        need(z.testzip() is None, 'Profile ZIP CRC failure')
        need(len(z.namelist()) == len(set(z.namelist())), 'Duplicate profile path')
        for item in z.infolist():
            need(common.safe(item.filename.rstrip('/')), 'Unsafe profile path')
            need(stat.S_IFMT(item.external_attr >> 16) in (stat.S_IFDIR, stat.S_IFREG), 'Nonregular profile entry')
            if not item.is_dir():
                need(sha(z.read(item)) == profile_receipt['files'][item.filename], 'Profile input differs')
    need(not common.git('status', '--porcelain'), 'Commit release source before packaging')
    revision = common.git('rev-parse', 'HEAD').decode().strip()
    beta, beta_modes = common.read_zip(beta_path)
    original = {n[len(BETA_PREFIX):]: b for n, b in beta.items() if n.startswith(BETA_PREFIX)}
    old = json.loads(original['manifest.json'])
    for name, digest in old['automatic_movie_files'].items():
        need(sha(original[name]) == digest, 'Accepted beta pin mismatch: ' + name)
    files = {PREFIX + n: b for n, b in original.items() if n != 'manifest.json'}
    modes = {PREFIX + n: beta_modes[BETA_PREFIX + n] for n in original if n != 'manifest.json'}
    host = ROOT / 'tools/standalone_host'
    files[PREFIX + 'nds_standalone_host'] = (host / 'nds_standalone_host').read_bytes()
    build = json.loads((ROOT / 'docs/release/RC14_HOST_BUILD.json').read_text())
    need(sha(files[PREFIX + 'nds_standalone_host']) == build['host_sha256'], 'Unrecorded host build')
    files[PREFIX + 'supervisor.py'] = (host / 'supervisor.py').read_bytes()
    need(files[PREFIX + 'supervisor.py'] == original['supervisor.py'].replace(
        b'v0.9.0-rc13-yc-beta2', VERSION.encode()), 'Supervisor changed beyond release label')
    for name, data in files.items():
        relative = name[len(PREFIX):]
        if relative in old['automatic_movie_files'] and (relative.startswith('fmv/') or relative.endswith(('.py', '.sh'))):
            need((host / relative).read_bytes() == data, 'Packaged runtime differs from source: ' + relative)
    files['Scripts/NDS4MiSTer.sh'] = (host / 'NDS4MiSTer.sh').read_bytes()
    need(files['Scripts/NDS4MiSTer.sh'].splitlines()[2:] == beta[BETA_LAUNCHER].replace(
        BETA_PREFIX.encode(), PREFIX.encode()).splitlines()[2:], 'Release launcher behavior differs')
    modes['Scripts/NDS4MiSTer.sh'] = modes[PREFIX + 'nds_standalone_host'] = 0o755
    for name, source in DOCS.items():
        files[name] = (ROOT / source).read_bytes()
    source_name = 'NDS4MiSTer_' + VERSION + '_Sources.zip'
    m = dict(old)
    m.update(name='NDS4MiSTer', version=VERSION, menu_version='v0.9.0-rc14',
             release_channel='release candidate', package_revision=1,
             remote_kit='/media/fat/Scripts/.NDS_Standalone', source_revision=revision,
             host_source_revision=revision, supervisor_source_revision=revision,
             host_sha256=sha(files[PREFIX + 'nds_standalone_host']),
             supervisor_sha256=sha(files[PREFIX + 'supervisor.py']),
             launcher_sha256=sha(files['Scripts/NDS4MiSTer.sh']),
             source_download=source_name, release_preparation_authorized=True,
             publication_authorized=False, published=False,
             validation_scope='Accepted Beta 5 components plus release-specific offline validation; final release ZIP not relaunched on hardware',
             automatic_movie_files={n: sha(files[PREFIX + n]) for n in old['automatic_movie_files']})
    m.pop('private_test_ready', None)
    files[PREFIX + 'manifest.json'] = js(m)
    files[PREFIX + 'SHA256SUMS'] = checksums({n[len(PREFIX):]: b for n, b in files.items() if n.startswith(PREFIX)})
    files['SHA256SUMS'] = checksums(files)
    validation = audit(files)

    # The normal install ZIP stays small. Complete matching component sources,
    # frozen FPGA inputs, renderer profiles and third-party source are separate.
    yc, _ = common.read_zip(yc_path)
    source = {'NDS4MiSTer-rc14-source.tar.gz': common.git('archive', '--format=tar.gz', 'HEAD')}
    for name in ['dv1-yc-fpga-inputs.tar.gz', 'Regional_Renderer_source.tar.gz',
                 'Regional_Renderer_inputs.json', 'Regional_Renderer_build.json',
                 'Regional_Renderer_BUILD.sh', 'ffmpeg-7.1.1.tar.xz', 'portrait-combo3-pgo.tar.gz']:
        source['components/' + name] = yc[YC_PREFIX + 'source/' + name]
    fpga = json.loads(yc[YC_PREFIX + 'fpga-source-manifest.json'])
    source['components/FPGA_INPUTS.json'] = js(dict(source_revision=fpga['source_revision'], all_build_inputs=fpga['frozen_input_sha256']))
    source['components/FPGA_BUILD.json'] = yc[YC_PREFIX + 'source/dv1-yc-build.json']
    fpga_count = inventory(source['components/dv1-yc-fpga-inputs.tar.gz'], fpga['frozen_input_sha256'])
    renderer_count = inventory(source['components/Regional_Renderer_source.tar.gz'],
                               json.loads(source['components/Regional_Renderer_inputs.json'])['files'])
    source['BUILD.md'] = (ROOT / 'docs/release/BUILD_RC14.md').read_bytes()
    source['LICENSE.txt'] = (ROOT / 'LICENSE.txt').read_bytes()
    provenance = dict(version=VERSION, source_revision=revision, accepted_beta_sha256=BETA_SHA,
                      host_build=build, fpga_sha256=PINS['NDS_Standalone.rbf'],
                      renderer_sha256=PINS['support/nds_hybrid_3d_service'],
                      guest_catalog_sha256=PINS['fmv/guest_catalog.json'],
                      frozen_fpga_files_verified=fpga_count, frozen_renderer_files_verified=renderer_count,
                      static_timing_closed=False, published=False)
    source['BUILD_PROVENANCE.json'] = js(provenance)
    for name, data in source.items():
        common.content_audit(name, data)
    source['SHA256SUMS'] = checksums(source)
    out.mkdir(parents=True, exist_ok=True)
    runtime_path = out / ('NDS4MiSTer_' + VERSION + '_Standalone.zip')
    source_path = out / source_name
    write_zip(runtime_path, files, modes)
    write_zip(source_path, source)
    optional_profile = out / PROFILE_NAME
    need(not optional_profile.exists(), 'Profile output already exists')
    shutil.copyfile(profile_path, optional_profile)
    optional_profile.with_suffix('.zip.sha256').write_text(PROFILE_SHA + '  ' + PROFILE_NAME + '\n')
    reloaded, _ = common.read_zip(runtime_path)
    audit(reloaded)
    validation.update(archive=runtime_path.name, sha256=sha(runtime_path.read_bytes()),
                      bytes=runtime_path.stat().st_size, source_revision=revision,
                      source_archive=source_path.name, source_archive_sha256=sha(source_path.read_bytes()),
                      source_archive_bytes=source_path.stat().st_size, provenance=provenance)
    (out / 'RC14_PACKAGE_VALIDATION.json').write_bytes(js(validation))
    for name in DOCS:
        (out / name).write_bytes(files[name])
    (out / 'BUILD_PROVENANCE.json').write_bytes(js(provenance))
    assets = [dict(name=p.name, bytes=p.stat().st_size, sha256=sha(p.read_bytes()), role=role)
              for p, role in [(runtime_path, 'runtime'), (source_path, 'corresponding source'),
                              (optional_profile, 'optional RetroTINK-4K profiles courtesy of Mr. Moro')]]
    (out / 'RELEASE_ASSETS.json').write_bytes(js(dict(version=VERSION, published=False, assets=assets)))
    return validation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--beta-zip', type=Path)
    parser.add_argument('--yc-zip', type=Path)
    parser.add_argument('--profile-zip', type=Path)
    parser.add_argument('--out-dir', type=Path)
    parser.add_argument('--audit', type=Path)
    args = parser.parse_args()
    if args.audit:
        files, _ = common.read_zip(args.audit)
        result = audit(files)
    else:
        need(args.beta_zip and args.yc_zip and args.profile_zip and args.out_dir,
             'Provide both parent ZIPs, contributed profile ZIP, and output directory')
        result = assemble(args.beta_zip, args.yc_zip, args.profile_zip, args.out_dir)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
