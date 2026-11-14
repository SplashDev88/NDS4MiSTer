#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package the permanent NDS installation from a verified release ZIP.

Preserve frozen core/renderer/support payloads; replace only reviewed frontend
and launcher sources. No network, hardware, publishing or custom source ZIP.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'tools/standalone_host'
PREFIX = 'Scripts/.NDS/'
LAUNCHER = 'Scripts/NDS.sh'
BASE_SHA256 = 'e5c4dd08a0c6fdcc0c0816e6635ad95bf9d08761784b1c2cfdff676add1c962f'
RETROTINK_SHA256 = 'ea1ca681eceffae91a1702aaa6e3e53319ce9a82b9aa5d532e00bf731ed6b3ad'
SOURCE_OVERLAY = ('supervisor.py', 'auto_movies.py', 'install_layout.py', 'defaults/NDS_speed.cfg')


def sha(data): return hashlib.sha256(data).hexdigest()
def js(value): return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
def require(ok, why):
    if not ok: raise ValueError(why)
def checksums(files): return ''.join(sha(b) + '  ' + n + '\n' for n, b in sorted(files.items())).encode()


def read_zip(path):
    files, modes = {}, {}
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, 'Archive CRC failure')
        for info in archive.infolist():
            if info.is_dir(): continue
            n = info.filename
            require(n not in files and not n.startswith('/') and '\\' not in n and ':' not in n and
                    all(p not in ('', '.', '..') for p in n.split('/')), 'Unsafe/duplicate member: ' + n)
            require(stat.S_IFMT(info.external_attr >> 16) in (0, stat.S_IFREG), 'Nonregular member: ' + n)
            files[n] = archive.read(info)
            modes[n] = stat.S_IMODE(info.external_attr >> 16)
    return files, modes


def audit(files, modes):
    require([n for n in files if n.startswith('Scripts/') and n.count('/') == 1] == [LAUNCHER], 'Exactly one public launcher required')
    require(all(not n.startswith('Scripts/') or n == LAUNCHER or n.startswith(PREFIX) for n in files), 'Versioned runtime folder')
    for n, data in files.items():
        rel = n[len(PREFIX):] if n.startswith(PREFIX) else n
        require(not rel.startswith(('inputs/', 'legacy-launchers/')) and rel != 'install-migration.json', 'User state bundled: ' + n)
        require(PurePosixPath(n).suffix.lower() not in {'.nds', '.sav', '.dsv', '.ini', '.map'}, 'User data bundled: ' + n)
        require(not n.lower().endswith('.cfg') or n == PREFIX + 'defaults/NDS_speed.cfg', 'Saved preference bundled: ' + n)
        if n.endswith('.py'): ast.parse(data, filename=n)
        if n.endswith(('.py', '.sh', '.json', '.md', '.txt')):
            require(not re.search(rb'/'+rb'Users/[^/]+/', data), 'Private source path: ' + n)
    manifest = json.loads(files[PREFIX + 'manifest.json'])
    require(manifest['remote_kit'] == '/media/fat/Scripts/.NDS', 'Wrong permanent settings path')
    require(manifest['launcher_sha256'] == sha(files[LAUNCHER]), 'Launcher checksum mismatch')
    for name, key in [('nds_standalone_host', 'host_sha256'), ('supervisor.py', 'supervisor_sha256'),
                      ('NDS_Standalone.rbf', 'core_sha256'), ('support/nds_hybrid_3d_service', 'helper_sha256')]:
        require(sha(files[PREFIX + name]) == manifest[key], 'Component checksum mismatch: ' + name)
    for name, digest in manifest['automatic_movie_files'].items():
        require(sha(files[PREFIX + name]) == digest, 'Runtime checksum mismatch: ' + name)
        require(not name.lower().endswith('.cfg') or name == 'defaults/NDS_speed.cfg', 'Pinned user preference')
    require(files[PREFIX + 'SHA256SUMS'] == checksums({n[len(PREFIX):]: b for n, b in files.items() if n.startswith(PREFIX) and n != PREFIX + 'SHA256SUMS'}), 'Kit checksum inventory mismatch')
    require(files['SHA256SUMS'] == checksums({n: b for n, b in files.items() if n != 'SHA256SUMS'}), 'Root checksum inventory mismatch')
    for n in [LAUNCHER, PREFIX + 'nds_standalone_host', PREFIX + 'support/nds_hybrid_3d_service', PREFIX + 'Kickstart.sh']:
        require(modes[n] & 0o111, 'Missing execute mode: ' + n)
    return dict(passed=True, files=len(files), source_revision=manifest['source_revision'],
                version=manifest['version'], package_revision=manifest['package_revision'],
                launcher=LAUNCHER, runtime_directory=PREFIX, saved_preferences_bundled=False,
                custom_source_zip_created=False, runtime_pins={k:manifest[k] for k in
                ['host_sha256', 'core_sha256', 'helper_sha256', 'supervisor_sha256']})


def collect(args):
    require(sha(args.base_runtime.read_bytes()) == args.base_sha256, 'Base runtime SHA256 differs')
    original, old_modes = read_zip(args.base_runtime)
    manifests = [n for n in original if re.fullmatch(r'Scripts/\.[^/]+/manifest\.json', n)]
    require(len(manifests) == 1, 'Expected one runtime manifest')
    old_prefix = manifests[0][:-len('manifest.json')]
    base = json.loads(original[manifests[0]])
    revision = args.source_revision or subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    require(re.fullmatch('[0-9a-f]{40}', revision), 'Full source revision required')
    files, modes = {}, {}
    for n, data in original.items():
        if n.startswith(old_prefix):
            relative = n[len(old_prefix):]
            if relative in {'manifest.json', 'SHA256SUMS'} or relative.lower().endswith('.cfg') or relative.startswith(('inputs/', 'legacy-launchers/')) or relative == 'install-migration.json':
                continue
            target = PREFIX + relative
        elif n.startswith('Scripts/') or n == 'SHA256SUMS': continue
        else: target = n
        files[target] = data; modes[target] = old_modes[n]
    unchanged = dict(files)
    files[LAUNCHER] = (HOST / 'NDS.sh').read_bytes(); modes[LAUNCHER] = 0o755
    files[PREFIX + 'nds_standalone_host'] = args.host.read_bytes()
    require(files[PREFIX + 'nds_standalone_host'][:4] == b'\x7fELF' and files[PREFIX + 'nds_standalone_host'][18:20] == b'\x28\x00', 'Expected an ARM host ELF')
    menu_version = (HOST / 'VERSION').read_text().strip()
    require(('NDS4MiSTer ' + menu_version + '\0').encode() in files[PREFIX + 'nds_standalone_host'], 'Core menu version missing')
    for relative in SOURCE_OVERLAY:
        files[PREFIX + relative] = (HOST / relative).read_bytes()
        modes[PREFIX + relative] = 0o644
    allowed = {PREFIX + n for n in SOURCE_OVERLAY} | {PREFIX + 'nds_standalone_host'}
    for n, data in unchanged.items():
        if n.startswith(PREFIX) and n not in allowed:
            require(files[n] == data, 'Unplanned runtime change: ' + n)
    manifest = dict(base)
    manifest.update(name='NDS4MiSTer 1.0', version=menu_version, release_channel='test candidate',
                    source_revision=revision, runtime_source_revision=revision,
                    host_source_revision=revision, packaging_source_revision=revision,
                    supervisor_source_revision=revision, package_revision=1,
                    remote_kit='/media/fat/Scripts/.NDS', menu_version=menu_version,
                    installation_scope='Permanent Scripts/NDS.sh and Scripts/.NDS; standard saves/NDS',
                    source_download='https://github.com/SplashDev88/NDS4MiSTer/archive/' + revision + '.zip',
                    user_settings_included=False, settings_migration='Automatic once from RC15, then RC14; existing .NDS files win',
                    release_defaults='defaults/NDS_speed.cfg; user preferences override it',
                    supervisor_provenance='Stable installation settings migration after package and owner validation.')
    manifest['graphics_defaults'] = dict(anti_aliasing='Off', resolution='Native 256x192')
    for relative, key in [('nds_standalone_host', 'host_sha256'), ('supervisor.py', 'supervisor_sha256')]:
        manifest[key] = sha(files[PREFIX + relative])
    manifest['launcher_sha256'] = sha(files[LAUNCHER])
    required = set(base['automatic_movie_files']) | set(SOURCE_OVERLAY)
    manifest['automatic_movie_files'] = {n:sha(files[PREFIX+n]) for n in sorted(required) if PREFIX+n in files}
    files[PREFIX + 'manifest.json'] = js(manifest)
    files[PREFIX + 'SHA256SUMS'] = checksums({n[len(PREFIX):]: b for n, b in files.items() if n.startswith(PREFIX)})
    for name, source in [('README.md', 'README.md'), ('QUICK_START.txt', 'docs/STANDALONE_QUICK_START.txt'),
                         ('RELEASE_NOTES.md', 'docs/RELEASE_NOTES_V10.md'), ('GAME_CLOCK.md', 'docs/GAME_CLOCK.md')]:
        files[name] = (ROOT / source).read_bytes()
    if 'VALIDATION.md' in files:
        files['VALIDATION.md'] += b'\nStable installation update: core and renderer bytes are unchanged. The host now reads an immutable speed default when no user preference exists. Launcher migration and settings preservation are covered by offline tests; no hardware upgrade trial is implied.\n'
    files['SHA256SUMS'] = checksums(files)
    report = audit(files, modes)
    report.update(base_runtime_sha256=args.base_sha256, unchanged_core_and_renderer=True,
                  menu_version=menu_version, published=False)
    return files, modes, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-runtime', type=Path, required=True)
    parser.add_argument('--base-sha256', default=BASE_SHA256)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path)
    parser.add_argument('--source-revision')
    parser.add_argument('--retrotink', type=Path)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    files, modes, report = collect(args)
    if not args.check_only:
        require(args.out_dir is not None, '--out-dir required')
        require(not subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']), 'Commit source before packaging')
        args.out_dir.mkdir(parents=True, exist_ok=True)
        archive = args.out_dir / ('NDS4MiSTer_' + report['version'] + '_Standalone.zip')
        require(not archive.exists(), 'Preserve previous archive')
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, (2026, 11, 14, 0, 0, 0)); info.create_system = 3
                info.external_attr = (stat.S_IFREG | modes.get(name, 0o644)) << 16
                info.compress_type = zipfile.ZIP_DEFLATED; z.writestr(info, data)
        reread, actual_modes = read_zip(archive)
        require(reread == files, 'ZIP readback differs'); audit(reread, actual_modes)
        assets = {archive.name: archive.read_bytes()}
        if args.retrotink:
            data = args.retrotink.read_bytes()
            require(sha(data) == RETROTINK_SHA256, 'Unreviewed RetroTINK pack')
            destination = args.out_dir / args.retrotink.name
            require(not destination.exists(), 'Preserve existing optional pack')
            shutil.copyfile(args.retrotink, destination); assets[destination.name] = data
        (args.out_dir / 'SHA256SUMS').write_bytes(checksums(assets))
        report.update(runtime_archive=archive.name, runtime_sha256=sha(archive.read_bytes()), bytes=archive.stat().st_size)
        (args.out_dir / 'PACKAGE_VALIDATION.json').write_bytes(js(report))
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
