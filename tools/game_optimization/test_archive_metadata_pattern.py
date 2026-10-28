"""Structural matches flag research candidates, never safe byte patches."""
import struct
import unittest

from scan_guest_patterns import scan_thumb_file_metadata


def blx(at, target):
    delta = target - ((at + 4) & ~3)
    assert delta % 4 == 0 and -(1 << 22) <= delta < (1 << 22)
    return struct.pack('<HH', 0xf000 | ((delta >> 12) & 0x7ff),
                       0xe800 | ((delta >> 1) & 0x7ff))


def fixture(base=0x1000, file_offset=24, value_offset=20):
    return (struct.pack('<3H', 0xa800 | (file_offset // 4), 0x210c, 0x2200) +
            blx(base + 6, base + 0x1000) +
            struct.pack('<3H', 0xa800 | (file_offset // 4),
                        0xa900 | (value_offset // 4), 0x2202) +
            blx(base + 16, base + 0x2000))


class ArchiveMetadataPatternTests(unittest.TestCase):
    def test_relocation_and_local_layout(self):
        for base, file_offset, value_offset in [(0x1000, 24, 20), (0x8000, 16, 12)]:
            with self.subTest(base=base):
                found = scan_thumb_file_metadata(fixture(base, file_offset, value_offset), base)
                self.assertEqual(len(found), 1)
                roles = found[0]['roles']
                self.assertEqual(roles['file_stack_offset'], file_offset)
                self.assertEqual(roles['value_stack_offset'], value_offset)
                self.assertEqual(roles['seek_target'], hex(base + 0x1000))
                self.assertEqual(roles['read_target'], hex(base + 0x2000))
                self.assertIn('No NARC/SDK identity', roles['required_proof'])

    def test_near_matches_and_truncation_are_rejected(self):
        original = fixture()
        for offset, value in [(0, 0xab06), (2, 0x210d), (4, 0x2201),
                              (10, 0xa807), (12, 0xa906), (14, 0x2204),
                              (6, 0xe000), (16, 0x4770)]:
            with self.subTest(offset=offset, value=hex(value)):
                changed = bytearray(original)
                struct.pack_into('<H', changed, offset, value)
                self.assertFalse(scan_thumb_file_metadata(changed, 0x1000))
        for length in range(20):
            self.assertFalse(scan_thumb_file_metadata(original[:length], 0x1000))
        changed = original[:16] + blx(0x1010, 0x2000)
        self.assertFalse(scan_thumb_file_metadata(changed, 0x1000))


if __name__ == '__main__':
    unittest.main()
