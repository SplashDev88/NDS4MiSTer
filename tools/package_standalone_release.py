#!/usr/bin/env python3
"""Build the standalone installer without touching an existing MiSTer install."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'tools/standalone_host'
SUPPORT = 'Scripts/.NDS_Standalone/'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('core', 'helper', 'host', 'module', 'out-dir'):
        p.add_argument('--' + name, required=True, type=Path)
    a = p.parse_args()
    version = (HOST / 'VERSION').read_text().strip()
    spec = importlib.util.spec_from_file_location('supervisor', HOST / 'supervisor.py')
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    files = {}
    executable = set()

    def add(name, path, mode=0o644):
        assert name not in files and '..' not in Path(name).parts
        assert path.is_file() and not path.is_symlink(), path
        files[name] = path.read_bytes()
        if mode == 0o755:
            executable.add(name)

    add('Scripts/NDS_Standalone.sh', HOST / 'NDS_Standalone.sh', 0o755)
    add(SUPPORT + 'supervisor.py', HOST / 'supervisor.py', 0o755)
    add(SUPPORT + 'Kickstart.sh', HOST / 'Kickstart.sh', 0o755)
    add(SUPPORT + 'NDS_Standalone.rbf', a.core)
    add(SUPPORT + 'nds_standalone_host', a.host, 0o755)
    add(SUPPORT + 'support/nds_hybrid_3d_service', a.helper, 0o755)
    add(SUPPORT + 'support/nds_mem_wc.ko', a.module)
    expected = {
        'NDS_Standalone.rbf': supervisor.EXPECTED_CORE,
        'support/nds_hybrid_3d_service': supervisor.EXPECTED_HELPER,
        'support/nds_mem_wc.ko': supervisor.EXPECTED_WC,
        'Kickstart.sh': supervisor.EXPECTED_KICKSTART,
    }
    for name, digest in expected.items():
        assert sha(files[SUPPORT + name]) == digest, name
    for name in ('nds_hybrid_3d_service', 'nds_mem_wc.ko'):
        digest = sha(files[SUPPORT + 'support/' + name])
        files[SUPPORT + 'support/' + name + '.sha256'] = (digest + '  ' + name + '\n').encode()
    add('NDS4MiSTer_Standalone_README.txt', ROOT / 'docs/STANDALONE_QUICK_START.txt')
    add(SUPPORT + 'README.txt', ROOT / 'docs/STANDALONE_QUICK_START.txt')
    add(SUPPORT + 'RELEASE_NOTES.md', ROOT / 'docs/RELEASE_NOTES_V060_BETA.md')
    add(SUPPORT + 'SOURCE_PACKAGE.txt', ROOT / 'SOURCE_PACKAGE.txt')
    for target, source in {
        'GPL-3.0.txt': 'LICENSE.txt',
        'WC-GPL-2.0.txt': 'kernel/nds_mem_wc/COPYING',
        'STANDALONE_THIRD_PARTY.md': 'tools/standalone_host/THIRD_PARTY.md',
        'Template_MiSTer.txt': 'fpga/mister_nitro_console_island/LICENSE.Template_MiSTer',
        'Nitro_DarkSide.md': 'third_party/Nitro_DarkSide/LICENSE.md',
        'melonDS.txt': 'third_party/melonDS/LICENSE',
        'teakra.txt': 'third_party/melonDS/src/teakra/LICENSE',
        'blip-buf.txt': 'third_party/melonDS/src/blip-buf/license.txt',
        'dolphin.txt': 'third_party/melonDS/src/dolphin/license_dolphin.txt',
        'tiny-AES.txt': 'third_party/melonDS/src/tiny-AES-c/unlicense.txt',
        'fatfs.txt': 'third_party/melonDS/src/fatfs/LICENSE.txt',
        'libslirp.txt': 'third_party/melonDS/src/net/libslirp/COPYRIGHT',
    }.items():
        add(SUPPORT + 'licenses/' + target, ROOT / source)
    for path in sorted((ROOT / 'licenses/runtime').glob('*.txt')):
        add(SUPPORT + 'licenses/runtime/' + path.name, path)
    revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    manifest = {
        'name': 'NDS4MiSTer Standalone', 'version': version,
        'source_revision': revision,
        'host_sha256': sha(a.host.read_bytes()),
        'core_sha256': supervisor.EXPECTED_CORE,
        'helper_sha256': supervisor.EXPECTED_HELPER,
        'kickstart_sha256': supervisor.EXPECTED_KICKSTART,
        'module_sha256': supervisor.EXPECTED_WC,
        'runtime_environment': supervisor.EXPECTED_SPEED_ENV,
        'shared_saves': '/media/fat/saves/NDS',
        'rom_directory': '/media/fat/games/NDS',
    }
    files[SUPPORT + 'manifest.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    files[SUPPORT + 'SHA256SUMS'] = ''.join(
        sha(data) + '  ./' + name + '\n' for name, data in sorted(files.items())
    ).encode()
    # No user preferences or game data can be overwritten by extraction.
    for name in files:
        assert name.startswith(SUPPORT) or name in {
            'Scripts/NDS_Standalone.sh', 'NDS4MiSTer_Standalone_README.txt'}
        assert Path(name).suffix.lower() not in {'.cfg', '.ini', '.map', '.nds', '.sav', '.dsv'}
        assert '/inputs/' not in name
    a.out_dir.mkdir(parents=True, exist_ok=True)
    archive = a.out_dir / ('NDS4MiSTer_' + version + '_Standalone.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 9, 30, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if name in executable else 0o644)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert z.namelist() == sorted(files)
        assert all(z.read(name) == data for name, data in files.items())
    digest = sha(archive.read_bytes())
    archive.with_suffix('.zip.sha256').write_text(digest + '  ' + archive.name + '\n')
    print(json.dumps({'archive': str(archive), 'sha256': digest,
                      'files': len(files), 'bytes': archive.stat().st_size(),
                      'source_revision': revision}, indent=2))


if __name__ == '__main__':
    main()
