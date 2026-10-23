#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import unittest
from symbolize_arm9_profile import summarize, symbols


class SymbolizationTests(unittest.TestCase):
    def test_states_aggregate_and_reset_does_not_become_code(self):
        profile=dict(observed_samples=5,missed_sequence_minimum=2,samples=[
            [0,1,0x02001008,0,0], [1,1,0x02001008,4,1],
            [2,1,0x02001008,2,2], [3,1,0x02002004,1,3],
            [4,0,0,8,4]])
        names=symbols('arm = 0x02001000;\nthumb = 0x02002000 + 1;')
        report=summarize(profile,names,[(0x02001000,16,'arm'),(0x02002000,8,'thumb')])
        self.assertEqual(report['nonreset_samples'],4)
        self.assertEqual(report['missed_sequence_minimum'],2)
        a,b=report['top30']
        self.assertEqual((a['pc'],a['samples'],a['percent']),('0x02001000',3,75))
        self.assertEqual(a['states'],{0:1,4:1,2:1})
        self.assertEqual((b['pc'],b['symbol']),('0x02002000','thumb'))
        self.assertEqual(a['architectural_r15'],{'0x02001008':3})

    def test_missing_and_overlapping_extents_are_not_nearest_attributions(self):
        p=dict(observed_samples=1,missed_sequence_minimum=0,
               samples=[[0,1,0x02001028,0,0]])
        names={0x02001000:['nearby']}
        for bounds in ([],[(0x02001000,64,'a'),(0x02001020,8,'b')]):
            row=summarize(p,names,bounds)['top30'][0]
            self.assertEqual(row['mapping'],'unresolved')
            self.assertIsNone(row['offset'])
        row=summarize(p,names)['top30'][0]
        self.assertEqual(row['mapping'],'nearest preceding symbol, extent unknown')


if __name__=='__main__':unittest.main()
