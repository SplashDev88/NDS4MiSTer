import copy
import struct
import unittest

from audit_rom_transfer_trace import audit, validate_evidence


SOURCE = b'aaaabbbbccccdddd'
FIXTURE = dict(cpu=0, entry_pc='0x10', exit_pc='0x20', mode='arm',
               entry_opcode='0xe1a00000', exit_opcode='0xe1a01001',
               input_spans=[], output_spans=[0], source_span=0, key_registers=[2],
               register_deltas=[dict(register=n, delta=0) for n in [4, 5, 6, 13]],
               output_addresses=[dict(span=0, entry_register=5)],
               exit_register_values=[dict(register=12, value='0x1')],
               capture_frames=[0, 8], source_register=2, payload_span=0,
               context_register=6, transfer_bytes=4, minimum_source_offset=0,
               source_alignment=4, stable_spans=[dict(entry=1, exit=1)],
               span_word_checks=[dict(event='entry', span=0, offset=0,
                                     mask='0xffffffff', register=2),
                                 dict(event='entry', span=1, offset=0,
                                      mask='0xff', value='0x7')],
               masked_register_checks=[dict(event='exit', register=3, mask='0xff', value='0x1')])
REGIONS = [dict(group='whole', id='image', start=0, end=16),
           dict(group='parts', id='partial', start=1, end=3),
           dict(group='parts', id='second', start=4, end=8)]


def events():
    result = []
    for frame, offset in enumerate([0, 4, 0]):
        regs = [0] * 16
        regs[2], regs[4], regs[5], regs[6], regs[13] = offset, 0x2000, 0x1000, 0x3000, 0x4000
        context = struct.pack('<II', 7, 123)
        result.append(dict(frame=frame, cpu=0, pc=0x10, mode='arm', opcode=0xe1a00000,
                           cpsr=0, regs=tuple(regs),
                           spans=[(0x2000, struct.pack('<III', offset, 0x1000, 4)), (0x3000, context)]))
        regs[3], regs[12] = 1, 1
        result.append(dict(frame=frame + (frame == 2), cpu=0, pc=0x20, mode='arm',
                           opcode=0xe1a01001, cpsr=0, regs=tuple(regs),
                           spans=[(0x1000, SOURCE[offset:offset+4]), (0x3000, context)]))
    return result


class TransferAuditTest(unittest.TestCase):
    def test_exact_content_and_partial_regions(self):
        result = audit(events(), FIXTURE, SOURCE, REGIONS)
        self.assertEqual(result['matched_bytes'], 12)
        self.assertEqual(result['repeated_content_calls'], 1)
        self.assertEqual(result['frame_spanning_transfers'], 1)
        self.assertEqual(result['recurrence_by_source_offset']['lru_hits_by_entry_capacity']['1'], 0)
        self.assertEqual(result['recurrence_by_source_offset']['lru_hits_by_entry_capacity']['2'], 1)
        self.assertEqual(result['uncovered_bytes_by_group'], dict(whole=0, parts=4))
        self.assertEqual(result['region_classification']['parts']['partial'],
                         dict(transfer_participations=2, overlap_bytes=4, unique_source_offsets=1))

    def test_wrong_payload_and_destination(self):
        for span in [(0x1000, b'aaab'), (0x1004, b'aaaa'), (0x1000, b'aaa')]:
            with self.subTest(span=span):
                rows=events();rows[1]['spans'][0]=span
                with self.assertRaises(ValueError):audit(rows,FIXTURE,SOURCE,REGIONS)

    def test_pairing_and_frame_bounds(self):
        for rows in [events()[:-1], events()[1:], events()[::2], list(reversed(events()))]:
            with self.subTest(rows=rows):
                with self.assertRaises(ValueError):audit(rows,FIXTURE,SOURCE,REGIONS)
        rows=events();rows[-1]['frame']=8
        with self.assertRaises(ValueError):audit(rows,FIXTURE,SOURCE,REGIONS)

    def test_context_mode_cpu_opcode_and_guards(self):
        cases=[]
        rows=events();rows[1]['spans'][1]=(0x3000,b'badbytes');cases.append(rows)
        rows=events();rows[0]['mode']='thumb';cases.append(rows)
        rows=events();rows[0]['cpu']=1;cases.append(rows)
        rows=events();rows[0]['opcode']^=1;cases.append(rows)
        rows=events();regs=list(rows[1]['regs']);regs[3]=0;rows[1]['regs']=tuple(regs);cases.append(rows)
        rows=events();rows[0]['spans'][0]=(0x2000,b'\0'*12);rows[2]['spans'][0]=(0x2000,b'\0'*12);cases.append(rows)
        for rows in cases:
            with self.subTest(rows=rows):
                with self.assertRaises(ValueError):audit(rows,FIXTURE,SOURCE,REGIONS)

    def test_source_and_region_guards(self):
        for change in [dict(minimum_source_offset=4),dict(transfer_bytes=0),
                       dict(transfer_bytes=8),dict(source_alignment=8),
                       dict(source_alignment=0)]:
            with self.subTest(change=change):
                with self.assertRaises(ValueError):audit(events(),dict(FIXTURE,**change),SOURCE,REGIONS)
        for extra in [dict(group='whole',id='overlap',start=0,end=1),
                      dict(group='third',id='outside',start=0,end=17),
                      dict(group='whole',id='__uncovered_bytes__',start=0,end=1)]:
            with self.assertRaises(ValueError):audit(events(),FIXTURE,SOURCE,REGIONS+[extra])

    def test_failed_or_changed_evidence_rejected(self):
        status=dict(state='passed_replay_equivalence',mode='off',admission=dict(state='unchanged'),
                    output_file_equality=dict(audio=True,frames=True),differing_state_frames=dict(ram=0),
                    checkpoint_RAM_equal_after_exact_code_normalization=True,
                    outputs={'memory_watch.csv':'trace'},virtual_image_sha256='source')
        validate_evidence(status,'trace','source')
        for changed in [dict(state='failed'),dict(mode='on'),dict(admission=dict(state='applied')),
                        dict(output_file_equality={}),dict(output_file_equality=dict(audio=False)),
                        dict(differing_state_frames={}),dict(differing_state_frames=dict(ram=1)),
                        dict(checkpoint_RAM_equal_after_exact_code_normalization=False)]:
            with self.subTest(changed=changed):
                with self.assertRaises(ValueError):validate_evidence(dict(status,**changed),'trace','source')
        for digests in [('changed','source'),('trace','changed')]:
            with self.assertRaises(ValueError):validate_evidence(status,*digests)


if __name__ == '__main__':
    unittest.main()
