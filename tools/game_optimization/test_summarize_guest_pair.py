import hashlib
from pathlib import Path
import tempfile
import unittest

from summarize_guest_pair import normalize_checkpoint


class OverlayCheckpointTest(unittest.TestCase):
    def test_full_body_required_and_unknown_bytes_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'context.bin'
            body = bytes(range(64))
            path.write_bytes(body)
            digest = hashlib.sha256(body).hexdigest()
            patch = dict(target='arm9.overlay', overlay=7, overlay_ram='0x02000100',
                         addr='0x02000108', expect=body[8:16].hex(), replace='ff'*8,
                         overlay_sha256=digest)
            context = dict(id=7, base=patch['overlay_ram'], path=str(path), sha256=digest)
            records = [dict(overlay_context=context), dict(overlay_context=context)]
            before = bytearray(0x400000)
            before[256:320] = body
            after = before.copy()
            after[264:272] = b'\xff'*8
            normalized, ids = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(normalized, before)
            self.assertEqual(ids, ['original', 'replacement'])
            after[319] ^= 1
            normalized, ids = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(normalized, after)
            self.assertEqual(ids, ['original', 'unmatched'])
            self.assertNotEqual(normalized, before)
            absent = bytearray(0x400000)
            self.assertEqual(normalize_checkpoint(absent, absent, patch, records)[1], ['unmatched']*2)
            path.write_bytes(body[:-1] + b'\xff')
            with self.assertRaises(AssertionError):
                normalize_checkpoint(before, after, patch, records)

    def test_initial_code_still_strict(self):
        patch = dict(target='arm9.bin/main_loaded', addr='0x02000100', expect='11'*8, replace='22'*8)
        before = bytearray(0x400000)
        before[256:264] = b'\x11'*8
        after = before.copy()
        after[256:264] = b'\x22'*8
        self.assertEqual(normalize_checkpoint(before, after, patch, [])[0], before)
        after[256] = 0
        with self.assertRaises(AssertionError):
            normalize_checkpoint(before, after, patch, [])


if __name__ == '__main__':
    unittest.main()
