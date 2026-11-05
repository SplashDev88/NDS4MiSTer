# SPDX-License-Identifier: GPL-3.0-or-later
import struct
import unittest
from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM
from scan_guest_patterns import conditional_signed_byte, scan


class SignedBytePatternTests(unittest.TestCase):
    def words(self, source, destination):
        d = destination
        return [0xe20000ff | source << 16 | d << 12,
                0xe1a00800 | d << 12 | d, 0xe1a00840 | d << 12 | d,
                0xe350007f | d << 16, 0xc3800cff | d << 16 | d << 12,
                0xc1a00800 | d << 12 | d, 0xc1a00840 | d << 12 | d,
                0xe1a00600 | d << 12 | d]

    def detect(self, words):
        md = Cs(CS_ARCH_ARM, CS_MODE_ARM)
        md.detail = True
        return conditional_signed_byte(list(md.disasm(struct.pack('<8I', *words), 0x2000000)))

    def test_renamed_and_overlapping_registers(self):
        for source, destination in [(4, 4), (1, 5), (12, 8)]:
            words = self.words(source, destination)
            result = self.detect(words)
            self.assertEqual(result['source'], f'r{source}')
            self.assertEqual(result['destination'], f'r{destination}')
            self.assertIn('conditional-signed-byte-to-fx12',
                          [x['pattern'] for x in scan(struct.pack('<8I', *words), 0x2000000)])

    def test_semantic_near_matches_are_rejected(self):
        for index, mask in [(0, 1), (1, 0x80), (2, 0x40), (3, 1),
                            (4, 0x10000000), (5, 0x00100000), (7, 0x80)]:
            words = self.words(4, 4)
            words[index] ^= mask
            self.assertIsNone(self.detect(words))
        self.assertIsNone(self.detect(self.words(13, 4)))


if __name__ == '__main__':
    unittest.main()
