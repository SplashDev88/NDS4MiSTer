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
VERSION = 'v0.9.0-rc.9'
HOST_VERSION = 'v0.9.0-rc.8'
HOST_SHA = '6b63736edbe4b82821edd2dfe460a731281ddfd5ae0d27f51cb88d0a4cdf192f'
HOST_REVISION = 'db09fc5cee49ccca4e9e3b9b71e65ba303836607'
FPGA_SOURCE_SHA = '927c76ad39990e59c2ea505f9ef4b7d7e729bbec55617d6a022195b2b3027118'
FPGA_REVISION = '32c31cd94b5a5734b6c034e8647d2a4924e990ae'
RUNTIME_REVISION = '1d3a33361730ca0d2f9123c578378bca40463aad'
RUNTIME_BASELINE = 'Castlevania Beta12 (C55 worker range)'
HOST_CHANGE = 'Exact Beta12 host with offline RTC fallback; retained rc.8 internal version label.'
RELEASE_SCOPE = 'Exact frozen Beta12 core, renderer, host and modules at 1 GHz. Public launcher layout, release metadata and documentation only; no binary rebuild.'
DIAGNOSTIC_REVISION = 'functional-status-and-coherent-rtc-snapshots'
SOURCE_RECORDS = {
    'FPGA_SOURCE_INPUTS.json': ('docs/release/BETA12_FPGA_SOURCE_INPUTS.json', FPGA_SOURCE_SHA),
    'BUILD_SOURCE_INPUTS.json': ('docs/release/BETA12_BUILD_SOURCE_INPUTS.json', '0bdfe3f976d451a95c4f3e78ddf1404cd0b16fae45f248c6189c2a9eacc19c4f'),
    'RENDERER_SOURCE_INPUTS.json': ('docs/release/BETA12_RENDERER_SOURCE_INPUTS.json', 'da8239c9b9b81c98a8a0d10fbe35f46328e5aac8e9a4b3ee5a4c3547d7ff37f0'),
    'PUBLIC_TEST_QUALIFICATION.json': ('docs/release/BETA12_PUBLIC_TEST_QUALIFICATION.json', '66e9b9520925923a2ad508a1e401403083d9248f4101996b44126f56accc12db'),
    'FROZEN_BUILD_PROVENANCE.json': ('docs/release/BETA12_BUILD_PROVENANCE.json', '636842280c28d7710d5b041ba620a87ccfd91ceb7b4dcac82a0944f5244a9f67'),
}
STATIC_TIMING = {'clean': False, 'route_and_assembly_passed': True,
                 'new_timing_analysis_performed': False}
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


def verify_source_inputs(records):
    """Verify frozen build records and current compiled inputs, without Git/network."""
    for name, (_, digest) in SOURCE_RECORDS.items():
        need(sha(records[name]) == digest, 'Frozen source record mismatch: ' + name)
    original = json.loads(records['BUILD_SOURCE_INPUTS.json'])
    reviewed = json.loads(records['RENDERER_SOURCE_INPUTS.json'])
    need(len(original) == len(reviewed) == 851 and original.keys() == reviewed.keys(),
         'Renderer source inventory mismatch')
    need([n for n in original if original[n] != reviewed[n]] ==
         ['src/replay/GameQueryProfileTest.cpp'], 'Unexpected post-build renderer differences')
    for name, digest in reviewed.items():
        need(sha((ROOT / name).read_bytes()) == digest, 'Renderer source differs: ' + name)
    fpga = json.loads(records['FPGA_SOURCE_INPUTS.json'])
    provenance = json.loads(records['FROZEN_BUILD_PROVENANCE.json'])
    suffixes = {'.v', '.sv', '.vhd', '.vhdl', '.vh', '.svh', '.sdc', '.qsf',
                '.qip', '.tcl', '.mif', '.hex', '.mem'}
    hardware = {n: h for n, h in fpga.items() if Path(n).suffix.lower() in suffixes}
    need(len(hardware) == 552, 'Unexpected FPGA HDL/config inventory')
    for name, digest in hardware.items():
        data = (ROOT / name).read_bytes()
        if name == 'fpga/mister_nitro_console_island/NDS4MiSTer.qsf':
            override = provenance['fpga_qsf_override']
            need(sha(data) == override['base_sha256'], 'FPGA base QSF differs')
            data += override['appended_text'].encode()
            need(sha(data) == override['build_sha256'], 'FPGA build override differs')
        need(sha(data) == digest, 'FPGA HDL/config source differs: ' + name)


def collect(a):
    need((HOST / 'VERSION').read_text().strip() == HOST_VERSION, 'Unexpected frontend VERSION')
    import sys
    sys.path.insert(0, str(HOST))
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
    add(SUPPORT + 'video_target.py', HOST / 'video_target.py', 0o755)
    for name, (path, _) in SOURCE_RECORDS.items():
        add(SUPPORT + name, ROOT / path)
    verify_source_inputs({name: files[SUPPORT + name] for name in SOURCE_RECORDS})
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
            'RELEASE_NOTES.md': ROOT / 'docs/RELEASE_NOTES_V090_RC9.md',
            'QUICK_START.txt': ROOT / 'docs/STANDALONE_QUICK_START.txt',
            'GAME_CLOCK.md': ROOT / 'docs/GAME_CLOCK.md'}
    for name, path in docs.items():
        add(name, a.docs_dir / name if a.docs_dir else path)
    add('LICENSE.txt', ROOT / 'LICENSE.txt')
    for name, path in LICENSES.items():
        add(SUPPORT + 'licenses/' + name, ROOT / path)
    for name in RUNTIME_LICENSES:
        add(SUPPORT + 'licenses/runtime/' + name, ROOT / 'licenses/runtime' / name)
    manifest = {
        'name': 'NDS4MiSTer', 'version': VERSION, 'source_revision': revision,
        'release_channel': 'beta', 'runtime_source_revision': RUNTIME_REVISION,
        'host_source_revision': HOST_REVISION, 'fpga_source_revision': FPGA_REVISION, 'runtime_baseline': RUNTIME_BASELINE,
        'host_internal_version': HOST_VERSION,
        'renderer_source_revision': RUNTIME_REVISION,
        'host_change': HOST_CHANGE,
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
        'diagnostic_revision': DIAGNOSTIC_REVISION, 'fpga_source_manifest_sha256': FPGA_SOURCE_SHA,
        'video_target_sha256': sha(files[SUPPORT + 'video_target.py']),
        'required_firmware_capability': 0x400,
        'rtc_snapshot_signature': 0x5254, 'rtc_snapshot_version': 1,
        'rtc_persistence': 'kit/NDS_rtc.cfg', 'rtc_alarm_interrupts': False,
        'static_timing_clean': False,
        'frozen_build_provenance_sha256': SOURCE_RECORDS['FROZEN_BUILD_PROVENANCE.json'][1],
    }
    files[SUPPORT + 'manifest.json'] = json_bytes(manifest)
    files[SUPPORT + 'BUILD_PROVENANCE.json'] = json_bytes({
        'release': VERSION, 'packaging_source_revision': revision,
        'runtime_source_revision': RUNTIME_REVISION,
        'fpga_source_manifest_sha256': FPGA_SOURCE_SHA,
        'core_sha256': supervisor.EXPECTED_CORE, 'host_sha256': HOST_SHA,
        'renderer_sha256': supervisor.EXPECTED_HELPER,
        'runtime_binaries_changed_for_packaging': False,
        'host_source_revision': HOST_REVISION,
        'fpga_source_revision': FPGA_REVISION,
        'renderer_source_revision': RUNTIME_REVISION,
        'frozen_build_provenance_sha256': SOURCE_RECORDS['FROZEN_BUILD_PROVENANCE.json'][1],
        'scope': RELEASE_SCOPE,
        'static_timing': STATIC_TIMING,
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
    parser.add_argument('--docs-dir', type=Path, help='Directory containing README.md, RELEASE_NOTES.md, QUICK_START.txt and GAME_CLOCK.md')
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
            info = zipfile.ZipInfo(name, (2026, 10, 17, 0, 0, 0))
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
