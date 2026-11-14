# SPDX-License-Identifier: GPL-3.0-only
"""Offline upgrades only: temporary SD cards, no MiSTer hardware."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import install_layout as layout


class Migration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / 'Scripts'
        self.kit = self.scripts / '.NDS'
        self.kit.mkdir(parents=True)

    def old(self, name='.NDS_Standalone'):
        p = self.scripts / name
        p.mkdir(exist_ok=True)
        return p

    def run_migration(self):
        return layout.migrate_legacy_settings(self.kit, self.root)

    def test_fresh_install_and_private_beta(self):
        self.assertTrue(self.run_migration()['complete'])
        self.assertEqual(list(self.kit.glob('NDS_*.cfg')), [])
        private = self.old('.NDS_RC15_Beta23_20261113')
        self.assertIsNone(layout.migrate_legacy_settings(private, self.root))
        self.assertEqual(list(private.iterdir()), [])

    def test_rc14_settings_clock_and_maps_copied_without_changing_originals(self):
        old = self.old()
        before = {}
        for name in layout.SETTINGS:
            before[name] = ('saved ' + name).encode()
            (old / name).write_bytes(before[name])
        (old / 'inputs').mkdir()
        before['inputs/NDS_input_test_v3.map'] = b'controller mapping'
        (old / 'inputs/NDS_input_test_v3.map').write_bytes(before['inputs/NDS_input_test_v3.map'])
        (old / 'nds_standalone_host').write_bytes(b'old executable')
        saves = self.root / 'saves/NDS'; saves.mkdir(parents=True)
        (saves / 'game.sav').write_bytes(b'original save')
        clock_time = (old / 'NDS_rtc.cfg').stat().st_mtime_ns
        result = self.run_migration()
        self.assertEqual(set(result['imported']), set(before))
        for name, data in before.items():
            self.assertEqual((old / name).read_bytes(), data)
            self.assertEqual((self.kit / name).read_bytes(), data)
        self.assertEqual((self.kit / 'NDS_rtc.cfg').stat().st_mtime_ns, clock_time)
        self.assertFalse((self.kit / 'nds_standalone_host').exists())
        self.assertEqual((saves / 'game.sav').read_bytes(), b'original save')

    def test_stable_settings_win_then_rc15_then_rc14(self):
        rc14, rc15 = self.old(), self.old('.NDS_RC15')
        (rc14 / 'NDS_rtc.cfg').write_bytes(b'rc14 clock')
        (rc15 / 'NDS_rtc.cfg').write_bytes(b'rc15 clock')
        (rc14 / 'NDS_touch.cfg').write_bytes(b'rc14 touch')
        (rc15 / 'NDS_graphics.cfg').write_bytes(b'rc15 display')
        (self.kit / 'NDS_graphics.cfg').write_bytes(b'stable display')
        self.run_migration()
        self.assertEqual((self.kit / 'NDS_rtc.cfg').read_bytes(), b'rc15 clock')
        self.assertEqual((self.kit / 'NDS_touch.cfg').read_bytes(), b'rc14 touch')
        self.assertEqual((self.kit / 'NDS_graphics.cfg').read_bytes(), b'stable display')

    def test_reset_or_deleted_settings_are_not_resurrected(self):
        old = self.old()
        (old / 'NDS_speed.cfg').write_bytes(b'old speed')
        self.run_migration()
        (self.kit / 'NDS_speed.cfg').unlink()
        receipt = (self.kit / layout.RECEIPT).read_bytes()
        self.run_migration()
        self.assertFalse((self.kit / 'NDS_speed.cfg').exists())
        self.assertEqual((self.kit / layout.RECEIPT).read_bytes(), receipt)

    def test_partial_import_can_resume_without_overwriting_existing_settings(self):
        old = self.old()
        (old / 'NDS_touch.cfg').write_bytes(b'touch')
        (old / 'NDS_rtc.cfg').write_bytes(b'clock')
        original = layout.write_new
        def fail_clock(path, *args):
            if path.name == 'NDS_rtc.cfg': raise OSError('simulated full disk')
            return original(path, *args)
        with patch.object(layout, 'write_new', side_effect=fail_clock):
            with self.assertRaises(OSError): self.run_migration()
        self.assertFalse((self.kit / layout.RECEIPT).exists())
        (self.kit / 'NDS_touch.cfg').write_bytes(b'keep newer value')
        self.run_migration()
        self.assertEqual((self.kit / 'NDS_touch.cfg').read_bytes(), b'keep newer value')
        self.assertEqual((self.kit / 'NDS_rtc.cfg').read_bytes(), b'clock')

    def test_symlink_and_oversized_source_rejected(self):
        old = self.old(); source = old / 'NDS_rtc.cfg'
        external = self.root / 'external'; external.write_bytes(b'not settings')
        source.symlink_to(external)
        with self.assertRaises(OSError): self.run_migration()
        source.unlink(); source.write_bytes(b'x' * (1024 * 1024 + 1))
        with self.assertRaises(ValueError): self.run_migration()
        self.assertFalse((self.kit / layout.RECEIPT).exists())

    def test_only_known_public_launchers_are_archived(self):
        source = self.scripts / 'NDS_RC15.sh'; source.write_bytes(b'known launcher')
        custom = self.scripts / 'NDS4MiSTer.sh'; custom.write_bytes(b'custom launcher')
        beta = self.scripts / 'NDS_RC15_Beta23.sh'; beta.write_bytes(b'private beta')
        known = hashlib.sha256(source.read_bytes()).hexdigest()
        with patch.dict(layout.LEGACY_LAUNCHERS, {'NDS_RC15.sh': known}):
            result = self.run_migration()
            self.run_migration()
        self.assertEqual(result['archived_launchers'], ['NDS_RC15.sh'])
        self.assertFalse(source.exists())
        self.assertEqual((self.kit / 'legacy-launchers' / (known[:12] + '-NDS_RC15.sh')).read_bytes(), b'known launcher')
        self.assertEqual(custom.read_bytes(), b'custom launcher')
        self.assertEqual(beta.read_bytes(), b'private beta')

    def test_target_input_directory_symlink_rejected(self):
        old = self.old(); (old / 'inputs').mkdir()
        (old / 'inputs/pad.map').write_bytes(b'mapping')
        external = self.root / 'elsewhere'; external.mkdir()
        (self.kit / 'inputs').symlink_to(external)
        with self.assertRaises(ValueError): self.run_migration()
        self.assertEqual(list(external.iterdir()), [])


class PackageSettings(unittest.TestCase):
    def test_mutable_preferences_not_pinned_but_defaults_are(self):
        with tempfile.TemporaryDirectory() as temporary:
            kit = Path(temporary)
            required = ['nds_standalone_host', 'support/nds_hybrid_3d_service',
                        'NDS_Standalone.rbf', 'supervisor.py', 'Kickstart.sh',
                        'auto_movies.py', 'fmv/stream.py', 'fmv/prepare.py',
                        'fmv/profiles.json', 'fmv/stream_load.py',
                        'fmv/prepared_cache.py', 'fmv/load_progress.py',
                        'install_layout.py', 'defaults/NDS_speed.cfg']
            for name in required:
                p = kit / name; p.parent.mkdir(exist_ok=True, parents=True)
                p.write_bytes(Path(__file__).with_name('auto_movies.py').read_bytes() if name == 'auto_movies.py' else b'package data')
            checks = {name: hashlib.sha256((kit / name).read_bytes()).hexdigest() for name in required}
            (kit / 'manifest.json').write_text(json.dumps({'automatic_movie_files': checks}))
            def validate():
                return subprocess.run([sys.executable, str(kit / 'auto_movies.py'), '--validate-only'], capture_output=True, text=True)
            self.assertEqual(validate().returncode, 0)
            (kit / 'NDS_speed.cfg').write_bytes(b'changed by Save settings')
            self.assertEqual(validate().returncode, 0)
            (kit / 'NDS_speed.cfg').unlink()
            self.assertEqual(validate().returncode, 0)
            (kit / 'defaults/NDS_speed.cfg').write_bytes(b'bad package')
            self.assertNotEqual(validate().returncode, 0)


if __name__ == '__main__': unittest.main()
