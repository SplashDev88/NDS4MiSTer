#!/usr/bin/env python3
"""Failure-path tests for the transfer census, independent of any game."""
import csv
import json
from pathlib import Path
import tempfile
import unittest

from audit_transfer_calls import audit, sha
from compare_replays import FILES


class CensusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        comparison = {}
        for name in FILES:
            path = self.root / name
            path.write_bytes(name.encode())
            comparison[name] = dict(equal=True, sha256=[sha(path), sha(path)])
        self.comparison = self.root / 'comparison.json'
        self.comparison.write_text(json.dumps(comparison))
        self.trace = self.root / 'memory_watch.csv'
        self.fixture = dict(comparison=str(self.comparison), comparison_sha256=sha(self.comparison),
                            window=[10, 20], cpu=0, mode='arm', stack_space='dtcm', stack_bytes=16,
                            regions=[dict(name='RAM', first='0x02000000', last_exclusive='0x02400000'),
                                     dict(name='port', first='0x04000000', last_exclusive='0x04000004')],
                            functions=[dict(id='stream', entry='0x02001000', exit='0x02001024',
                                            entry_opcode='0xe080c002', exit_opcode='0xe12fff1e',
                                            unit_bytes=4, source_advance=True, destination_fixed=True,
                                            counter_rule='source_plus_length',
                                            preserved_registers=[1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14])])
        self.rows = []
        for event, pc in enumerate([0x02001000, 0x02001024]):
            regs = [0] * 16
            regs[0:3] = [0x02010000 + event * 8, 0x04000000, 8 if event == 0 else 123]
            regs[12:16] = [0 if event == 0 else 0x02010008, 0x027e3000, 0x02002001, pc + 8]
            row = dict(event=event, span=0, frame=10 + event, cpu=0, pc=f'{pc:x}', mode='arm',
                       opcode='e080c002' if event == 0 else 'e12fff1e',
                       cpsr='1f' if event == 0 else '6000001f', address='27e3000', length=16,
                       bytes='00' * 16, space='dtcm')
            row.update({f'r{n}': f'{v:x}' for n, v in enumerate(regs)})
            self.rows.append(row)

    def run_audit(self):
        with self.trace.open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=self.rows[0].keys())
            writer.writeheader()
            writer.writerows(self.rows)
        self.fixture['trace_sha256'] = sha(self.trace)
        return audit(self.trace, self.fixture)

    def test_complete_cross_frame_call(self):
        result = self.run_audit()['functions']['stream']
        self.assertEqual((result['calls'], result['requested_bytes'], result['data_units'],
                          result['cross_frame_calls']), (1, 8, 2, 1))
        self.assertEqual(result['destination_regions'], {'port': 1})

    def test_mode_and_opcode(self):
        self.rows[1]['mode'] = 'thumb'
        with self.assertRaisesRegex(ValueError, 'Instruction/mode'):
            self.run_audit()
        self.rows[1]['mode'] = 'arm'
        self.rows[1]['opcode'] = 'e1a00000'
        with self.assertRaisesRegex(ValueError, 'Instruction/mode'):
            self.run_audit()

    def test_unfinished_call(self):
        self.rows.pop()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            self.run_audit()

    def test_changed_destination(self):
        self.rows[1]['r1'] = '4000004'
        with self.assertRaisesRegex(ValueError, 'Preserved register'):
            self.run_audit()

    def test_changed_stack(self):
        self.rows[1]['bytes'] = '01' + '00' * 15
        with self.assertRaisesRegex(ValueError, 'stack bytes'):
            self.run_audit()

    def test_reused_golden_comparison(self):
        (self.root / FILES[0]).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'different outputs'):
            self.run_audit()

    def test_event_order_and_window(self):
        self.rows[1]['event'] = 2
        with self.assertRaisesRegex(ValueError, 'Event/span'):
            self.run_audit()
        self.rows[1]['event'] = 1
        self.rows[1]['frame'] = 20
        with self.assertRaisesRegex(ValueError, 'window'):
            self.run_audit()


if __name__ == '__main__':
    unittest.main()
