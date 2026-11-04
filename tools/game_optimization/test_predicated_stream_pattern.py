# SPDX-License-Identifier: GPL-3.0-or-later
import struct
import unittest
from capstone import Cs,CS_ARCH_ARM,CS_MODE_ARM
from scan_guest_patterns import predicated_fixed_destination_word_stream as detect

class PredicatedStreamTests(unittest.TestCase):
    def run_detector(self,words):
        md=Cs(CS_ARCH_ARM,CS_MODE_ARM);md.detail=True
        return detect(list(md.disasm(struct.pack('<%dI'%len(words),*words),0x2000000)))
    def test_sdk_shape_and_renamed_registers(self):
        for source,end,length,destination,data in [(0,12,2,1,2),(3,6,7,4,8)]:
            words=[0xe0800000|source<<16|end<<12|length,0xe1500000|source<<16|end,
                   0xb8b00000|source<<16|1<<data,0xb5800000|destination<<16|data<<12,
                   0xbafffffb,0xe12fff1e]
            result=self.run_detector(words)
            self.assertIsNotNone(result)
            self.assertEqual(result['destination'],f'r{destination}')
    def test_incrementing_destination_and_wrong_loop_are_not_this_pattern(self):
        original=[0xe080c002,0xe150000c,0xb8b00004,0xb5812000,0xbafffffb,0xe12fff1e]
        for index,value in [(3,0xb4812004),(4,0xbafffffa),(5,0xe12fff1c),(2,0xe8b00004),(0,0xe0801002)]:
            words=list(original);words[index]=value
            self.assertIsNone(self.run_detector(words))

if __name__=='__main__':unittest.main()
