import unittest

from scan_guest_patterns import THUMB_EMPTY_TAIL_SIGNATURE, scan_thumb_empty_tail


class EmptyTailPatternTests(unittest.TestCase):
    def test_relocation_multiple_instances_and_byte_identity(self):
        body = THUMB_EMPTY_TAIL_SIGNATURE
        for base in [0x02000000, 0x02100002]:
            findings = scan_thumb_empty_tail(b'\0\0' + body + b'\0\0' + body, base)
            self.assertEqual([int(x['address'], 0) for x in findings],
                             [base+2, base+4+len(body)])
            self.assertTrue(all(bytes.fromhex(x['expect']) == body for x in findings))
            self.assertTrue(all(x['status'].startswith('static_candidate') for x in findings))

    def test_alignment_truncation_and_every_changed_byte_reject(self):
        body = THUMB_EMPTY_TAIL_SIGNATURE
        self.assertFalse(scan_thumb_empty_tail(body, 0x02000001))
        for length in range(len(body)):
            self.assertFalse(scan_thumb_empty_tail(body[:length], 0x02000000))
        for offset in range(len(body)):
            changed = bytearray(body); changed[offset] ^= 1
            self.assertFalse(scan_thumb_empty_tail(changed, 0x02000000))


if __name__ == '__main__':
    unittest.main()
