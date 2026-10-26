# SPDX-License-Identifier: GPL-3.0-or-later
import os
import struct
import unittest
from unittest import mock
from load_progress import LoadProgress
import test_image_cache
import test_stream_load


def without_progress(wire):
    """Decode records, never interpret payload bytes as progress metadata."""
    output, values = bytearray(), []
    at = 0
    while at < len(wire):
        header = wire[at:at+16]
        size, length, operation = struct.unpack('<Qii', header)
        at += 16
        if operation == 13:
            assert length == 0 and 0 <= size <= 9900
            values.append(size)
        else:
            output.extend(header)
            if operation == 10:
                output.extend(wire[at:at+length])
                at += length
    assert at == len(wire) and values == sorted(values)
    return bytes(output), values


class LoadingProgressTests(unittest.TestCase):
    def fixture(self, kind):
        fixture = kind()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        return fixture

    def test_cold_hit_recovery_fallback_keep_identical_cartridge_bytes(self):
        fixture = self.fixture(test_image_cache.ImageCacheTests)
        expected = b''.join(fixture.assemble(fixture.source, fixture.profile).blocks())
        with mock.patch.dict(os.environ, {'NDS_ROM_LOAD_PROGRESS': '1'}):
            for attempt in range(4):
                if attempt == 2:
                    path = next(fixture.root.glob('*.data'))
                    data = bytearray(path.read_bytes()); data[12] ^= 1; path.write_bytes(data)
                wire = fixture.run_cache()
                stripped, values = without_progress(wire)
                self.assertEqual(fixture.decode(stripped), expected)
                self.assertEqual(values[0], 0)
                self.assertEqual(values[-1], 9900)
                self.assertGreater(len(values), 2)
            stripped, values = without_progress(fixture.run_cache(
                profile=dict(fixture.profile, source_sha256='0'*64)))
            self.assertEqual(fixture.decode(stripped), fixture.raw)
            self.assertEqual(values[-1], 9900)

    def test_compacted_and_disabled_cache_work_before_completion(self):
        fixture = self.fixture(test_stream_load.StreamTests)
        expected = b''.join(fixture.assembled(fixture.source, fixture.profile).blocks())
        with mock.patch.dict(os.environ, {'NDS_ROM_LOAD_PROGRESS': '1'}):
            stripped, values = without_progress(fixture.wire())
            self.assertEqual(fixture.decode(stripped), expected)
            self.assertIn(4500, values)
            self.assertEqual(values[-1], 9900)

    def test_old_hosts_receive_no_new_records(self):
        out = []
        with mock.patch.dict(os.environ, {'NDS_ROM_LOAD_PROGRESS': '0'}):
            p = LoadProgress(out.append)
            p.update(0, 9900)
        self.assertEqual(out, [])


if __name__ == '__main__':
    unittest.main()
