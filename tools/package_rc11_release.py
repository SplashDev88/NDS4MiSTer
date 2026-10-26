#!/usr/bin/env python3
"""Package RC11 from the tested Portrait FMV Beta4 and a label-only host rebuild."""
from pathlib import Path, PurePosixPath
import argparse
import ast
import gzip
import hashlib
import io
import json
import re
import stat
import struct
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v0.9.0-rc.11'
PREFIX = 'Scripts/.NDS_Standalone/'
BETA_PREFIX = 'Scripts/.NDS_Portrait_FMV_Beta4_20261025/'
BETA_SHA = '4eda19c56d6cf15b7fb3e68e3fc306596f7d34123798494b5de287eae2cd16fb'
PINS = {
    'NDS_Standalone.rbf': '876ec97a6044191515a0fea910eb1359417a466fdd0a23e31e0cca2a069a08fa',
    'support/nds_hybrid_3d_service': 'bce5e79d8e1825b0380dc4e14d5b3c892833faa87a23538ae79f53f03df07da8',
    'nds_standalone_host': 'd2459739f78a335c61aadef96d086e5457252eeb434a1a66833bf61ae1de001b',
}
ROOT_RUNTIME = {'NDS_Standalone.rbf', 'nds_standalone_host', 'NDS_speed.cfg',
                'Kickstart.sh', 'auto_movies.py', 'clock_control.py',
                'video_target.py', 'supervisor.py'}
DOCS = {
    'README.md': 'docs/STANDALONE_INSTALL_README.md',
    'RELEASE_NOTES.md': 'docs/RELEASE_NOTES_V090_RC11.md',
    'QUICK_START.txt': 'docs/STANDALONE_QUICK_START.txt',
    'LICENSE.txt': 'LICENSE.txt', 'GAME_CLOCK.md': 'docs/GAME_CLOCK.md',
    'VALIDATION_RC11.md': 'docs/release/VALIDATION_RC11.md',
    'RETROTINK_DS_LITE.md': 'docs/release/RETROTINK_DS_LITE.md',
}
FORBIDDEN = {'.nds', '.sav', '.dsv', '.srm', '.duc', '.rom', '.bios', '.pem',
             '.key', '.p12', '.pfx', '.mp4', '.mov', '.mkv', '.ini'}


def need(value, message):
    if not value:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def js(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def safe(name):
    return bool(name) and not name.startswith('/') and '\\' not in name and ':' not in name and all(p not in ('', '.', '..') for p in name.split('/'))


def read_zip(path):
    with zipfile.ZipFile(path) as z:
        need(z.testzip() is None, 'ZIP CRC failure')
        need(len(z.namelist()) == len(set(z.namelist())), 'Duplicate ZIP paths')
        for i in z.infolist():
            need(safe(i.filename), 'Unsafe ZIP path')
            need(stat.S_IFMT(i.external_attr >> 16) in (0, stat.S_IFREG), 'Nonregular ZIP member')
        return {i.filename: z.read(i) for i in z.infolist()}, {i.filename: (i.external_attr >> 16) & 0o777 for i in z.infolist()}


def elf_sections(data):
    need(data[:6] == b'\x7fELF\x01\x01', 'Expected little-endian ELF32 host')
    h = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    size, count, names_index = h[-3:]
    headers = [struct.unpack_from('<10I', data, h[6] + i * size) for i in range(count)]
    ns = headers[names_index]
    names = data[ns[4]:ns[4]+ns[5]]
    return {names[s[0]:].split(b'\0', 1)[0].decode(): data[s[4]:s[4]+s[5]] for s in headers if s[1] != 8}


def check_label_only(old, new):
    a, b = elf_sections(old), elf_sections(new)
    need(set(a) == set(b), 'Host ELF section set changed')
    changed = [k for k in a if a[k] != b[k]]
    need(set(changed) <= {'.rodata', '.note.gnu.build-id'}, 'Host executable code changed')
    need(a['.rodata'].replace(b'NDS4MiSTer v0.9.0-rc10', b'NDS4MiSTer v0.9.0-rc11') == b['.rodata'], 'Host change exceeds version label')
    return changed


def pgo_archive(data):
    output = io.BytesIO()
    count = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as source:
        with gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as target:
                for m in source.getmembers():
                    if not m.isfile() or not m.name.startswith('pgo-combo3-data/'):
                        continue
                    need(safe(m.name) and m.name.endswith('.gcda'), 'Unexpected PGO input')
                    body = source.extractfile(m).read()
                    n = tarfile.TarInfo(m.name)
                    n.size = len(body); n.mode = 0o644; n.mtime = 0
                    target.addfile(n, io.BytesIO(body)); count += 1
    need(count > 50, 'Missing compiler training counters')
    return output.getvalue(), count


def check_fpga(data, manifest):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as t:
        members = t.getmembers()
        need(all(m.isfile() and safe(m.name) for m in members), 'Unsafe frozen FPGA source')
        need(len(members) == len(set(m.name for m in members)), 'Duplicate FPGA source')
        need(set(t.getnames()) == set(manifest['all_build_inputs']), 'Incomplete FPGA input inventory')
        for name, digest in manifest['all_build_inputs'].items():
            need(sha(t.extractfile(name).read()) == digest, 'FPGA source mismatch: ' + name)
    return len(members)


def content_audit(name, data, depth=0):
    need(depth < 4, 'Unexpected archive nesting')
    need(safe(name), 'Unsafe content path: ' + name)
    freebios_makefile = depth > 0 and name == 'third_party/melonDS/freebios/Makefile.bios'
    # FFmpeg's upstream FATE references have media suffixes but contain text
    # checksums/metadata, not recordings. The whole upstream archive is pinned.
    fate_reference = depth > 0 and name.startswith('ffmpeg-7.1.1/tests/ref/') and all(c in (9, 10, 13) or 32 <= c < 127 for c in data)
    need(freebios_makefile or fate_reference or PurePosixPath(name).suffix.lower() not in FORBIDDEN, 'User/secret file: ' + name)
    need(not any(p in ('.git', '__pycache__', '.cache', 'prepared-roms') for p in PurePosixPath(name).parts), 'Cache or repository state: ' + name)
    if name.endswith(('.tar.gz', '.tar.xz', '.tar')):
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as t:
            seen = set()
            for member in t.getmembers():
                n = member.name.rstrip('/')
                need(safe(n) and n not in seen, 'Unsafe/duplicate nested member')
                seen.add(n)
                need(member.isdir() or member.isfile(), 'Nonregular nested member')
                if member.isfile():
                    content_audit(n, t.extractfile(member).read(), depth + 1)
    elif PurePosixPath(name).suffix.lower() in {'.py', '.sh', '.json', '.md', '.txt', '.qsf', '.qpf'}:
        patterns = [rb'/' + rb'Users/[A-Za-z0-9._-]+/',
                    rb'-----BEGIN ' + rb'(?:[A-Z]+ )?PRIVATE KEY-----',
                    rb'gh' + rb'[pousr]_[A-Za-z0-9]{20,}',
                    rb'github' + rb'_pat_[A-Za-z0-9_]{20,}']
        for p in patterns:
            need(not re.search(p, data), 'Private path/secret in ' + name)


def assemble(beta_path):
    need(sha(beta_path.read_bytes()) == BETA_SHA, 'Wrong Beta4 input archive')
    original, original_modes = read_zip(beta_path)
    beta = {n[len(BETA_PREFIX):]: b for n, b in original.items() if n.startswith(BETA_PREFIX)}
    old_manifest = json.loads(beta['manifest.json'])
    need(not git('status', '--porcelain'), 'Commit release source before packaging')
    revision = git('rev-parse', 'HEAD').decode().strip()
    files, modes = {}, {}
    for n, b in beta.items():
        if n in ROOT_RUNTIME or n.startswith(('support/', 'fmv/', 'licenses/')):
            files[PREFIX+n] = b
            modes[PREFIX+n] = original_modes[BETA_PREFIX+n] or 0o644
    host = (ROOT/'tools/standalone_host/nds_standalone_host').read_bytes()
    changed_sections = check_label_only(beta['nds_standalone_host'], host)
    files[PREFIX+'nds_standalone_host'] = host
    supervisor = (ROOT/'tools/standalone_host/supervisor.py').read_bytes()
    need(supervisor == beta['supervisor.py'].replace(b'v0.9.0-rc.8', VERSION.encode()), 'Supervisor differs beyond release label')
    files[PREFIX+'supervisor.py'] = supervisor
    for n in ('Kickstart.sh', 'auto_movies.py', 'clock_control.py', 'video_target.py', 'fmv/profiles.json'):
        need(files[PREFIX+n] == (ROOT/'tools/standalone_host'/n).read_bytes(), 'Runtime/source mismatch: '+n)
    for n, h in PINS.items():
        need(sha(files[PREFIX+n]) == h, 'Pinned runtime mismatch: '+n)
    launcher = 'Scripts/NDS4MiSTer.sh'
    files[launcher] = (ROOT/'tools/standalone_host/NDS4MiSTer.sh').read_bytes()
    modes[launcher] = modes[PREFIX+'nds_standalone_host'] = 0o755
    for n, source in DOCS.items():
        files[n] = (ROOT/source).read_bytes()
    source_name = 'source/NDS4MiSTer-rc11-source.tar.gz'
    files[PREFIX+source_name] = git('archive', '--format=tar.gz', 'HEAD')
    for n in ('side-native-fpga-inputs.tar.gz', 'ffmpeg-7.1.1.tar.xz'):
        files[PREFIX+'source/'+n] = beta['source/'+n]
    pgo, pgo_count = pgo_archive(beta['source/portrait-beta1-reproduction.tar.gz'])
    files[PREFIX+'source/portrait-combo3-pgo.tar.gz'] = pgo
    for n in ('BUILD_RC11.md', 'RC11_RENDERER_BUILD.json', 'RC11_RENDERER_BUILD.sh',
              'RC11_FPGA_INPUTS.json', 'RC11_FPGA_BUILD.json'):
        files[PREFIX+'source/'+n] = (ROOT/'docs/release'/n).read_bytes()
    for n in ('RC11_PORTRAIT_HARDWARE.json', 'RC11_JP1_STALL_INVESTIGATION.json',
              'RC11_MENU_MATRIX.json', 'RC11_HOST_LABEL_VALIDATION.json', 'RC11_OFFLINE_VALIDATION.json',
              'PORTRAIT_FMV_SOFTWARE_20261025.json'):
        files[PREFIX+'source/validation/'+n] = (ROOT/'docs/release'/n).read_bytes()
    fpga_manifest = json.loads(files[PREFIX+'source/RC11_FPGA_INPUTS.json'])
    checked = check_fpga(files[PREFIX+'source/side-native-fpga-inputs.tar.gz'], fpga_manifest)
    files[PREFIX+'fpga-source-manifest.json'] = js(dict(
        core_sha256=PINS['NDS_Standalone.rbf'], source_revision=old_manifest['core_source_revision'],
        packaged_fpga_source='source/side-native-fpga-inputs.tar.gz',
        frozen_input_sha256=fpga_manifest['all_build_inputs'], static_timing_closed=False))
    provenance = dict(version=VERSION, packaging_source_revision=revision,
                      baseline_archive_sha256=BETA_SHA, runtime_pins=PINS,
                      baseline_source_revision='e7bb1119ab6b3fc0f2f8f03ffc38f8a0ff474b27',
                      runtime_changes=['Host menu version text', 'Supervisor release-label text', 'Normal standalone launcher path'],
                      host_changed_sections=changed_sections, host_executable_code_identical=True,
                      renderer_and_fpga_byte_identical=True, frozen_fpga_inputs_checked=checked,
                      pgo_counter_files=pgo_count, published=False,
                      validation_scope='Pinned beta hardware results plus RC11 offline package checks; no new full-game hardware qualification')
    files[PREFIX+'BUILD_PROVENANCE.json'] = js(provenance)
    profiles = json.loads(files[PREFIX+'fmv/profiles.json'])['profiles']
    runtime_files = {n[len(PREFIX):]: sha(b) for n, b in files.items() if n.startswith(PREFIX) and not n.startswith((PREFIX+'source/', PREFIX+'licenses/')) and not n.endswith('BUILD_PROVENANCE.json')}
    manifest = {k: old_manifest[k] for k in ('hps_clock_khz', 'required_firmware_capability',
        'kernel_module_sha256', 'runtime_environment', 'nsmb_default', 'nsmb_regions',
        'nsmb_validation', 'prepared_cache_budget_bytes', 'shared_saves',
        'rtc_alarm_interrupts', 'rtc_snapshot_signature', 'rtc_snapshot_version')}
    manifest.update(name='NDS4MiSTer', version=VERSION, menu_version='v0.9.0-rc11',
                    release_channel='release candidate', package_revision=1,
                    remote_kit='/media/fat/Scripts/.NDS_Standalone',
                    packaging_source_revision=revision, source_revision=revision,
                    source_commit=revision, runtime_source_archive=source_name,
                    runtime_source_revision=revision,
                    source_archive_sha256=sha(files[PREFIX+source_name]),
                    core_sha256=PINS['NDS_Standalone.rbf'],
                    core_source_revision=old_manifest['core_source_revision'],
                    host_sha256=PINS['nds_standalone_host'], host_source_revision=revision,
                    helper_sha256=PINS['support/nds_hybrid_3d_service'],
                    helper_source_revision=old_manifest['helper_source_revision'],
                    renderer_source_revision=old_manifest['helper_source_revision'],
                    loader_source_revision=revision, supervisor_source_revision=revision,
                    supervisor_sha256=sha(supervisor), launcher_sha256=sha(files[launcher]),
                    automatic_movie_files=runtime_files,
                    automatic_movie_scope='Exact registered movie identities; includes all four known retail Portrait of Ruin variants',
                    prepared_cache_profiles=len(profiles), portrait_fmv_variants=['ACBE0','ACBP0','ACBJ0','ACBJ1'],
                    static_timing_clean=False, public_release_qualified=False,
                    public_release_scope='Prepared release candidate; bounded validation and unresolved timing are documented',
                    user_dumps_included=False, user_settings_included=False,
                    speed_hacks_menu=False, dx_experiment_included=False,
                    release_performance_preset_included=True,
                    installation_scope='Normal standalone kit; existing user settings and normal saves retained',
                    source_and_validation_sha256={n[len(PREFIX):]: sha(b) for n,b in files.items() if n.startswith(PREFIX+'source/')})
    files[PREFIX+'manifest.json'] = js(manifest)
    files[PREFIX+'SHA256SUMS'] = ''.join(sha(b)+'  '+n[len(PREFIX):]+'\n' for n,b in sorted(files.items()) if n.startswith(PREFIX)).encode()
    files['SHA256SUMS'] = ''.join(sha(b)+'  '+n+'\n' for n,b in sorted(files.items())).encode()
    return files, modes, provenance


def audit(files):
    for n, b in files.items():
        content_audit(n, b)
        if n.lower().endswith(('.cfg', '.map')):
            need(n == PREFIX+'NDS_speed.cfg' and b == b'NDS-SpeedHacks-v1\n5\n', 'Unexpected settings file')
    for root, sums in (('', 'SHA256SUMS'), (PREFIX, PREFIX+'SHA256SUMS')):
        entries = {}
        for line in files[sums].decode().splitlines():
            digest, n = line.split('  ', 1)
            need(n not in entries and safe(n), 'Invalid checksum entry')
            entries[n] = digest
        need(set(entries) == {n[len(root):] for n in files if n.startswith(root) and n != sums}, 'Incomplete checksums')
        for n, digest in entries.items():
            need(sha(files[root+n]) == digest, 'Checksum mismatch: '+n)
    m = json.loads(files[PREFIX+'manifest.json'])
    for group in ('automatic_movie_files', 'source_and_validation_sha256'):
        for n, digest in m[group].items():
            need(sha(files[PREFIX+n]) == digest, 'Manifest hash mismatch: '+n)
    for n, digest in PINS.items():
        need(sha(files[PREFIX+n]) == digest, 'Runtime mismatch: '+n)
    need(b'/media/fat/Scripts/.NDS_Standalone/auto_movies.py' in files['Scripts/NDS4MiSTer.sh'], 'Wrong launcher')
    need(sha(files['Scripts/NDS4MiSTer.sh']) == m['launcher_sha256'], 'Launcher checksum')
    constants = {n.targets[0].id: ast.literal_eval(n.value) for n in ast.parse(files[PREFIX+'supervisor.py']).body if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id.startswith('EXPECTED_')}
    for constant, n in {'EXPECTED_CORE':'NDS_Standalone.rbf', 'EXPECTED_HELPER':'support/nds_hybrid_3d_service', 'EXPECTED_CLOCK':'clock_control.py', 'EXPECTED_KICKSTART':'Kickstart.sh', 'EXPECTED_WC':'support/nds_mem_wc.ko', 'EXPECTED_WC_618':'support/modules/6.18.38-MiSTer/nds_mem_wc.ko'}.items():
        need(constants[constant] == sha(files[PREFIX+n]), 'Supervisor pin mismatch: '+n)
    need(constants['EXPECTED_SPEED_ENV'] == m['runtime_environment'], 'Runtime environment metadata differs')
    for p in json.loads(files[PREFIX+'fmv/profiles.json'])['profiles']:
        for stub in p['stubs']:
            need(sha(files[PREFIX+'fmv/guest/'+stub['file']]) == stub['sha256'], 'Movie hook mismatch')
    sentinels = {PREFIX+'NDS_v1.CFG':b'display', PREFIX+'NDS_rtc.cfg':b'clock', PREFIX+'NDS_stick.cfg':b'range', PREFIX+'inputs/pad.map':b'buttons', 'saves/NDS/test.sav':b'progress', 'config/NDS_storage.cfg':b'folder', 'MiSTer.ini':b'video'}
    upgraded = dict(sentinels); upgraded.update(files)
    need(all(upgraded[n] == b for n,b in sentinels.items()), 'Upgrade overwrites user files')
    return dict(status='passed', files=len(files), runtime_pins=PINS,
                checksums='complete', nested_source_audit='passed',
                upgrade_preserves_settings_and_saves=True, publication_performed=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--beta-zip', type=Path)
    parser.add_argument('--out-dir', type=Path)
    parser.add_argument('--audit', type=Path)
    args = parser.parse_args()
    if args.audit:
        files, _ = read_zip(args.audit)
        print(json.dumps(audit(files), indent=2)); return
    need(args.beta_zip is not None and args.out_dir is not None, '--beta-zip and --out-dir required')
    files, modes, provenance = assemble(args.beta_zip)
    result = audit(files)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    archive = args.out_dir/('NDS4MiSTer_'+VERSION+'_Standalone.zip')
    need(not archive.exists(), 'Release archive already exists')
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name, body in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026,10,25,0,0,0))
            info.create_system = 3; info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | modes.get(name, 0o644)) << 16
            z.writestr(info, body)
    reloaded, _ = read_zip(archive)
    audit(reloaded)
    digest = sha(archive.read_bytes())
    archive.with_suffix('.zip.sha256').write_text(digest+'  '+archive.name+'\n')
    result.update(archive=archive.name, sha256=digest, bytes=archive.stat().st_size, provenance=provenance)
    (args.out_dir/'RC11_PACKAGE_VALIDATION.json').write_bytes(js(result))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
