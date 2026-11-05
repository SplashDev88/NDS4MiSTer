#!/usr/bin/env python3
"""Package a private renderer or guarded guest beta beside an existing installation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def package_guest_beta(args, definition):
    """Keep the frozen runtime and add guarded guest-loader source/manifest files."""
    root = Path(__file__).resolve().parents[2]
    assert sha(args.base_zip.read_bytes()) == definition['base_zip_sha256']
    assert args.out.is_dir() and not any(args.out.iterdir())
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=root), 'Commit the reviewed source first'
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    kit, launcher_name = definition['kit'], definition['launcher']
    assert kit.startswith('.NDS_') and '/' not in kit and '/' not in launcher_name and launcher_name.endswith('.sh')
    old, new = 'Scripts/.NDS_Standalone/', 'Scripts/' + kit + '/'
    files, modes = {}, {}
    with zipfile.ZipFile(args.base_zip) as archive:
        for item in archive.infolist():
            assert not Path(item.filename).is_absolute() and '..' not in Path(item.filename).parts
            if item.is_dir() or not item.filename.startswith(old):
                continue
            name = new + item.filename[len(old):]
            files[name] = archive.read(item)
            modes[name] = (item.external_attr >> 16) & 0o777 or 0o644
    manifest = json.loads(files[new + 'manifest.json'])
    for name, expected in definition['frozen_runtime_sha256'].items():
        assert sha(files[new + name]) == expected, name
    for target, source in definition['files'].items():
        assert not Path(target).is_absolute() and '..' not in Path(target).parts
        assert not Path(source).is_absolute() and '..' not in Path(source).parts
        assert target not in definition['frozen_runtime_sha256'] and target != 'manifest.json'
        files[new + target] = (root / source).read_bytes()
    entry = definition['guest_entry']
    guest = json.loads((root / entry['manifest']).read_text())
    assert guest['delivery'] == 'append-decoded-arm9-gx-spans-v1'
    assert set(entry['patch_ids']) == {p['id'] for p in guest['patches']}
    catalog = json.loads(files[new + 'fmv/guest_catalog.json'])
    identity = lambda m: (m['game_code'], m['revision'], m['header_sha1'])
    assert all(identity(e['manifest']) != identity(guest) for e in catalog['entries'])
    catalog['entries'].append(dict(manifest=guest, patch_ids=entry['patch_ids']))
    assert len(catalog['entries']) <= 32
    files[new + 'fmv/guest_catalog.json'] = (json.dumps(catalog, indent=2) + '\n').encode()
    launcher = 'Scripts/' + launcher_name
    asset_cache = definition.get('asset_preparation_cache', False)
    assert type(asset_cache) is bool
    if asset_cache:
        assert 'fmv/gx_span_cache.py' in definition['files']
    files[launcher] = ('#!/bin/sh\n# ' + definition['name'] + '\n'
        'export NDS_GUEST_PATCH_MANIFEST=/media/fat/' + new + 'fmv/guest_catalog.json\n'
        'export NDS_GUEST_PATCH_SHA256=' + sha(files[new + 'fmv/guest_catalog.json']) + '\n'
        'export NDS_GUEST_PATCH_IDS=@catalog\nexport NDS_GUEST_PATCH_FALLBACK_FMV=1\n'
        + ('export NDS_GX_ASSET_CACHE=1\n' if asset_cache else '') +
        'exec python3 /media/fat/' + new + 'auto_movies.py "$@"\n').encode()
    modes[launcher] = 0o755
    files[new + 'source/private-guest-source.tar.gz'] = subprocess.check_output(
        ['git', 'archive', '--format=tar.gz', revision], cwd=root)
    files[new + 'PRIVATE_BETA.txt'] = definition['instructions'].encode()
    pins = manifest['automatic_movie_files']
    for name, data in files.items():
        if name.startswith(new) and name != new + 'manifest.json' and name != new + 'SHA256SUMS':
            relative = name[len(new):]
            if relative in pins or relative in definition['files'] or relative in (
                    'source/private-guest-source.tar.gz', 'PRIVATE_BETA.txt'):
                pins[relative] = sha(data)
    manifest.update(name=definition['name'], version=definition['version'],
        release_channel='private experimental beta', private_test_ready=True,
        public_release_qualified=False, source_revision=revision, package_revision=definition['version'],
        remote_kit='/media/fat/' + new.rstrip('/'), launcher_sha256=sha(files[launcher]),
        base_zip_sha256=definition['base_zip_sha256'], guest_validation=definition['validation'],
        asset_preparation_cache=asset_cache,
        installation_scope='Separate launcher/support directory; saves are shared when loading the original game path.',
        guest_source_archive='source/private-guest-source.tar.gz', guest_source_revision=revision)
    files[new + 'manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    files[new + 'SHA256SUMS'] = ''.join(pins[n] + '  ' + n + '\n' for n in sorted(pins)).encode()
    for name in files:
        assert not name.lower().endswith(('.nds', '.sav', '.dsv', '.ini', '.srm'))
        if name.lower().endswith('.cfg'):
            assert name == new + 'NDS_speed.cfg', name
    output = args.out / definition['archive']
    with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2026, 11, 4, 0, 0, 0))
            item.external_attr = (0o100000 | modes.get(name, 0o644)) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        for name, expected in definition['frozen_runtime_sha256'].items():
            assert sha(archive.read(new + name)) == expected
        for name, expected in pins.items():
            assert sha(archive.read(new + name)) == expected, name
    digest = sha(output.read_bytes())
    output.with_suffix(output.suffix + '.sha256').write_text(digest + '  ' + output.name + '\n')
    receipt = dict(archive=output.name, sha256=digest, bytes=output.stat().st_size,
        source_revision=revision, files=len(files), personal_data_included=False,
        isolated_launcher=launcher, runtime_binaries_unchanged=True)
    (args.out / 'PACKAGE_VALIDATION.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['base-zip', 'definition', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    for name in ['helper', 'build-record', 'training-profiles']:
        parser.add_argument('--' + name, type=Path)
    args = parser.parse_args()
    definition = json.loads(args.definition.read_text())
    if definition.get('mode') == 'guarded-guest':
        package_guest_beta(args, definition)
        return
    assert args.helper and args.build_record and args.training_profiles
    assert sha(args.base_zip.read_bytes()) == definition['base_zip_sha256']
    assert args.out.is_dir() and not any(args.out.iterdir()), 'Use an empty output directory'
    root = Path(__file__).resolve().parents[2]
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    assert not subprocess.check_output(['git', 'diff', '--', 'src', 'third_party'], cwd=root)
    helper = args.helper.read_bytes()
    build = json.loads(args.build_record.read_text())
    assert build['sha256'] == sha(helper) and not build['diagnostic']
    old = 'Scripts/.NDS_Standalone/'
    new = 'Scripts/' + definition['kit'] + '/'
    assert definition['kit'].startswith('.NDS_') and '/' not in definition['kit']
    assert '/' not in definition['launcher'] and definition['launcher'].endswith('.sh')
    files = {}
    modes = {}
    with zipfile.ZipFile(args.base_zip) as archive:
        for item in archive.infolist():
            assert not Path(item.filename).is_absolute() and '..' not in Path(item.filename).parts
            if item.is_dir() or not item.filename.startswith(old):
                continue
            name = new + item.filename[len(old):]
            files[name] = archive.read(item)
            modes[name] = (item.external_attr >> 16) & 0o777 or 0o644
    manifest = json.loads(files[new + 'manifest.json'])
    previous_helper = manifest['helper_sha256']
    files[new + 'support/nds_hybrid_3d_service'] = helper
    files[new + 'support/nds_hybrid_3d_service.sha256'] = (sha(helper) + '  nds_hybrid_3d_service\n').encode()
    supervisor = files[new + 'supervisor.py'].decode()
    assert previous_helper in supervisor
    supervisor = supervisor.replace(previous_helper, sha(helper))
    anchor = '        stage("start verified helper")'
    assert supervisor.count(anchor) == 1
    supervisor = supervisor.replace(anchor, '''        texture_choice = os.environ.get("NDS4MISTER_TEXTURE_HISTORY", "1")
        assert texture_choice in ("0", "1"), "Invalid texture-history choice"
        env["NDS4MISTER_TEXTURE_HISTORY"] = texture_choice
        if os.environ.get("NDS4MISTER_RENDER_CACHE_STATS") == "1":
            env["NDS4MISTER_RENDER_CACHE_STATS"] = "1"
''' + anchor)
    anchor = '        state["renderer_environment"] = actual_env'
    assert supervisor.count(anchor) == 1
    supervisor = supervisor.replace(anchor, '        assert actual_env.get("NDS4MISTER_TEXTURE_HISTORY") == texture_choice\n' + anchor)
    files[new + 'supervisor.py'] = supervisor.encode()
    launcher = 'Scripts/' + definition['launcher']
    files[launcher] = ('#!/bin/sh\n# ' + definition['name'] + '\nexec python3 /media/fat/' + new + 'auto_movies.py "$@"\n').encode()
    modes[launcher] = 0o755
    files[new + 'source/private-renderer-source.tar.gz'] = subprocess.check_output(
        ['git', 'archive', '--format=tar.gz', revision], cwd=root)
    build['binary'] = 'support/nds_hybrid_3d_service'
    build['packaged_source_revision'] = revision
    files[new + 'source/private-renderer-build.json'] = (json.dumps(build, indent=2) + '\n').encode()
    files[new + 'source/private-native-training.tar'] = args.training_profiles.read_bytes()
    files[new + 'source/BUILD_PRIVATE_RENDERER.md'] = definition['build_instructions'].encode()
    files[new + 'PRIVATE_BETA.txt'] = definition['instructions'].encode()
    for target, source in definition['documents'].items():
        assert not Path(target).is_absolute() and '..' not in Path(target).parts
        assert not Path(source).is_absolute() and '..' not in Path(source).parts
        files[new + target] = (root / source).read_bytes()
    manifest.update(
        name=definition['name'], version=definition['version'], release_channel='private experimental beta',
        remote_kit='/media/fat/' + new.rstrip('/'), private_test_ready=True,
        public_release_qualified=False, helper_sha256=sha(helper),
        helper_source_revision=revision, source_revision=revision,
        supervisor_sha256=sha(files[new + 'supervisor.py']),
        launcher_sha256=sha(files[launcher]), base_zip_sha256=definition['base_zip_sha256'],
        experimental_features=definition['features'], hardware_validation=definition['validation'],
        runtime_source_archive='source/private-renderer-source.tar.gz',
        source_archive_sha256=sha(files[new + 'source/private-renderer-source.tar.gz']),
        runtime_source_revision=revision, packaging_source_revision=revision,
        source_commit=revision, package_revision=definition['version'],
        renderer_build=build, public_release_scope='Not a public release; private Castlevania test build',
        installation_scope='Separate launcher and support folder; existing saves are shared',
        user_settings_included=False, static_timing_clean=False)
    pins = manifest['automatic_movie_files']
    for relative in pins:
        pins[relative] = sha(files[new + relative])
    for relative in ['source/private-renderer-source.tar.gz', 'source/private-renderer-build.json',
                     'source/private-native-training.tar', 'source/BUILD_PRIVATE_RENDERER.md', 'PRIVATE_BETA.txt']:
        pins[relative] = sha(files[new + relative])
    for relative in definition['documents']:
        pins[relative] = sha(files[new + relative])
    files[new + 'manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    files[new + 'SHA256SUMS'] = ''.join(pins[name] + '  ' + name + '\n' for name in sorted(pins)).encode()
    for name in files:
        assert not name.lower().endswith(('.nds', '.sav', '.dsv', '.ini', '.srm'))
        if name.lower().endswith('.cfg'):
            assert name == new + 'NDS_speed.cfg', name
        assert '/inputs/' not in name
    output = args.out / definition['archive']
    with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2026, 10, 25, 0, 0, 0))
            item.external_attr = (0o100000 | modes.get(name, 0o644)) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
    digest = sha(output.read_bytes())
    output.with_suffix(output.suffix + '.sha256').write_text(digest + '  ' + output.name + '\n')
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert archive.read(new + 'support/nds_hybrid_3d_service') == helper
    receipt = dict(archive=output.name, sha256=digest, bytes=output.stat().st_size,
                   source_revision=revision, helper_sha256=sha(helper), files=len(files),
                   personal_data_included=False, isolated_launcher=launcher)
    (args.out / 'PACKAGE_VALIDATION.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
