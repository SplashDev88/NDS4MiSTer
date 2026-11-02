"""Structural screening must reject near-matches with different effects."""
import struct
import unittest
from scan_guest_patterns import scan


def body(source=0, end=12, length=2, destination=1, data=2):
    return [0xe0800000 | source << 16 | end << 12 | length,
            0xe1500000 | source << 16 | end, 0xba000000, 0xea000000,
            0xe8b00000 | source << 16 | 1 << data, 0xba000000, 0xea000000,
            0xe5800000 | destination << 16 | data << 12, 0xbafffff7, 0xe12fff1e]


def matches(words):
    return [x for x in scan(struct.pack('<10I', *words), 0x02000000)
            if x['pattern'] == 'branch-heavy-fixed-destination-word-stream']


class WordStreamDetectorTests(unittest.TestCase):
    def test_register_renaming_and_separate_length_data(self):
        for roles in [(0, 12, 2, 1, 2), (4, 5, 6, 7, 8)]:
            with self.subTest(roles=roles):
                self.assertEqual(len(matches(body(*roles))), 1)

    def test_reject_changed_control_flow_flags_and_accesses(self):
        for at, xor in [(0, 1 << 20), (2, 1), (4, 1 << 21),
                        (4, 1 << 3), (7, 1), (7, 1 << 21),
                        (8, 1), (9, 1)]:
            with self.subTest(at=at, xor=xor):
                words = body(); words[at] ^= xor
                self.assertEqual(matches(words), [])

    def test_reject_aliased_control_registers_and_special_registers(self):
        for roles in [(0, 0, 2, 1, 2), (0, 12, 0, 1, 2),
                      (0, 12, 2, 1, 1), (0, 13, 2, 1, 2)]:
            with self.subTest(roles=roles):
                self.assertEqual(matches(body(*roles)), [])


if __name__ == '__main__':
    unittest.main()
