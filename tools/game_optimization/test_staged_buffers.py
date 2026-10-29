import copy
import hashlib
import unittest
from audit_staged_buffers import audit

class StagedBufferTests(unittest.TestCase):
    def setUp(self):
        code=b'owned'; guard={'span':2,'address':'0x200','sha256':hashlib.sha256(code).hexdigest()}
        self.fixture={'phases':['before','after'],'sites':[dict(pc=hex(pc),cpu=0,mode='thumb',opcode='0x1234',phase=phase,header_span=0,payload_span=1,code_guards=[guard]) for pc,phase in [(16,'before'),(18,'after')]],'instances':{'0x100':{'label':'owned instance','fields':[dict(name='field',address='0x300',count=2,width=1,stride=2)]}}}
        self.events=[]
        for frame in [1,2]:
            for pc,data in [(16,b'aXbY'),(18,b'zXbY')]:self.events.append(dict(pc=pc,cpu=0,mode='thumb',opcode=0x1234,frame=frame,regs=(0,)*16,spans=[(0x100,b'header'),(0x300,data),(0x200,code)]))
    def test_exact_fields_and_recurrence(self):
        r=audit(self.events,self.fixture)['instances']['0x100'];self.assertEqual(r['groups'],2);self.assertEqual(r['fields']['field']['unchanged_since_previous_upload'],2);self.assertEqual(r['changes']['before_to_after']['field']['changed_blocks'],2)
    def test_out_of_order_rejected(self):
        with self.assertRaisesRegex(ValueError,'Phase order'):audit(self.events[1:],self.fixture)
    def test_truncated_group_rejected(self):
        with self.assertRaisesRegex(ValueError,'Incomplete'):audit(self.events[:-1],self.fixture)
    def test_changed_code_rejected(self):
        e=copy.deepcopy(self.events);e[0]['spans'][2]=(0x200,b'wrong')
        with self.assertRaisesRegex(ValueError,'Code context'):audit(e,self.fixture)
    def test_field_outside_snapshot_rejected(self):
        f=copy.deepcopy(self.fixture);f['instances']['0x100']['fields'][0]['count']=3
        with self.assertRaisesRegex(ValueError,'Field outside'):audit(self.events,f)
    def test_unknown_instance_rejected(self):
        e=copy.deepcopy(self.events);e[0]['spans'][0]=(0x101,b'header')
        with self.assertRaisesRegex(ValueError,'Unknown instance'):audit(e,self.fixture)
    def test_unguarded_site_rejected(self):
        f=copy.deepcopy(self.fixture);f['sites'][0]['code_guards']=[]
        with self.assertRaisesRegex(ValueError,'Missing code guard'):audit(self.events,f)
    def test_duplicate_fields_rejected(self):
        f=copy.deepcopy(self.fixture);f['instances']['0x100']['fields']*=2
        with self.assertRaisesRegex(ValueError,'Ambiguous fields'):audit(self.events,f)
    def test_cross_frame_group_rejected(self):
        e=copy.deepcopy(self.events);e[1]['frame']=4
        with self.assertRaisesRegex(ValueError,'crosses frame'):audit(e,self.fixture)

if __name__=='__main__':unittest.main()
