# SPDX-License-Identifier: GPL-3.0-only
"""Private scaled-HDMI launch recovery, including interrupted durable writes."""
from pathlib import Path
from unittest.mock import patch
import json
import tempfile
import unittest
import video_target as v


class ScaledBootstrap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.kit = self.root / 'kit'
        self.kit.mkdir()
        self.ini = self.root / 'MiSTer.ini'
        self.cfg = self.root / 'config/NDS_v1.CFG'
        self.cfg.parent.mkdir()
        self.original = b'[MiSTer]\r\nvideo_mode=0\r\n[NDS]\r\ndirect_video=1\r\n; keep me\r\n'
        self.ini.write_bytes(self.original)
        self.ini.chmod(0o640)
        self.cfg.write_bytes(bytes(range(16)))
        self.payload = b'\x20\x44' + bytes(range(2, 16))

    def enable(self, mode='1080p'):
        (self.kit / v.SCALED_PREFERENCE).write_text('NDS-ScaledHDMI-v1\n' + mode + '\n')

    def assert_restored(self):
        self.assertEqual(self.ini.read_bytes(), self.original)
        self.assertEqual(self.ini.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.cfg.read_bytes(), bytes(range(16)))
        self.assertFalse((self.kit / v.SCALED_JOURNAL).exists())
        self.assertFalse((self.kit / v.JOURNAL).exists())

    def test_ordinary_kit_does_not_change_ini(self):
        v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(self.ini.read_bytes(), self.original)
        self.assertFalse((self.kit / v.SCALED_JOURNAL).exists())
        v.restore_bootstrap(self.kit, self.root)
        self.assert_restored()

    def test_both_modes_preserve_every_original_byte_and_restore(self):
        for mode, number in [('1080p', b'8'), ('720p', b'0')]:
            self.enable(mode)
            v.stage_bootstrap(self.kit, self.root, self.payload)
            applied = self.ini.read_bytes()
            self.assertTrue(applied.startswith(self.original))
            final = applied.rsplit(b'[NDS]\r\n', 1)[1]
            self.assertEqual(final.splitlines(), [b'direct_video=0', b'video_mode=' + number,
                                                  b'video_mode_ntsc=' + number, b'video_mode_pal=' + number])
            self.assertTrue(v.restore_bootstrap(self.kit, self.root))
            self.assert_restored()
            self.assertFalse(v.restore_bootstrap(self.kit, self.root))

    def test_every_interrupted_write_recovers_exactly(self):
        self.enable()
        real = v.atomic_bytes
        targets = [self.kit / v.SCALED_JOURNAL, self.ini, self.kit / v.JOURNAL, self.cfg]
        for target in targets:
            for after_write in [False, True]:
                with self.subTest(target=target.name, after_write=after_write):
                    def interrupted(path, *args):
                        if path == target and not after_write:
                            raise OSError('simulated interruption')
                        real(path, *args)
                        if path == target:
                            raise OSError('simulated interruption')
                    with patch.object(v, 'atomic_bytes', side_effect=interrupted):
                        with self.assertRaises(OSError):
                            v.stage_bootstrap(self.kit, self.root, self.payload)
                    v.restore_bootstrap(self.kit, self.root)
                    self.assert_restored()

    def test_restored_ini_with_pending_journal_is_idempotent(self):
        self.enable()
        v.stage_bootstrap(self.kit, self.root, self.payload)
        self.ini.write_bytes(self.original)
        v.restore_bootstrap(self.kit, self.root)
        self.assert_restored()

    def test_external_edit_is_preserved_and_backup_retained(self):
        self.enable()
        v.stage_bootstrap(self.kit, self.root, self.payload)
        applied = self.ini.read_bytes()
        changed = applied + b'; external edit\n'
        self.ini.write_bytes(changed)
        with self.assertRaisesRegex(RuntimeError, 'changed during bootstrap'):
            v.restore_bootstrap(self.kit, self.root)
        self.assertEqual(self.ini.read_bytes(), changed)
        record = json.loads((self.kit / v.SCALED_JOURNAL).read_text())
        self.assertEqual(bytes.fromhex(record['original']), self.original)
        self.ini.write_bytes(applied)
        v.restore_bootstrap(self.kit, self.root)
        self.assert_restored()

    def test_missing_ini_is_removed_on_recovery(self):
        self.enable()
        self.ini.unlink()
        v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertIn(b'direct_video=0\n', self.ini.read_bytes())
        v.restore_bootstrap(self.kit, self.root)
        self.assertFalse(self.ini.exists())

    def test_invalid_preference_or_ini_is_not_overwritten(self):
        self.enable('future')
        with self.assertRaises(RuntimeError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assert_restored()
        self.enable()
        self.ini.write_bytes(b'bad\0ini')
        with self.assertRaises(RuntimeError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(self.ini.read_bytes(), b'bad\0ini')
        self.assertFalse((self.kit / v.SCALED_JOURNAL).exists())

    def test_symlink_is_not_followed(self):
        self.enable()
        target = self.root / 'real.ini'
        self.ini.rename(target)
        self.ini.symlink_to(target)
        with self.assertRaises(RuntimeError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(target.read_bytes(), self.original)
        self.assertTrue(self.ini.is_symlink())


if __name__ == '__main__': unittest.main()
