#!/usr/bin/env python3
"""Check complete-state keys and entry/exit integrity, not just source pointers."""
import copy
import unittest
from analyze_memory_recurrence import analyze, pair_events


class RecurrenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = dict(cpu=0, entry_pc='0x1000', exit_pc='0x1004',
                            register_deltas=[dict(register=13, delta=-4)],
                            output_addresses=[dict(span=0, entry_register=1)],
                            input_spans=[0, 1], output_spans=[0], key_registers=[2],
                            source_span=0, selected_frames=[1, 4])
        self.events = []
        for n, (state, output) in enumerate([(b'a', b'A'), (b'b', b'B'), (b'a', b'A'), (b'a', b'X')]):
            regs = [0]*16
            regs[1], regs[2], regs[13] = 0x02000200, 256, 0x02000400
            self.events.append(dict(cpu=0, pc=0x1000, frame=n, regs=tuple(regs),
                                    spans=[(0x02000100, b'source'), (0x02000300, state)]))
            regs[13] -= 4
            self.events.append(dict(cpu=0, pc=0x1004, frame=n, regs=tuple(regs),
                                    spans=[(0x02000200, output)]))

    def test_state_key_and_output_conflict(self):
        result = analyze(self.events, self.fixture)
        full = result['full_route']
        self.assertEqual(full['unique_source_contents'], 1)
        self.assertEqual(full['unique_complete_inputs'], 2)
        self.assertEqual(full['exact_reuse_calls'], 2)
        self.assertEqual(full['repeated_inputs_with_different_outputs'], 1)
        self.assertEqual(full['lru_hits_by_entry_capacity']['1'], 1)
        self.assertEqual(full['lru_hits_by_entry_capacity']['2'], 2)
        self.assertEqual(result['selected_window']['exact_reuse_calls'], 1)
        self.assertEqual(result['selected_window_hits_with_prior_route_history'], 2)

    def test_call_integrity(self):
        for change in ['cpu', 'pc', 'stack', 'output', 'unfinished', 'nested']:
            events = copy.deepcopy(self.events)
            if change == 'cpu':
                events[1]['cpu'] = 1
            elif change == 'pc':
                events[1]['pc'] = 0x1008
            elif change == 'stack':
                events[1]['regs'] = events[0]['regs']
            elif change == 'output':
                events[1]['spans'][0] = (0x02000204, b'A')
            elif change == 'unfinished':
                events.pop()
            else:
                events.insert(1, events[0])
            with self.subTest(change=change), self.assertRaises(ValueError):
                pair_events(events, self.fixture)


if __name__ == '__main__':
    unittest.main()
