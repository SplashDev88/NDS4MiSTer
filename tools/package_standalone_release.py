#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package the reviewed standalone binaries using only public source inputs.

No build, network or device operation is performed. Use --check-only to verify
all inputs and inspect the intended layout without writing an archive. Extracted
source archives can supply --source-revision instead of requiring a Git checkout.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'tools/standalone_host'
SUPPORT = 'Scripts/.NDS_Standalone/'
VERSION = 'v0.9.0-rc.4'
HOST_SHA = '9a5500dc65f3afafd602e56fcf2b5d73846a1a0cb1ece77dc3fcede06712e361'
FRONTEND_BUILD_SHA = '220a4d30bd2c76dc47274036d7f7d93e3c22bedac802bc63de0087e0fb67d850'
FPGA_BUILD_SHA = '4639337f86cc0e7e4f8acc7479c30c267fb07de5e6fe184bad858c4152b8b86d'
FPGA_SOURCE_SHA = 'a95f446e48e4fa15cd34f0e05d87486931bac60816ae75f33b0700dc4d50ce01'
ACCEPTED_HOST_SHA = 'd5314c9ca75d015c3ce4447a04836711aa2d147caec16ef0fdcdf7b91236f151'
RUNTIME_INPUT_SHA = '84ebdbf7376762f87756949040a3cda68dc785f13d3090571d34dac3a678a7da'
LICENSES = {
    'GPL-3.0.txt': 'LICENSE.txt',
    'WC-GPL-2.0.txt': 'kernel/nds_mem_wc/COPYING',
    'STANDALONE_THIRD_PARTY.md': 'tools/standalone_host/THIRD_PARTY.md',
    'FreeBIOS.txt': 'third_party/melonDS/freebios/drastic_bios_readme.txt',
    'Template_MiSTer.txt': 'fpga/mister_nitro_console_island/LICENSE.Template_MiSTer',
    'Nitro_DarkSide.md': 'third_party/Nitro_DarkSide/LICENSE.md',
    'melonDS.txt': 'third_party/melonDS/LICENSE',
    'teakra.txt': 'third_party/melonDS/src/teakra/LICENSE',
    'blip-buf.txt': 'third_party/melonDS/src/blip-buf/license.txt',
    'dolphin.txt': 'third_party/melonDS/src/dolphin/license_dolphin.txt',
    'tiny-AES.txt': 'third_party/melonDS/src/tiny-AES-c/unlicense.txt',
    'fatfs.txt': 'third_party/melonDS/src/fatfs/LICENSE.txt',
    'libslirp.txt': 'third_party/melonDS/src/net/libslirp/COPYRIGHT',
}
RUNTIME_LICENSES = ('GCC-13-cross-copyright-and-runtime-exception.txt',
                    'GPL-3.0-GCC-runtime.txt', 'LGPL-2.1-glibc.txt', 'glibc-armhf-copyright.txt')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def collect(a):
    need((HOST / 'VERSION').read_text().strip() == VERSION, 'Unexpected frontend VERSION')
    spec = importlib.util.spec_from_file_location('supervisor', HOST / 'supervisor.py')
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    revision = a.source_revision or subprocess.check_output(
        ['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    need(re.fullmatch(r'[0-9a-f]{40}', revision) is not None, 'Full source commit hash required')
    files, executable = {}, set()

    def add(name, path, mode=0o644):
        need(name not in files and '..' not in Path(name).parts, 'Duplicate/unsafe archive name')
        need(path.is_file() and not path.is_symlink(), 'Missing/nonregular input: ' + str(path))
        files[name] = path.read_bytes()
        if mode == 0o755:
            executable.add(name)

    add('Scripts/NDS4MiSTer.sh', HOST / 'NDS4MiSTer.sh', 0o755)
    add(SUPPORT + 'supervisor.py', HOST / 'supervisor.py', 0o755)
    add(SUPPORT + 'Kickstart.sh', HOST / 'Kickstart.sh', 0o755)
    add(SUPPORT + 'clock_control.py', HOST / 'clock_control.py', 0o755)
    add(SUPPORT + 'NDS_Standalone.rbf', a.core)
    add(SUPPORT + 'nds_standalone_host', a.host, 0o755)
    add(SUPPORT + 'support/nds_hybrid_3d_service', a.helper, 0o755)
    add(SUPPORT + 'support/nds_mem_wc.ko', a.module)
    module_618 = 'support/modules/6.18.38-MiSTer/nds_mem_wc.ko'
    add(SUPPORT + module_618, a.module_618)
    add(SUPPORT + 'support/modules/6.18.38-MiSTer/BUILD_PROVENANCE.json',
        ROOT / 'kernel/nds_mem_wc/BUILD_PROVENANCE-6.18.38.json')
    for name, digest in {
        'NDS_Standalone.rbf': supervisor.EXPECTED_CORE,
        'support/nds_hybrid_3d_service': supervisor.EXPECTED_HELPER,
        'support/nds_mem_wc.ko': supervisor.EXPECTED_WC,
        module_618: supervisor.EXPECTED_WC_618,
        'clock_control.py': supervisor.EXPECTED_CLOCK,
        'Kickstart.sh': supervisor.EXPECTED_KICKSTART,
        'nds_standalone_host': HOST_SHA,
    }.items():
        need(sha(files[SUPPORT + name]) == digest, 'Binary/runtime checksum mismatch: ' + name)
    for name in ('nds_hybrid_3d_service', 'nds_mem_wc.ko'):
        digest = sha(files[SUPPORT + 'support/' + name])
        files[SUPPORT + 'support/' + name + '.sha256'] = (digest + '  ' + name + '\n').encode()
    files[SUPPORT + module_618 + '.sha256'] = (
        supervisor.EXPECTED_WC_618 + '  nds_mem_wc.ko\n').encode()
    docs = {'README.md': ROOT / 'docs/STANDALONE_INSTALL_README.md',
            'RELEASE_NOTES.md': ROOT / 'docs/RELEASE_NOTES_V090_RC4.md',
            'QUICK_START.txt': ROOT / 'docs/STANDALONE_QUICK_START.txt'}
    for name, path in docs.items():
        add(name, a.docs_dir / name if a.docs_dir else path)
    add('LICENSE.txt', ROOT / 'LICENSE.txt')
    for name, path in LICENSES.items():
        add(SUPPORT + 'licenses/' + name, ROOT / path)
    for name in RUNTIME_LICENSES:
        add(SUPPORT + 'licenses/runtime/' + name, ROOT / 'licenses/runtime' / name)
    manifest = {
        'name': 'NDS4MiSTer', 'version': VERSION, 'source_revision': revision,
        'source_tag': VERSION, 'runtime_baseline': 'standalone-fw1-20261003',
        'host_change': 'Release version label only; frontend behavior unchanged from rc.3.',
        'host_sha256': HOST_SHA, 'core_sha256': supervisor.EXPECTED_CORE,
        'helper_sha256': supervisor.EXPECTED_HELPER, 'module_sha256': supervisor.EXPECTED_WC,
        'kickstart_sha256': supervisor.EXPECTED_KICKSTART,
        'clock_control_sha256': supervisor.EXPECTED_CLOCK,
        'kernel_module_sha256': {'5.15.1-MiSTer': supervisor.EXPECTED_WC,
                                 '6.18.38-MiSTer': supervisor.EXPECTED_WC_618},
        'supervisor_sha256': sha(files[SUPPORT + 'supervisor.py']),
        'launcher_sha256': sha(files['Scripts/NDS4MiSTer.sh']),
        'runtime_environment': supervisor.EXPECTED_SPEED_ENV, 'hps_clock_khz': 1000000,
        'remote_kit': '/media/fat/Scripts/.NDS_Standalone', 'rom_directory': '/media/fat/games/NDS',
        'shared_saves': '/media/fat/saves/NDS', 'firmware_working_image': '/media/fat/saves/NDS/firmware.bin',
        'user_dumps_included': False, 'user_settings_included': False,
        'diagnostic_revision': 'native-pc9-memctl-v1', 'fpga_source_manifest_sha256': FPGA_SOURCE_SHA,
        'frontend_build_sha256': FRONTEND_BUILD_SHA,
    }
    files[SUPPORT + 'manifest.json'] = json_bytes(manifest)
    files[SUPPORT + 'BUILD_PROVENANCE.json'] = json_bytes({
        'release': VERSION, 'source_revision': revision, 'fpga_build_sha256': FPGA_BUILD_SHA,
        'fpga_source_manifest_sha256': FPGA_SOURCE_SHA, 'accepted_host_sha256': ACCEPTED_HOST_SHA,
        'frontend_build_sha256': FRONTEND_BUILD_SHA, 'release_host_sha256': HOST_SHA,
        'runtime_input_receipt_sha256': RUNTIME_INPUT_SHA,
        'scope': 'Fire Emblem Engine B C/D VRAM address-mapping fix on rc.3; accepted FPGA binary retained from the hardware test; renderer, both kernel modules, 1 GHz clock and runtime speed options unchanged; host release label updated.',
    })
    files[SUPPORT + 'SHA256SUMS'] = ''.join(
        sha(data) + '  ' + name[len(SUPPORT):] + '\n'
        for name, data in sorted(files.items()) if name.startswith(SUPPORT)
    ).encode()
    for name, data in files.items():
        need(name.startswith(SUPPORT) or name in set(docs) | {'LICENSE.txt', 'Scripts/NDS4MiSTer.sh'}, 'Unexpected package path')
        need(Path(name).suffix.lower() not in {'.cfg', '.ini', '.map', '.nds', '.sav', '.dsv'} and '/inputs/' not in name, 'User data entered package')
        if Path(name).suffix in {'.json', '.txt', '.md', '.sh', '.py'}:
            need(b'/Users/' not in data, 'Private local path entered package')
    return files, executable, revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('core', 'helper', 'host', 'module', 'module-618'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--out-dir', type=Path)
    parser.add_argument('--docs-dir', type=Path, help='Directory containing README.md, RELEASE_NOTES.md and QUICK_START.txt')
    parser.add_argument('--source-revision', help='Full corresponding-source commit; otherwise use checkout HEAD')
    parser.add_argument('--check-only', action='store_true')
    a = parser.parse_args()
    files, executable, revision = collect(a)
    inventory = {name: {'sha256': sha(data), 'bytes': len(data), 'mode': oct(0o755 if name in executable else 0o644)}
                 for name, data in sorted(files.items())}
    if a.check_only:
        print(json.dumps({'check_only': True, 'version': VERSION, 'source_revision': revision, 'files': inventory}, indent=2))
        return
    need(a.out_dir is not None, '--out-dir required unless --check-only')
    archive = a.out_dir / ('NDS4MiSTer_' + VERSION + '_Standalone.zip')
    checksum = archive.with_suffix('.zip.sha256')
    need(not archive.exists() and not checksum.exists(), 'Output archive/checksum already exists')
    a.out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 4, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if name in executable else 0o644)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    with zipfile.ZipFile(archive) as z:
        need(z.testzip() is None and z.namelist() == sorted(files), 'Archive integrity/inventory mismatch')
        for name, data in files.items():
            need(z.read(name) == data, 'Archive data mismatch')
            need(stat.S_IMODE(z.getinfo(name).external_attr >> 16) == int(inventory[name]['mode'], 8), 'Archive mode mismatch')
    digest = sha(archive.read_bytes())
    checksum.write_text(digest + '  ' + archive.name + '\n')
    print(json.dumps({'archive': str(archive), 'sha256': digest, 'files': len(files),
                      'bytes': archive.stat().st_size, 'source_revision': revision}, indent=2))


if __name__ == '__main__':
    main()
