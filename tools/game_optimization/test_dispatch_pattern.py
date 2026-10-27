#!/usr/bin/env python3
"""Structural admission checks; these do not qualify any game patch."""
import struct
import unittest

from scan_guest_patterns import scan


class DispatchPatternTests(unittest.TestCase):
    words = [0xe592c000, 0xe15c0001, 0x1a000003, 0xe5922004, 0xe12fff32,
             0xe1a04000, 0xea000003, 0xe28ee001, 0xe2822008, 0xe15e0003, 0xbafffff4]

    def findings(self, words):
        return [f for f in scan(struct.pack('<11I', *words), 0x1000)
                if f['pattern'] == 'linear-key-handler-dispatch']

    def test_shape_and_register_renaming(self):
        for words in [self.words,
                      [0xe5958000, 0xe1580007, 0x1a000003, 0xe5955004, 0xe12fff35,
                       0xe1a04000, 0xea000003, 0xe2899001, 0xe2855008, 0xe1590006, 0xbafffff4]]:
            with self.subTest(words=words):
                found = self.findings(words)
                self.assertEqual(len(found), 1)
                self.assertEqual(found[0]['bytes'], 44)
                self.assertIn('first-match', found[0]['roles']['required_proof'])

    def test_near_matches_are_rejected(self):
        mutations = [
            (0, 0xe592c004),  # key offset
            (0, 0xe5b2c000),  # writeback
            (1, 0xe15c0002),  # searched key aliases table pointer
            (2, 0x1a000002),  # wrong mismatch destination
            (2, 0x0a000003),  # wrong condition
            (3, 0xe5922008),  # handler offset
            (4, 0xe12fff33),  # wrong call register
            (6, 0xea000002),  # does not exit search
            (7, 0xe29ee001),  # flag-changing increment
            (7, 0xe28ee002),  # wrong index increment
            (8, 0xe2822004),  # wrong entry size
            (9, 0xe15e000e),  # count aliases index
            (10, 0xbafffff5), # wrong back edge
        ]
        for at, word in mutations:
            with self.subTest(at=at, word=hex(word)):
                changed = self.words.copy()
                changed[at] = word
                self.assertFalse(self.findings(changed))


if __name__ == '__main__':
    unittest.main()
