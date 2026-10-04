#!/usr/bin/env python3
"""Offline release-audit controls; generated ZIPs exist only in temporary dirs."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, main, mock
import stat
import tempfile
import warnings
import zipfile

import audit_public_release as audit
import package_standalone_release as package


class ReleaseAudit(TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.zip = self.root / 'release.zip'
        self.sidecar = self.root / 'release.zip.sha256'
        self.hashes, self.environment = audit.standalone_contract()
        components = {}
        values = {}
        for option, name, constant in (
            ('core', 'NDS_Standalone.rbf', 'EXPECTED_CORE'),
            ('host', 'nds_standalone_host', None),
            ('helper', 'support/nds_hybrid_3d_service', 'EXPECTED_HELPER'),
            ('module', 'support/nds_mem_wc.ko', 'EXPECTED_WC'),
            ('module_618', 'support/modules/6.18.38-MiSTer/nds_mem_wc.ko', 'EXPECTED_WC_618'),
        ):
            path = self.root / option
            path.write_bytes(('synthetic offline ' + option).encode())
            digest = audit.sha256(path.read_bytes())
            self.hashes[audit.STANDALONE_PREFIX + name] = digest
            components[option] = path
            if constant:
                values[constant] = digest
        values['EXPECTED_KICKSTART'] = self.hashes[audit.STANDALONE_PREFIX + 'Kickstart.sh']
        values['EXPECTED_CLOCK'] = self.hashes[audit.STANDALONE_PREFIX + 'clock_control.py']
        values['EXPECTED_SPEED_ENV'] = self.environment
        docs = self.root / 'docs'; docs.mkdir()
        for name in ('README.md', 'RELEASE_NOTES.md', 'QUICK_START.txt'):
            (docs / name).write_text('Synthetic documentation for an offline audit test.\n')
        args = SimpleNamespace(**components, docs_dir=docs, source_revision='a'*40)
        # Independently create the fixture with the public packager. Only binary
        # pins are synthetic; real approved runtime/license bytes remain intact.
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
        with mock.patch.object(package, 'HOST_SHA', self.hashes[audit.STANDALONE_PREFIX+'nds_standalone_host']), \
             mock.patch.object(package.importlib.util, 'spec_from_file_location', return_value=spec), \
             mock.patch.object(package.importlib.util, 'module_from_spec', return_value=SimpleNamespace(**values)):
            self.files, self.executable, _ = package.collect(args)
        self.patch = mock.patch.object(audit, 'standalone_contract', return_value=(self.hashes, self.environment))
        self.patch.start(); self.addCleanup(self.patch.stop)

    def write(self, files=None, *, mode_overrides=None, extra=None, layout='standalone', sidecar=True):
        files = self.files if files is None else files
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.zip, 'w', zipfile.ZIP_DEFLATED) as z:
                for name, data in list(files.items()) + (extra or []):
                    info = zipfile.ZipInfo(name); info.create_system = 3
                    info.external_attr = (stat.S_IFREG | (0o755 if name in self.executable else 0o644)) << 16
                    if mode_overrides and name in mode_overrides:
                        info.external_attr = mode_overrides[name] << 16
                    z.writestr(info, data)
        self.sidecar.write_text(audit.sha256(self.zip.read_bytes())+'  '+self.zip.name+'\n')
        return audit.audit_zip(self.zip, self.sidecar if sidecar else None, layout)

    def resign_inner(self, files):
        prefix = audit.STANDALONE_PREFIX
        files[prefix+'SHA256SUMS'] = ''.join(
            audit.sha256(data)+'  '+name[len(prefix):]+'\n'
            for name,data in sorted(files.items()) if name.startswith(prefix) and name != prefix+'SHA256SUMS').encode()

    def test_public_packager_layout_passes_with_sidecar(self):
        self.assertEqual(len(self.files), 37)
        self.assertEqual(self.write(layout='auto'), [])

    def test_normal_layout_still_passes(self):
        files = {name:b'legacy public fixture\n' for name in audit.ROOT_FILES | audit.SUPPORT_FILES}
        files['_Console/NDS_20261003.rbf'] = b'normal core fixture'
        files['SHA256SUMS'] = ''.join(audit.sha256(data)+'  ./'+name+'\n'
            for name,data in sorted(files.items()) if name != 'SHA256SUMS').encode()
        self.assertEqual(self.write(files, layout='normal'), [])
        self.assertEqual(self.write(files, layout='auto', sidecar=False), [])
        files['Scripts/NDS_Support/nds_mem_wc.ko'] = b'incomplete module'
        self.assertTrue(any('incomplete WC' in x for x in self.write(files, layout='normal')))

    def test_outer_sidecar_required_and_checked(self):
        self.assertTrue(any('requires' in x for x in self.write(sidecar=False)))
        self.write(); self.sidecar.write_text('0'*64+'  '+self.zip.name+'\n')
        self.assertTrue(any('outer checksum' in x for x in audit.audit_zip(self.zip,self.sidecar)))

    def test_rehashed_runtime_and_license_tampering_rejected(self):
        for name in ('nds_standalone_host','supervisor.py','licenses/FreeBIOS.txt',
                     'clock_control.py','support/modules/6.18.38-MiSTer/nds_mem_wc.ko'):
            with self.subTest(name=name):
                files=dict(self.files);files[audit.STANDALONE_PREFIX+name]+=b'changed'
                self.resign_inner(files)
                self.assertTrue(any('approved standalone input mismatch' in x for x in self.write(files)))

    def test_internal_and_component_hashes_checked(self):
        for name in ('SHA256SUMS','support/nds_mem_wc.ko.sha256',
                     'support/modules/6.18.38-MiSTer/nds_mem_wc.ko.sha256'):
            with self.subTest(name=name):
                files=dict(self.files);files[audit.STANDALONE_PREFIX+name]=b'0'*64+b'  wrong\n'
                self.assertTrue(self.write(files))

    def test_rehashed_metadata_contract_rejected(self):
        for field,value in (('firmware_working_image','/media/fat/games/NDS/firmware.bin'),
                            ('hps_clock_khz',1200000),('user_settings_included',True)):
            with self.subTest(field=field):
                files=dict(self.files);name=audit.STANDALONE_PREFIX+'manifest.json'
                manifest=json.loads(files[name]);manifest[field]=value;files[name]=json.dumps(manifest).encode()
                self.resign_inner(files)
                self.assertTrue(any('manifest fields' in x for x in self.write(files)))

    def test_missing_approved_file_rejected(self):
        files=dict(self.files);del files[audit.STANDALONE_PREFIX+'licenses/FreeBIOS.txt'];self.resign_inner(files)
        self.assertTrue(any('missing required' in x for x in self.write(files)))

    def test_unsafe_extra_paths_and_user_files_rejected(self):
        for name in ('../escape','Scripts/./NDS4MiSTer.sh','Scripts\\NDS4MiSTer.sh',
                     'C:/escape','/absolute','Scripts/.NDS_Standalone/NDS_v1.CFG',
                     'Scripts/.NDS_Standalone/firmware.bin','Scripts/.NDS_Standalone/extra.txt'):
            with self.subTest(name=name):
                self.assertTrue(self.write(extra=[(name,b'forbidden')]))

    def test_duplicate_symlink_and_bad_mode_rejected(self):
        self.assertTrue(any('duplicate paths' in x for x in self.write(extra=[('README.md',b'duplicate')])))
        name='Scripts/NDS4MiSTer.sh'
        for mode in (stat.S_IFLNK|0o777,stat.S_IFIFO|0o644,stat.S_IFREG|0o644):
            with self.subTest(mode=mode):self.assertTrue(self.write(mode_overrides={name:mode}))

    def test_private_path_and_duplicate_manifest_key_rejected(self):
        files=dict(self.files);files['README.md']=b'private '+b'/Users/'+b'test/private/file'
        self.assertTrue(any('home path' in x for x in self.write(files)))
        files=dict(self.files);name=audit.STANDALONE_PREFIX+'manifest.json'
        files[name]=files[name].replace(b'{',b'{"version":"duplicate",',1);self.resign_inner(files)
        self.assertTrue(any('duplicate JSON key' in x for x in self.write(files)))
        files=dict(self.files);name=audit.STANDALONE_PREFIX+'SHA256SUMS'
        files[name]+=files[name].splitlines(True)[0]
        self.assertTrue(any('duplicate/unsafe SHA256SUMS' in x for x in self.write(files)))


if __name__ == '__main__':
    main()
