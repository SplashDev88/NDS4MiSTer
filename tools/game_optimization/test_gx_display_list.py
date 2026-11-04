# SPDX-License-Identifier: GPL-3.0-or-later
import struct
import unittest
from inspect_gx_display_list import analyze,commands

class DisplayListTests(unittest.TestCase):
    def test_unknown_state_is_not_a_partial_coordinate_match(self):
        # One full vertex followed by NOPs; no inherited state is assumed.
        data=bytes([0x23,0,0,0])+struct.pack('<II',0x00020001,3)
        self.assertEqual(list(commands(data)),[(0x23,(0x00020001,3)),(0,()),(0,()),(0,())])
        result=analyze(data)
        self.assertEqual(result['vtx16'],1)
        self.assertFalse(any(result.get(k,0) for k in ('partial_exact','delta_exact','vtx10_exact')))

    def test_partial_and_signed_wrapped_delta_leads(self):
        # Full vertex (65535,1200,2400), then a same-Z vertex, then a short
        # signed delta that crosses the 16-bit boundary on X.
        data=bytes([0x23,0x23,0x23,0])+struct.pack('<6I',
             (1200<<16)|65535,2400,(2200<<16)|65000,2400,(2201<<16)|65500,2401)
        result=analyze(data)
        self.assertEqual(result['partial_exact'],1)
        self.assertEqual(result['delta_exact'],1)

    def test_vtx10_exact_negative_coordinates(self):
        data=bytes([0x23,0,0,0])+struct.pack('<II',(0x8000<<16)|0xffc0,0x40)
        self.assertEqual(analyze(data)['vtx10_exact'],1)

    def test_existing_partial_command_updates_only_its_axes(self):
        data=bytes([0x24,0x25,0x23,0])+struct.pack('<4I',0,0x00020001,0x07d003e8,0)
        self.assertEqual(analyze(data)['partial_exact'],1)

    def test_malformed_streams_fail_closed(self):
        for data in [b'\0',bytes([0xff,0,0,0]),bytes([0x23,0,0,0])+b'\0'*4]:
            with self.assertRaises(ValueError):list(commands(data))

if __name__=='__main__':unittest.main()
