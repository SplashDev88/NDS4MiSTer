"""Guard against apparently successful replays that silently omit button events."""
import unittest

from validate_replay_inputs import validate


class ReplayInputsTests(unittest.TestCase):
    def test_numeric_format_and_blank_lines(self):
        result = validate(b'\n0 8 1\n  10\t20\t0xA0\r\n', 20)
        self.assertEqual(result['interval_count'], 2)
        self.assertEqual(result['intervals'][1], dict(first=10, last_exclusive=20, mask_hex='a0'))

    def test_comment_cannot_silently_hide_later_movement(self):
        with self.assertRaisesRegex(ValueError, 'Line 2'):
            validate(b'0 8 1\n# walk outdoors\n10 20 10\n', 20)

    def test_partial_or_extra_row_is_rejected(self):
        for data in (b'0 8\n', b'0 8 1 extra\n', b'0 8 1 # comment\n'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                validate(data, 20)

    def test_sign_hex_frame_and_non_ascii_are_rejected(self):
        for data in (b'-1 8 1', b'+0 8 1', b'0x10 20 1', b'0 8 \xff'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                validate(data, 20)

    def test_bounds_and_button_width(self):
        for data in (b'0 21 1', b'8 8 1', b'9 8 1', b'0 8 1000', b'0 4294967296 1'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                validate(data, 20)

    def test_invalid_frame_counts(self):
        for frames in (0, -1, 0x100000000):
            with self.subTest(frames=frames), self.assertRaises(ValueError):
                validate(b'', frames)

    def test_existing_overlap_and_zero_mask_semantics(self):
        result = validate(b'5 10 10\n0 8 80\n0 20 0\n', 20)
        self.assertEqual(result['interval_count'], 3)

    def test_idle_replay_is_valid(self):
        self.assertEqual(validate(b'\n', 20)['interval_count'], 0)


if __name__ == '__main__':
    unittest.main()
