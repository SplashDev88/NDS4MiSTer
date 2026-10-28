#!/usr/bin/env python3
"""Structural guards for carry-derived multiply predication; no game bytes."""
import struct
import unittest

from scan_guest_patterns import scan


def mla(dst, left, right, accumulator):
    return 0xe0200090 | dst << 16 | accumulator << 12 | right << 8 | left


def shape(zero=12, carry=3, accumulator=1, left=5, temp=0, source=4):
    return [0xe3a00000 | zero << 12,
            mla(accumulator, carry, temp, accumulator),
            0xe2a00000 | zero << 16 | carry << 12,
            0xe2400010 | source << 16 | temp << 12,
            mla(accumulator, carry, left, accumulator)]


class ZeroMultiplicandTests(unittest.TestCase):
    def findings(self, words, base=0x1000):
        raw = struct.pack('<' + 'I'*len(words), *words)
        return [f for f in scan(raw, base)
                if f['pattern'] == 'zero-multiplicand-predication']

    def test_shape_and_renaming(self):
        for words, carry, accumulator in [(shape(), 'r3', 'r1'),
                (shape(9, 8, 7, 6, 5, 4), 'r8', 'r7')]:
            found = self.findings(words)
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]['bytes'], 20)
            self.assertEqual(found[0]['roles']['carry'], carry)
            self.assertEqual(found[0]['roles']['accumulator'], accumulator)
            self.assertEqual(found[0]['roles']['candidate_address'], '0x1010')
            self.assertEqual(found[0]['roles']['condition'], 'cs')

    def test_other_multiply_operand_can_hold_carry(self):
        words = shape(); words[4] = mla(1, 5, 3, 1)
        self.assertEqual(len(self.findings(words)), 1)

    def test_changed_conditions_and_flags_rejected(self):
        for at in range(5):
            for word in [shape()[at] | 0x100000, shape()[at] & 0x0fffffff]:
                with self.subTest(at=at, word=hex(word)):
                    changed = shape(); changed[at] = word
                    self.assertFalse(self.findings(changed))

    def test_broken_dataflow_rejected(self):
        mutations = [(0, 0xe3a0c001),        # initial constant is not zero
                     (1, mla(12, 3, 0, 1)), # zero register overwritten
                     (1, mla(3, 3, 0, 1)),  # ARMv4 destination/source alias
                     (2, 0xe2ac3001),       # ADC adds a nonzero constant
                     (2, 0xe2ab3000),       # ADC reads another register
                     (3, 0xe2443010),       # carry-derived register overwritten
                     (4, mla(1, 3, 5, 2)),  # not self-accumulating
                     (4, mla(1, 2, 5, 1)),  # neither multiplicand is C
                     (4, mla(1, 1, 3, 1))]  # ARMv4 destination/source alias
        for at, word in mutations:
            with self.subTest(at=at, word=hex(word)):
                changed = shape(); changed[at] = word
                self.assertFalse(self.findings(changed))

    def test_subtract_value_is_not_game_specific(self):
        words = shape(); words[3] = 0xe2440040
        self.assertEqual(len(self.findings(words)), 1)

    def test_special_registers_and_indirect_control_rejected(self):
        for register in (13, 15):
            for field in ('zero', 'carry', 'accumulator', 'left', 'temp', 'source'):
                with self.subTest(register=register, field=field):
                    self.assertFalse(self.findings(shape(**{field: register})))
        words = shape(); words[3] = 0xe12fff1e
        self.assertFalse(self.findings(words))

    def test_truncated_and_unaligned_input(self):
        self.assertFalse(self.findings(shape()[:-1]))
        self.assertFalse(self.findings(shape(), 0x1001))


if __name__ == '__main__':
    unittest.main()
