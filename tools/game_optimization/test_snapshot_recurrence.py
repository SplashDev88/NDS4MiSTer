import unittest
from analyze_memory_recurrence import snapshot_recurrence


class SnapshotRecurrenceTests(unittest.TestCase):
    fixture = dict(cpu=0, pc='0x100', span=0, payload_bytes=6, key_registers=[1, 9])

    def event(self, frame, offset, callback, data, pc=0x100):
        regs = [0]*16; regs[1] = offset; regs[9] = callback
        return dict(cpu=0, pc=pc, frame=frame, regs=regs, spans=[(0x2000000+offset, data)])

    def test_interleaved_destinations_and_callbacks_have_separate_history(self):
        rows = [self.event(0, 0, 1, b'abcdef00'), self.event(0, 8, 1, b'abcdef00'),
                self.event(1, 0, 2, b'abcdef00'), self.event(1, 0, 1, b'abcdef11'),
                self.event(1, 8, 1, b'abcdeF00'), self.event(1, 0, 1, b'abcdef11')]
        result = snapshot_recurrence(rows, self.fixture)
        self.assertEqual(result['distinct_keys'], 3)
        self.assertEqual(result['prior_key_comparisons'], 3)
        self.assertEqual(result['repeated_payloads'], 2)
        self.assertEqual(result['repeated_within_same_frame'], 1)
        self.assertEqual(result['repeated_with_different_excluded_suffix'], 1)
        self.assertEqual(result['observed_payload_bytes'], 36)

    def test_unrelated_sites_do_not_replace_selected_history(self):
        rows = [self.event(0, 0, 1, b'abcdef'),
                self.event(1, 0, 1, b'xxxxxx', pc=0x200),
                self.event(2, 0, 1, b'abcdef')]
        result = snapshot_recurrence(rows, self.fixture)
        self.assertEqual(result['snapshots'], 2)
        self.assertEqual(result['repeated_payloads'], 1)

    def test_missing_short_and_empty_snapshots_are_rejected(self):
        with self.assertRaises(ValueError): snapshot_recurrence([], self.fixture)
        with self.assertRaises(ValueError):
            snapshot_recurrence([self.event(0, 0, 1, b'short')], self.fixture)
        bad = self.event(0, 0, 1, b'abcdef'); bad['spans'] = []
        with self.assertRaises(ValueError): snapshot_recurrence([bad], self.fixture)


if __name__ == '__main__':
    unittest.main()
