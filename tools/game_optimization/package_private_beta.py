#!/usr/bin/env python3
"""Package a private renderer beta beside an existing standalone installation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['base-zip', 'helper', 'build-record', 'training-profiles', 'definition', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    definition = json.loads(args.definition.read_text())
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
