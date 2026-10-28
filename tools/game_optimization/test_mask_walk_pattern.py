#!/usr/bin/env python3
"""Adversarial structural detector checks; no game bytes or safe-patch claim."""
import struct
import unittest

from scan_guest_patterns import scan


class MaskWalkPatternTests(unittest.TestCase):
    # TST r0,#1; BEQ advance; STR r1,[r2,r3,LSL#2];
    # ADD r3,r3,#1; CMP r3,#16; LSR r0,r0,#1; BLT start.
    words = [0xe3100001, 0x0a000000, 0xe7821103,
             0xe2833001, 0xe3530010, 0xe1a000a0, 0xbafffff8]

    def findings(self, words, base=0x1000):
        raw = struct.pack('<'+'I'*len(words), *words)
        return [f for f in scan(raw, base)
                if f['pattern'] == 'fixed-width-sparse-bitmask-traversal']

    def test_shape_and_register_renaming(self):
        for words, mask, index in [(self.words, 'r0', 'r3'),
                ([0xe3150001, 0x0a000000, 0xe7876108,
                  0xe2888001, 0xe3580020, 0xe1a050a5, 0xbafffff8], 'r5', 'r8')]:
            found = self.findings(words)
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]['bytes'], 28)
            self.assertEqual(found[0]['roles']['mask'], mask)
            self.assertEqual(found[0]['roles']['index'], index)
            self.assertIn('high-bit', found[0]['roles']['required_proof'])

    def test_forward_body_branch(self):
        words = [0xe3100001, 0x0a000002, 0xe3510000, 0x0a000000,
                 0xe7821103, 0xe2833001, 0xe3530010, 0xe1a000a0, 0xbafffff6]
        self.assertEqual(len(self.findings(words)), 1)
        for branch in [0x0afffffc, 0x0a000001, 0xeb000000]:
            changed=words.copy();changed[3]=branch
            self.assertFalse(self.findings(changed))

    def test_near_matches_are_rejected(self):
        mutations = [(0,0xe3100002), (0,0xe3100104), (0,0x13100001),
                     (1,0x1a000000), (1,0x0affffff), (1,0x0a7fffff),
                     (2,0xe1a00001), (2,0xe1a03001), (2,0xe592f000),
                     (2,0xe12fff11), (2,0xe12fff31), (2,0xef000000),
                     (3,0xe2933001), (3,0xe2833002), (3,0xe2803001),
                     (4,0xe3530000), (4,0xe3530021), (4,0xe3500010),
                     (5,0xe1b000a0), (5,0xe1a000c0), (5,0xe1a000a1),
                     (6,0x1afffff8), (6,0xbafffff9)]
        for at,word in mutations:
            with self.subTest(at=at,word=hex(word)):
                changed=self.words.copy();changed[at]=word
                self.assertFalse(self.findings(changed))

    def test_truncated_and_unaligned_input(self):
        self.assertFalse(self.findings(self.words[:-1]))
        self.assertFalse(self.findings(self.words,0x1001))


if __name__ == '__main__':
    unittest.main()
