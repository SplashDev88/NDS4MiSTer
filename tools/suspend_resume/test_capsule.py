#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import capsule


class CapsuleTests(unittest.TestCase):
    def setUp(self):
        self.identity = {'rom_sha256': '1' * 64, 'build_sha256': '2' * 64,
                         'component': 'arm9-branch-v1'}
        self.words = b'12345678\n' * 68
        self.encoded = capsule.encode(self.identity, self.words)

    def test_roundtrip_both_components(self):
        for component, count in capsule.WORD_COUNTS.items():
            identity = dict(self.identity, component=component)
            words = b'ABCDEF01\n' * count
            self.assertEqual(capsule.decode(capsule.encode(identity, words), identity), words)

    def test_mismatch_before_any_state_is_returned(self):
        for key, value in [('rom_sha256', '3' * 64), ('build_sha256', '4' * 64),
                           ('component', 'arm7-branch-v1')]:
            with self.assertRaises(capsule.InvalidCheckpoint):
                capsule.decode(self.encoded, dict(self.identity, **{key: value}))

    def test_truncation_every_boundary_and_trailing_bytes(self):
        for length in range(len(self.encoded)):
            with self.assertRaises(capsule.InvalidCheckpoint):
                capsule.decode(self.encoded[:length], self.identity)
        with self.assertRaises(capsule.InvalidCheckpoint):
            capsule.decode(self.encoded + b'x', self.identity)

    def test_bit_corruption_header_payload_digest(self):
        for offset in range(len(self.encoded)):
            bad = bytearray(self.encoded)
            bad[offset] ^= 1
            with self.assertRaises(capsule.InvalidCheckpoint):
                capsule.decode(bytes(bad), self.identity)

    def test_unknown_version_even_with_valid_checksum(self):
        bad = bytearray(self.encoded[:-32]); bad[len(capsule.MAGIC)-1] ^= 1
        with self.assertRaises(capsule.InvalidCheckpoint):
            capsule.decode(bytes(bad) + hashlib.sha256(bad).digest(), self.identity)

    def test_incomplete_and_console_state_refused(self):
        for words in [b'', self.words[:-9], self.words + b'00000000\n', self.words.lower() + b'x']:
            with self.assertRaises(capsule.InvalidCheckpoint):
                capsule.encode(self.identity, words)
        with self.assertRaises(capsule.InvalidCheckpoint):
            capsule.encode(dict(self.identity, component='whole-console'), self.words)

    def test_atomic_replace_failure_preserves_prior_slot(self):
        with tempfile.TemporaryDirectory() as folder:
            slot = Path(folder) / 'suspend.state'
            capsule.write_slot(slot, self.identity, self.words)
            with patch.object(capsule.os, 'replace', side_effect=OSError('injected write failure')):
                with self.assertRaises(OSError):
                    capsule.write_slot(slot, self.identity, b'87654321\n' * 68)
            self.assertEqual(capsule.read_slot(slot, self.identity), self.words)
            self.assertEqual(list(Path(folder).iterdir()), [slot])
            self.assertEqual(slot.stat().st_mode & 0o777, 0o600)

    def test_fsync_failure_before_commit_preserves_prior_slot(self):
        with tempfile.TemporaryDirectory() as folder:
            slot = Path(folder) / 'suspend.state'
            capsule.write_slot(slot, self.identity, self.words)
            before = slot.read_bytes()
            with patch.object(capsule.os, 'fsync', side_effect=OSError('injected fsync failure')):
                with self.assertRaises(OSError):
                    capsule.write_slot(slot, self.identity, b'87654321\n' * 68)
            self.assertEqual(slot.read_bytes(), before)
            self.assertEqual(list(Path(folder).iterdir()), [slot])

    def test_symlink_slot_does_not_modify_target(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'ordinary-save'
            target.write_bytes(b'protected')
            slot = Path(folder) / 'suspend.state'; slot.symlink_to(target)
            with self.assertRaises(capsule.InvalidCheckpoint):
                capsule.write_slot(slot, self.identity, self.words)
            self.assertEqual(target.read_bytes(), b'protected')


if __name__ == '__main__':
    unittest.main()
