#!/usr/bin/env python3
"""Check complete-state keys and entry/exit integrity, not just source pointers."""
import copy
import csv
from pathlib import Path
import tempfile
import unittest
from analyze_memory_recurrence import analyze, pair_events, arm_condition, read_events


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

    def test_arm_condition_truth_tables(self):
        masks = [0xf0f0, 0x0f0f, 0xcccc, 0x3333, 0xff00, 0x00ff, 0xaaaa, 0x5555,
                 0x0c0c, 0xf3f3, 0xaa55, 0x55aa, 0x0a05, 0xf5fa, 0xffff]
        for condition, mask in enumerate(masks):
            for flags in range(16):
                self.assertEqual(arm_condition(condition, flags << 28), bool(mask & (1 << flags)))
        with self.assertRaises(ValueError):
            arm_condition(15, 0)

    def test_conditional_returns_and_bounded_window(self):
        fixture = copy.deepcopy(self.fixture)
        fixture.pop('exit_pc')
        fixture.update(exit_pcs=['0x1004', '0x1008'], conditional_arm_exits=True,
                       capture_frames=[0, 1], selected_frames=[0, 1], output_spans=[],
                       output_registers=[0], output_addresses=[],
                       saved_entry_registers=[dict(span=0, offset=0, register=14)])
        events = copy.deepcopy(self.events[:2])
        events[1].update(mode='arm', opcode=0xd8bd8000, cpsr=0, spans=[(0x02000400, b'\0'*4)])
        events.append(copy.deepcopy(events[1]))
        events[2].update(pc=0x1008, opcode=0xe8bd8000)
        result = analyze(events, fixture)
        self.assertNotIn('full_route', result)
        self.assertEqual(result['captured_window']['calls'], 1)
        self.assertEqual(result['return_sites'], {'0x1008': 1})
        events[2]['spans'][0] = (0x02000400, b'\1\0\0\0')
        with self.assertRaises(ValueError):
            analyze(events, fixture)
        events[2]['spans'][0] = (0x02000400, b'\0'*4)
        events[1]['cpsr'] = 0x40000000
        with self.assertRaises(ValueError):
            analyze(events, fixture)
        events[1]['cpsr'] = 0
        events[0]['frame'] = 1
        with self.assertRaises(ValueError):
            analyze(events, fixture)

    def test_register_only_recurrence_without_invented_source(self):
        fixture = copy.deepcopy(self.fixture)
        fixture.update(source_span=None,input_spans=[],output_spans=[],output_addresses=[],
                       key_registers=[2],output_registers=[0])
        events=copy.deepcopy(self.events)
        for event in events:
            event['spans']=[(0,b'')]
        result=analyze(events,fixture)['full_route']
        self.assertEqual(result['calls'],4)
        self.assertEqual(result['unique_complete_inputs'],1)
        self.assertEqual(result['exact_reuse_calls'],3)
        self.assertEqual(result['source_snapshot_calls'],0)
        self.assertEqual(result['unique_source_contents'],0)
        self.assertEqual(result['unique_source_addresses'],0)

    def test_register_only_csv_requires_explicit_empty_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'trace.csv'
            row=dict(event=0,span=0,frame=1,cpu=1,pc='3800100',mode='arm',opcode='e92d4010',
                     cpsr='92',address='0',length='0',bytes='',space='regs',
                     **{f'r{i}':format(i,'x') for i in range(16)})
            def write(value):
                with path.open('w',newline='') as stream:
                    writer=csv.DictWriter(stream,fieldnames=value.keys());writer.writeheader();writer.writerow(value)
            write(row);events=read_events(path)
            self.assertEqual(events[0]['regs'],tuple(range(16)))
            self.assertEqual(events[0]['spans'],[(0,b'')])
            for mutation in [dict(address='1'),dict(length='1',bytes='00'),dict(space='main')]:
                with self.subTest(mutation=mutation):
                    write(dict(row,**mutation))
                    with self.assertRaises(ValueError):read_events(path)


if __name__ == '__main__':
    unittest.main()
