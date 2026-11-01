"""Small synthetic control-flow regressions; no game code or ROM required."""
import struct
import unittest

from audit_regional_direct_flow import audit


class Memory:
    def __init__(self, base, bss, words):
        self.base, self.bss = base, (bss, bss + 0x1000)
        self.data = struct.pack('<' + 'I' * len(words), *words)

    def read(self, address, size):
        offset = address - self.base
        if not 0 <= offset <= len(self.data) - size:
            raise ValueError('unmapped synthetic memory')
        return self.data[offset:offset+size]

    def classify(self, value):
        if self.bss[0] <= value < self.bss[1]:
            return dict(kind='static_bss', offset=value-self.bss[0])
        return dict(kind='constant_or_unmapped', value=hex(value))


class DirectFlowTests(unittest.TestCase):
    def compare(self, a, b):
        return audit(a, b, [dict(reference=hex(a.base), candidate=hex(b.base), mode='arm')], 64)

    def pair(self, literal_offset=0x40):
        # cmp r0,#0; bxeq lr; ldr r0,[pc]; bx lr; pointer literal.
        prefix = [0xe3500000, 0x012fff1e, 0xe59f0000, 0xe12fff1e]
        return (Memory(0x02000000, 0x02100000, prefix+[0x02100040]),
                Memory(0x02010000, 0x02200000, prefix+[0x02200000+literal_offset]))

    def test_conditional_return_keeps_fallthrough_but_not_literal(self):
        a, b = self.pair()
        result = self.compare(a, b)
        self.assertEqual(result['instructions'], 4)
        self.assertFalse(result['issues'])
        self.assertFalse(result['unresolved_literals'])
        self.assertTrue(result['literal_words'][0]['same_bss_offset'])

    def test_changed_state_field_is_not_a_valid_relocation(self):
        a, b = self.pair(literal_offset=0x44)
        result = self.compare(a, b)
        self.assertEqual(len(result['unresolved_literals']), 1)

    def test_changed_nonbranch_instruction_is_rejected(self):
        a, b = self.pair()
        b.data = struct.pack('<I', 0xe3500001) + b.data[4:]
        self.assertTrue(self.compare(a, b)['issues'])

    def test_indirect_branch_is_not_assumed_to_return(self):
        a = Memory(0x02000000, 0x02100000, [0xe12fff10])  # bx r0
        b = Memory(0x02010000, 0x02200000, [0xe12fff10])
        self.assertTrue(self.compare(a, b)['issues'])

    def test_changed_direct_callee_is_followed_and_rejected(self):
        # push {lr}; bl entry+0x20; pop {pc}; padding; mov r0,#1; bx lr.
        words = [0xe52de004, 0xeb000005, 0xe49df004] + [0] * 5 + [0xe3a00001, 0xe12fff1e]
        a = Memory(0x02000000, 0x02100000, words)
        b = Memory(0x02010000, 0x02200000, words)
        self.assertFalse(self.compare(a, b)['issues'])
        words[1] = 0xeb000006  # skips the callee's first instruction
        b = Memory(0x02010000, 0x02200000, words)
        self.assertTrue(self.compare(a, b)['issues'])


if __name__ == '__main__':
    unittest.main()
