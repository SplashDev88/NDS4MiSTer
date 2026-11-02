import unittest
from instrument_itcm_trace import instrument


def fixture():
    return '\n'.join(
        f'void ARMv5::DataWrite{s}(u32 addr, u{w} val)\n{{\n'
        f'        *(u{w}*)&ITCM[addr & (ITCMPhysicalSize - 1)] = val;\n'
        '        return;\n}'
        for s, w in [('8', 8), ('16', 16), ('32', 32), ('32S', 32)])


class ITCMTraceTests(unittest.TestCase):
    def test_four_stores_and_aliases(self):
        result = instrument(fixture())
        self.assertEqual(result.count('replay_ram_write(NDS,'), 4)
        self.assertEqual(result.count('0x01ff8000u | (addr & (ITCMPhysicalSize - 1))'), 4)
        for address in [0, 0x7fff, 0x8000, 0x01fffffc]:
            self.assertEqual(0x01ff8000 | (address & 0x7fff),
                             0x01ff8000 + address % 0x8000)

    def test_refuses_missing_duplicate_and_reinstrumented_sources(self):
        source = fixture()
        for bad in [source.replace('DataWrite32S', 'DifferentWrite'), source + source,
                    instrument(source), source.replace(' = val;', ' = 0;', 1)]:
            with self.subTest(source=bad[:40]), self.assertRaises(ValueError):
                instrument(bad)


if __name__ == '__main__':
    unittest.main()
