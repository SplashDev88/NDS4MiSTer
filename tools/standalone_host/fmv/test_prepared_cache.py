# SPDX-License-Identifier: GPL-3.0-or-later
import json
import os
from pathlib import Path
import struct
from unittest import mock
from prepare import Source
from prepared_cache import cached_transfer, Store, Writer, cache_key, loader_identity
from stream_load import select_plan
from test_stream_load import StreamTests


class CacheTests(StreamTests):
    def setUp(self):
        super().setUp()
        self.root = Path(self.temp.name)/'cache'

    def cached(self, loader='fixture-v1', profile=None, emit=None):
        plan = select_plan(self.source, [profile or self.profile])
        pieces = []
        cached_transfer(self.source, plan, emit or (lambda b: pieces.append(bytes(b))),
                        root=self.root, loader=loader, assembler=self.assembled)
        return b''.join(pieces)

    def data(self):
        return next(self.root.glob('*.data'))

    def test_hit_matches_fresh_image_without_reading_original_payload(self):
        fresh = self.decode(self.cached())
        plan = select_plan(self.source, [self.profile])
        with mock.patch.object(self.source, 'read', side_effect=AssertionError('source payload reread')):
            pieces = []
            cached_transfer(self.source, plan, lambda b: pieces.append(bytes(b)), root=self.root,
                            loader='fixture-v1', assembler=self.assembled)
        self.assertEqual(self.decode(b''.join(pieces)), fresh)
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_corrupt_payload_rebuilds_and_overwrites_every_provisional_byte(self):
        expected = self.decode(self.cached())
        p = self.data()
        data = bytearray(p.read_bytes())
        # Also redirect this validly bounded write into an otherwise empty hole.
        struct.pack_into('<Q', data, 0, 3000)
        data[12] ^= 1
        p.write_bytes(data)
        self.assertEqual(self.decode(self.cached()), expected)
        self.assertEqual(self.decode(self.cached()), expected)

    def test_invalid_record_bounds_rebuild_without_booting_partial_image(self):
        expected = self.decode(self.cached())
        p = self.data(); data = bytearray(p.read_bytes())
        struct.pack_into('<Q', data, 0, 999999)
        p.write_bytes(data)
        self.assertEqual(self.decode(self.cached()), expected)

    def test_truncated_or_missing_metadata_is_a_miss(self):
        expected = self.decode(self.cached())
        self.data().write_bytes(b'partial')
        self.assertEqual(self.decode(self.cached()), expected)
        self.data().with_suffix('.json').write_text('{')
        self.assertEqual(self.decode(self.cached()), expected)

    def test_source_metadata_and_loader_changes_invalidate(self):
        expected = self.decode(self.cached())
        first = self.data().name
        os.utime(self.path, ns=(self.source.stat.st_atime_ns, self.source.stat.st_mtime_ns+1000000000))
        self.source = Source(self.fd)
        self.assertEqual(self.decode(self.cached()), expected)
        self.assertEqual(len(list(self.root.glob('*.data'))), 2)
        self.assertEqual(self.decode(self.cached(loader='fixture-v2')), expected)
        self.assertEqual(len(list(self.root.glob('*.data'))), 3)
        self.assertIn(first, [p.name for p in self.root.glob('*.data')])

    def test_failed_original_hash_never_creates_cache(self):
        wrong = dict(self.profile, source_sha256='0'*64)
        self.assertEqual(self.decode(self.cached(profile=wrong)), self.raw)
        self.assertEqual(list(self.root.glob('*.data')), [])
        self.assertEqual(list(self.root.glob('*.json')), [])

    def test_source_mutation_during_hit_has_no_completion(self):
        self.cached(); pieces = []
        def emit(b):
            pieces.append(bytes(b))
            if len(pieces) == 1:
                self.path.write_bytes(b'short')
        with self.assertRaises(ValueError):
            self.cached(emit=emit)
        self.assertNotEqual(pieces[-1], struct.pack('<Qii', len(self.raw), 0, 8))

    def test_unavailable_full_and_disabled_cache_still_load(self):
        expected = b''.join(self.assembled(self.source, self.profile).blocks())
        with mock.patch.object(Store, 'reserve', return_value=False):
            self.assertEqual(self.decode(self.cached()), expected)
        self.assertEqual(list(self.root.glob('*.data')), [])
        for root in ('off', str(self.path/'not-a-directory')):
            pieces = []
            cached_transfer(self.source, select_plan(self.source, [self.profile]),
                            lambda b: pieces.append(bytes(b)), root=root, assembler=self.assembled)
            self.assertEqual(self.decode(b''.join(pieces)), expected)

    def test_interrupted_write_is_not_published_and_stale_temp_is_removed(self):
        pieces = []
        def emit(b):
            pieces.append(bytes(b))
            if len(pieces) > 4:
                raise RuntimeError('cancelled')
        with self.assertRaises(RuntimeError):
            self.cached(emit=emit)
        self.assertEqual(list(self.root.glob('*.json')), [])
        stale = self.root/('f'*64+'.tmp'); stale.write_bytes(b'abandoned')
        self.cached()
        self.assertFalse(stale.exists())

    def test_disk_write_error_does_not_interrupt_load(self):
        expected = b''.join(self.assembled(self.source, self.profile).blocks())
        with mock.patch('prepared_cache.os.fsync', side_effect=OSError('disk full')):
            self.assertEqual(self.decode(self.cached()), expected)
        self.assertEqual(list(self.root.glob('*.json')), [])

    def test_loader_content_change_invalidates_identity(self):
        code = Path(self.temp.name)/'fmv'; code.mkdir()
        f = code/'loader.py'; f.write_text('a')
        first = loader_identity(code)
        f.write_text('b')
        self.assertNotEqual(loader_identity(code), first)

    def test_cache_budget_evicts_only_owned_namespace(self):
        self.cached()
        unrelated = self.root/'keep-me'; unrelated.write_text('user file')
        key = cache_key(self.source, self.profile, 'new-loader')
        store = Store(self.root, key)
        try:
            with mock.patch('prepared_cache.BUDGET', 513*1024**2):
                self.assertTrue(store.reserve())
            self.assertEqual(list(self.root.glob('*.data')), [])
            self.assertTrue(unrelated.exists())
        finally:
            store.close()


if __name__ == '__main__':
    import unittest
    unittest.main()
