#!/usr/bin/env python3
"""Check collision/eviction accounting and the deliberately optimistic credits."""
import unittest
from estimate_boolean_cache_trace import estimate


class CacheTraceTests(unittest.TestCase):
    fixture = dict(cpu=0, entry_pc='0x1000', exit_pc='0x1004', register_deltas=[],
                   output_addresses=[], input_spans=[0,1], output_spans=[], output_registers=[0],
                   key_registers=[], source_span=0, capture_frames=[0,8],
                   baseline_return_entries={'0x1004':26}, nonhit_tail_entries=2, reused_prologue_entries=1)
    synthetic = dict(groups={kind:[dict(instruction_entries=count)] for kind,count in
                            [('hit',26),('cold',17),('unaligned',6)]+[('collision'+str(n),26) for n in range(4)]})

    def events(self, keys, aligns=None, values=None):
        result=[]
        for n,key in enumerate(keys):
            regs=[0]*16
            result.append(dict(cpu=0,pc=0x1000,frame=n,regs=tuple(regs),
                               spans=[(0x02000100,key[:8]),(0x02000200+(aligns or [0]*len(keys))[n],key[8:])]))
            regs[0]=(values or [0]*len(keys))[n]
            result.append(dict(cpu=0,pc=0x1004,frame=n,regs=tuple(regs),spans=[]))
        return result

    def test_cold_collision_eviction_hit(self):
        a=bytes(16);b=(512).to_bytes(4,'little')+bytes(12)
        result=estimate(self.events([a,b,a,a]),self.fixture,self.synthetic)
        self.assertEqual(result['groups'],{'cold':1,'collision0':2,'hit':1})
        self.assertEqual(result['original_instruction_entries'],104)
        self.assertEqual(result['optimistic_candidate_instruction_entries'],164)
        self.assertEqual(result['perfect_aligned_hit_instruction_entries'],104)

    def test_alignment_fallback_does_not_insert(self):
        result=estimate(self.events([bytes(16)]*2,[2,0]),self.fixture,self.synthetic)
        self.assertEqual(result['groups'],{'unaligned':1,'cold':1})
        self.assertEqual(result['optimistic_candidate_instruction_entries'],69)
        self.assertEqual(result['perfect_aligned_hit_instruction_entries'],55)

    def test_same_key_different_result_rejected(self):
        with self.assertRaises(ValueError):
            estimate(self.events([bytes(16)]*2,values=[0,1]),self.fixture,self.synthetic)

    def test_outside_capture_rejected(self):
        events=self.events([bytes(16)])
        events[0]['frame']=8
        with self.assertRaises(ValueError):
            estimate(events,self.fixture,self.synthetic)


if __name__=='__main__':
    unittest.main()
