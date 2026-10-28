import unittest
from summarize_geometry_trace import summarize


class GeometrySummaryTest(unittest.TestCase):
    def rows(self):
        result = []
        for kind, a, b, dma in [('command', 0x20, 1, 0), ('command', 0x50, 0, 0),
                               ('command', 0x29, 7, 0), ('command', 0x50, 0, 0),
                               ('command', 0x29, 7, 1), ('command', 0x50, 0, 0),
                               ('frame', 12, 3, 0), ('command', 0x20, 2, 0)]:
            i = len(result)
            result.append(dict(ordinal=str(i), kind=kind, replay_frame='100', core_frame='101',
                               timestamp=str(i), a=hex(a), b=hex(b), c='0',
                               dma_executing_mask=hex(dma), last_profile_valid='1',
                               last_profile_pc='2000000', last_profile_opcode='e5801000', lr='2001004'))
        return result

    def test_partial_edges_and_dma_attribution(self):
        d = summarize(self.rows(), 100, 101)
        self.assertEqual((d['complete_swap_intervals'], d['adjacent_identical_swap_intervals']), (2, 1))
        self.assertEqual((d['excluded_leading_parameter_packets'], d['excluded_trailing_parameter_packets']), (2, 1))
        self.assertEqual((d['dma_parameter_packets'], d['cpu_context_parameter_packets']), (1, 6))
        self.assertEqual(d['state_assignment_recurrence'][0]['same_as_previous_assignment'], 1)

    def test_corrupt_or_incomplete_captures_fail(self):
        for field, value in [('ordinal', '999'), ('timestamp', '-1'), ('replay_frame', '99'),
                             ('a', '100'), ('last_profile_valid', '2')]:
            rows = self.rows()
            rows[3][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                summarize(rows, 100, 101)
        with self.assertRaises(ValueError):
            summarize(self.rows()[:2], 100, 101)


if __name__ == '__main__':
    unittest.main()
