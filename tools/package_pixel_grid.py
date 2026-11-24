#!/usr/bin/env python3
"""Package an isolated v1.0.3 Pixel Grid test without altering the release kit."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE_REV = '6eadde791669feef6cdbbcfb1be36403519ab23c'
BASE_SHA = '52fddd009ca0dc7509eb56ec0f2241c3e9472901824aa3ee42d97128579264b9'
OLD = 'Scripts/.NDS/'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def js(data):
    return (json.dumps(data, indent=2) + '\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--test-number', type=int, default=1)
    parser.add_argument('--hardware-evidence', type=Path)
    args = parser.parse_args()
    assert args.test_number > 0
    assert not args.out.exists(), 'Choose a new output directory'
    assert sha(args.baseline.read_bytes()) == BASE_SHA, 'Wrong v1.0.3 baseline archive'
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT).strip(), 'Commit source first'
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    # Collect fresh evidence. Static timing is diagnostic and may still be
    # running; map, fit and assembly must have succeeded for this exact RTL.
    subprocess.run(['python3', str(ROOT / 'tools/fpga3d/collect_pixel_grid_build.py')], check=True)
    build = ROOT / 'build-pixel-grid'
    validation = json.loads((build / 'VALIDATION.json').read_text())
    inputs = json.loads((build / 'BUILD_INPUTS.json').read_text())
    core = (ROOT / 'build-fpga3d/rc15-command-output/NDS4MiSTer.rbf').read_bytes()
    host = (ROOT / 'tools/standalone_host/nds_standalone_host').read_bytes()
    assert sha(core) == validation['core_sha256']
    assert sha(host) == validation['arm_host_sha256']
    hardware = None
    if args.hardware_evidence:
        hardware = json.loads(args.hardware_evidence.read_text())
        assert hardware['status'] == 'passed'
        assert hardware['core_sha256'] == sha(core) and hardware['host_sha256'] == sha(host)
        assert hardware['fpga_source_revision'] == inputs['source_revision']
        assert hardware['protected_files_unchanged'] is True
        games = hardware['games']
        assert len({g['game'] for g in games if g['startup'] and g['gameplay']}) >= 2
        assert any(set(g['grid_strengths']) == {'Off', 'Light', 'Medium', 'Strong'} for g in games)
        assert hardware['screenshot_files'], 'Commercial-game screenshots required'
    qualified = hardware is not None
    prefix = f'Scripts/.NDS_PixelGrid_v103_Test{args.test_number}/'
    launcher = f'Scripts/NDS_PixelGrid_v103_Test{args.test_number}.sh'
    with zipfile.ZipFile(args.baseline) as archive:
        original, modes = {}, {}
        for item in archive.infolist():
            assert not Path(item.filename).is_absolute() and '..' not in Path(item.filename).parts
            if not item.is_dir():
                original[item.filename] = archive.read(item)
                modes[item.filename] = (item.external_attr >> 16) & 0o777 or 0o644
    base = json.loads(original[OLD + 'manifest.json'])
    assert base['version'] == 'v1.0.3'
    files = {prefix + n[len(OLD):]: data for n, data in original.items()
             if n.startswith(OLD) and n != OLD + 'SHA256SUMS'}
    permissions = {prefix + n[len(OLD):]: mode for n, mode in modes.items() if n.startswith(OLD)}
    files[prefix + 'NDS_Standalone.rbf'] = core
    files[prefix + 'nds_standalone_host'] = host
    if prefix + 'nds_standalone_host.sha256' in files:
        files[prefix + 'nds_standalone_host.sha256'] = (sha(host) + '  nds_standalone_host\n').encode()
    files[prefix + 'install_layout.py'] = (ROOT / 'tools/standalone_host/install_layout.py').read_bytes()
    supervisor = files[prefix + 'supervisor.py']
    old_pin = ('EXPECTED_CORE = "' + base['core_sha256'] + '"').encode()
    assert supervisor.count(old_pin) == 1
    files[prefix + 'supervisor.py'] = supervisor.replace(old_pin, ('EXPECTED_CORE = "' + sha(core) + '"').encode())
    files[launcher] = original['Scripts/NDS.sh'].replace(OLD.encode(), prefix.encode())
    permissions[launcher] = 0o755
    manifest = dict(base)
    manifest.update(version=f'v1.0.3-pixel-grid.{args.test_number}',
                    name=f'NDS4MiSTer v1.0.3 Pixel Grid Test {args.test_number}',
                    release_channel='private pixel-grid test',
                    remote_kit='/media/fat/' + prefix.rstrip('/'), private_test_ready=True,
                    installation_scope='Separate launcher and preferences; interactive launches use normal game saves',
                    source_revision=revision, packaging_source_revision=revision,
                    host_source_revision=validation.get('host_source_revision', inputs['source_revision']),
                    fpga_source_revision=inputs['source_revision'], core_source_revision=inputs['source_revision'],
                    runtime_source_revision=revision, tested_runtime_source_revision=None,
                    supervisor_source_revision=base['supervisor_source_revision'],
                    supervisor_provenance='Exact v1.0.3 supervisor with only EXPECTED_CORE regenerated by package_pixel_grid.py',
                    core_sha256=sha(core), host_sha256=sha(host),
                    supervisor_sha256=sha(files[prefix + 'supervisor.py']), launcher_sha256=sha(files[launcher]),
                    baseline_archive_sha256=BASE_SHA, baseline_source_revision=BASE_REV,
                    base_zip_sha256=BASE_SHA, base_source_revision=BASE_REV, base_version='v1.0.3',
                    packager_sha256=sha(Path(__file__).read_bytes()),
                    source_reconstruction='Apply PIXEL_GRID_SOURCE_PATCH.diff to the v1.0.3 tag; see SOURCE.md.',
                    hardware_qualified=qualified, public_release_qualified=False, published=False,
                    validation_scope=('Private hardware beta; see PIXEL_GRID_HARDWARE.json for exact coverage' if qualified else 'Offline tests and FPGA build only; fresh hardware qualification pending'),
                    acceptance_criterion='Actual game startup, gameplay and grid behavior; static timing diagnostic',
                    pixel_grid={'values': ['Off', 'Light', 'Medium', 'Strong'], 'default': 'Off',
                                'modes': ['1280x720', '1920x1080'], 'pipeline_cycles': 4,
                                'dsp_blocks': validation['fit']['grid_dsp_blocks']})
    manifest['automatic_movie_files'] = {n: sha(files[prefix + n]) for n in base['automatic_movie_files']}
    files[prefix + 'manifest.json'] = js(manifest)
    files[prefix + 'SHA256SUMS'] = ''.join(h + '  ' + n + '\n' for n, h in sorted(manifest['automatic_movie_files'].items())).encode()
    files['BASELINE_MANIFEST.json'] = original[OLD + 'manifest.json']
    files['PIXEL_GRID_VALIDATION.json'] = js(validation)
    if hardware:
        files['PIXEL_GRID_HARDWARE.json'] = js(hardware)
    files['PIXEL_GRID_BUILD_INPUTS.json'] = js(inputs)
    files['PIXEL_GRID_SOURCE_PATCH.diff'] = subprocess.check_output(['git', 'diff', '--binary', BASE_REV, revision], cwd=ROOT)
    files['PIXEL_GRID_V103.md'] = (ROOT / 'docs/PIXEL_GRID_V103.md').read_bytes()
    for name in original:
        if '/' not in name and name.lower().startswith('license'):
            files[name] = original[name]
    files['SOURCE.md'] = (f'Base source: https://github.com/SplashDev88/NDS4MiSTer/tree/{BASE_REV}\n'
                          'Apply PIXEL_GRID_SOURCE_PATCH.diff to that source.\n'
                          f'Experiment source: {revision}\n'
                          f'FPGA source: {inputs["source_revision"]}\n'
                          'The package regenerates only the supervisor core pin; the renderer and guest catalog come from the exact v1.0.3 archive.\n').encode()
    files['README_PIXEL_GRID.txt'] = (f'''NDS4MiSTer v1.0.3 Pixel Grid Test {args.test_number}

{'Private beta tested on commercial games; see PIXEL_GRID_HARDWARE.json.' if qualified else 'Private hardware-test candidate; gameplay has not yet been qualified.'}
Extract to the SD root, including hidden files. Run {launcher}.
The normal NDS launcher and preferences remain separate.

Display options > Pixel Grid: Off / Light / Medium / Strong. Default Off.
System > Save settings persists the choice; Reset restores Off.
Use standard scaled HDMI at 720p or 1080p (direct_video=0). Direct Video,
1440p, noninteger scaling and 1x bypass the grid. At 720p, an unrotated
Top/Bottom layout can be 1x; choose a larger layout to see the grid.
At 1080p, Side by Side gives 3x; Top/Bottom with 90-degree rotation gives 4x.
Main Only/Touch Only may use a 320x240 canvas and bypass at noninteger scales.
Menu text is drawn afterward. Disable an external scaler's own grid during
comparison. The implementation preserves the approved LCD Grid 2 approximation.

Normal interactive launches use normal game saves. Automated qualification
must use isolated game/save copies. See PIXEL_GRID_VALIDATION.json for the
exact build and test coverage. Static timing results are diagnostic.
''').encode()
    # Preserve baseline renderer and every guest patch byte-for-byte.
    for name, data in original.items():
        if name.startswith(OLD + 'fmv/') or name == OLD + 'support/nds_hybrid_3d_service':
            assert files[prefix + name[len(OLD):]] == data
    assert all(not n.startswith(OLD) and n != 'Scripts/NDS.sh' for n in files)
    args.out.mkdir(parents=True)
    output = args.out / f'NDS4MiSTer_v1.0.3_PixelGrid_Test{args.test_number}.zip'
    with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (2026, 11, 23, 0, 0, 0))
            item.external_attr = (0o100000 | permissions.get(name, 0o644)) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        for name, digest in manifest['automatic_movie_files'].items():
            assert sha(archive.read(prefix + name)) == digest
    receipt = dict(archive=str(output), sha256=sha(output.read_bytes()), files=len(files),
                   core_sha256=sha(core), host_sha256=sha(host), hardware_qualified=qualified,
                   source_revision=revision, isolated_launcher=launcher)
    (args.out / 'PACKAGE_VALIDATION.json').write_bytes(js(receipt))
    (args.out / 'SHA256SUMS').write_text(receipt['sha256'] + '  ' + output.name + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
