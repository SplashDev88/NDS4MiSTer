#!/usr/bin/env python3
import struct
import unittest

from analyze_frame_timeline import analyze, read_timeline


def fixture():
    rows = [[(100, 7, 6, 1, 42, 0, 1)],
            [(150, 7, 10, 1, 42, 1, 0), (300, 7, 11, 1, 42, 0, 0)],
            [(320, 7, 12, 2, 42, 0, 0), (400, 7, 13, 2, 42, 0, 0)]]
    raw = struct.pack('<6I', 0x314c5443, 1, 32, 3, 500, 0)
    for lane, records in enumerate(rows):
        raw += struct.pack('<5I', lane, len(records), 0, 0, len(records))
        raw += b''.join(struct.pack('<Q6I', *r) for r in records)
    return raw


class FrameTimelineTest(unittest.TestCase):
    def test_known_intervals(self):
        lanes, timestamp = read_timeline(fixture())
        result = analyze(lanes)
        self.assertEqual(timestamp, 500)
        self.assertEqual(result['counts']['complete_chains'], 1)
        self.assertEqual(result['intervals']['input_to_admission']['mean_us'], 50)
        self.assertEqual(result['intervals']['upload']['p50_us'], 80)
        self.assertEqual(result['upload_duration']['p50_us'], 80)
        self.assertEqual(result['intervals']['input_to_uploaded']['p50_us'], 300)
        self.assertEqual(analyze(lanes, start_us=151)['counts'], {})

    def test_incomplete_retention(self):
        lanes, _ = read_timeline(fixture())
        lanes[0]['records'].clear()
        result = analyze(lanes)
        self.assertEqual(result['counts']['incomplete_chain'], 1)
        self.assertEqual(result['intervals'], {})
        self.assertEqual(result['upload_duration']['p50_us'], 80)

    def test_session_separation(self):
        lanes, _ = read_timeline(fixture())
        for record in lanes[2]['records']:
            record['session'] = 8
        self.assertEqual(analyze(lanes)['counts']['incomplete_chain'], 1)

    def test_publication_spacing(self):
        lanes, _ = read_timeline(fixture())
        second = dict(lanes[2]['records'][-1], us=600, frame=43)
        third = dict(second, us=900, frame=44)
        lanes[2]['records'].extend([second, third])
        result = analyze(lanes)
        self.assertEqual(result['publication_spacing']['mean_us'], 250)
        self.assertEqual(result['publication_spacing']['count'], 2)
        self.assertIsNone(analyze(lanes, start_us=601)['publication_spacing'])

    def test_duplicate_and_reversed_events(self):
        lanes, _ = read_timeline(fixture())
        lanes[0]['records'].append(lanes[0]['records'][0])
        with self.assertRaises(ValueError):
            analyze(lanes)
        lanes, _ = read_timeline(fixture())
        lanes[2]['records'][1]['us'] = 200
        with self.assertRaises(ValueError):
            analyze(lanes)

    def test_bad_binary(self):
        for raw in (fixture()[:-1], fixture() + b'\0', b'BAD!' + fixture()[4:]):
            with self.assertRaises((ValueError, struct.error)):
                read_timeline(raw)


if __name__ == '__main__':
    unittest.main()
