#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from arm9_pc_profile import collect_native


class NativeStreamTests(unittest.TestCase):
    def test_histogram_and_raw_state_preservation(self):
        meta=(0xb<<28)|(4<<24)|(19<<8)|255
        stream=f'NDS-PC-v1,7,2000000000,10000000,2,3\n1,33558540,{meta}\n1001,33558540,{meta+1}\n'
        with patch('arm9_pc_profile.subprocess.run',return_value=SimpleNamespace(stdout=stream)):
            d=collect_native(2,.0004,Path(__file__))
        self.assertEqual(d['session'],7)
        self.assertEqual(d['collector_cpu_seconds'],.01)
        self.assertEqual(d['missed_sequence_minimum'],3)
        self.assertEqual(d['flags'],{'4':2})
        self.assertEqual(d['per_frame']['19'],[[33558540,4,1]])
        self.assertEqual(d['per_frame']['20'],[[33558540,4,1]])

    def test_truncated_stream_is_rejected(self):
        with patch('arm9_pc_profile.subprocess.run',return_value=SimpleNamespace(stdout='NDS-PC-v1,7,1,1,2,0\n')):
            with self.assertRaises(RuntimeError):collect_native(2,.0004,Path(__file__))


if __name__=='__main__':unittest.main()
