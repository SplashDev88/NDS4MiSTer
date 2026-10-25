# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
from prepare import ROOT, Source, VirtualRom
from prepared_cache import cached_transfer, Store
from stream_load import select_plan, transfer_limit


class ImageCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'game.nds'
        raw = bytearray(bytes(range(256))*16)
        raw[12:16] = b'YQUE'; raw[30] = 0
        self.raw = bytes(raw); self.path.write_bytes(raw)
        self.fd = os.open(self.path, os.O_RDONLY)
        self.source = Source(self.fd)
        self.root = Path(self.temp.name)/'cache'
        self.profile = dict(key='fixture', code_hex=b'YQUE'.hex(), revision=0,
            source_size=len(raw), output_size=len(raw)*2,
            source_sha256=hashlib.sha256(raw).hexdigest())

    def tearDown(self):
        os.close(self.fd); self.temp.cleanup()

    def assemble(self, source, profile, **kwargs):
        image = VirtualRom(source, profile['output_size'])
        image.add(100, b'guarded-code')
        image.add(image.size-21, b'expanded-movie')
        return image.finish()

    def run_cache(self, profile=None, assembler=None, emit=None, **kwargs):
        plan = select_plan(self.source, [profile or self.profile])
        self.assertIsNotNone(plan)
        pieces = []
        cached_transfer(self.source, plan, emit or (lambda x: pieces.append(bytes(x))),
                        root=self.root, loader='fixture', assembler=assembler or self.assemble, **kwargs)
        return b''.join(pieces)

    def decode(self, wire):
        at = 0
        while True:
            size, length, op = struct.unpack_from('<Qii', wire, at); at += 16
            if op != 7: break
        self.assertEqual((length, op), (0, 9))
        output = bytearray(b'\xff'*size)
        previous, preparing, complete = 0, False, False
        while at < len(wire):
            offset, length, op = struct.unpack_from('<Qii', wire, at); at += 16
            if op == 10:
                self.assertGreater(length, 0)
                self.assertLessEqual(length, 262144)
                self.assertLessEqual(offset+length, transfer_limit(size))
                output[offset:offset+length] = wire[at:at+length]; at += length
            elif op == 7:
                self.assertLessEqual(previous, offset); self.assertLessEqual(offset, size)
                previous = offset
            elif op == 11:
                self.assertFalse(preparing); self.assertEqual(previous, size); preparing = True
            elif op == 8:
                self.assertTrue(preparing); self.assertEqual(previous, size)
                self.assertEqual(offset, transfer_limit(size)); self.assertEqual(at, len(wire))
                complete = True
            else: self.fail('invalid protocol')
        self.assertTrue(complete)
        return bytes(output)

    def test_same_size_and_expanded_images_hit_without_source_reads_or_assembly(self):
        for size in [4096, 8192]:
            p = dict(self.profile, output_size=size)
            expected = b''.join(self.assemble(self.source, p).blocks())
            self.assertEqual(self.decode(self.run_cache(profile=p)), expected)
            plan = select_plan(self.source, [p]); pieces = []
            with mock.patch.object(self.source, 'read', side_effect=AssertionError('original reread')):
                cached_transfer(self.source, plan, lambda b: pieces.append(bytes(b)),
                    root=self.root, loader='fixture', assembler=mock.Mock(side_effect=AssertionError('reassembled')))
            self.assertEqual(self.decode(b''.join(pieces)), expected)
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_corruption_recovers_expanded_image_and_clears_provisional_writes(self):
        expected = self.decode(self.run_cache())
        datafile = next(self.root.glob('*.data'))
        data = bytearray(datafile.read_bytes()); struct.pack_into('<Q', data, 0, 6000); data[12] ^= 1
        datafile.write_bytes(data)
        self.assertEqual(self.decode(self.run_cache()), expected)
        self.assertEqual(self.decode(self.run_cache()), expected)

    def test_wrong_hash_and_failed_guard_fall_back_to_original_size_without_cache(self):
        self.assertEqual(self.decode(self.run_cache(profile=dict(self.profile, source_sha256='0'*64))), self.raw)
        def fail(*args, **kwargs): raise ValueError('hook differs')
        self.assertEqual(self.decode(self.run_cache(assembler=fail)), self.raw)
        self.assertFalse(list(self.root.glob('*.json')))

    def test_corrupt_cache_and_failed_recovery_never_complete(self):
        self.run_cache()
        p = next(self.root.glob('*.data')); b = bytearray(p.read_bytes()); b[12] ^= 1; p.write_bytes(b)
        pieces = []
        def fail(*args, **kwargs): raise ValueError('hook differs')
        with self.assertRaisesRegex(ValueError, 'recovery could not qualify'):
            self.run_cache(assembler=fail, emit=lambda b: pieces.append(bytes(b)))
        self.assertNotEqual(pieces[-1], struct.pack('<Qii', 8192, 0, 8))
        self.assertFalse(list(self.root.glob('*.json')))

    def test_source_mutation_on_transfer_has_no_completion_or_published_cache(self):
        pieces=[]
        def emit(data):
            pieces.append(bytes(data))
            if len(data) == 16 and struct.unpack('<Qii', data)[2] == 9:
                self.path.write_bytes(b'short')
        with self.assertRaises(ValueError): self.run_cache(emit=emit)
        self.assertFalse(list(self.root.glob('*.json')))
        self.assertNotEqual(pieces[-1], struct.pack('<Qii', 8192, 0, 8))

    def test_disk_failure_still_loads_and_does_not_publish(self):
        expected = b''.join(self.assemble(self.source, self.profile).blocks())
        with mock.patch('prepared_cache.os.fsync', side_effect=OSError('full')):
            self.assertEqual(self.decode(self.run_cache()), expected)
        self.assertFalse(list(self.root.glob('*.json')))

    def test_precise_reservation_does_not_evict_small_entries_unnecessarily(self):
        self.run_cache()
        old = next(self.root.glob('*.data'))
        p = dict(self.profile, key='second')
        with mock.patch('prepared_cache.BUDGET', 20000): self.run_cache(profile=p)
        self.assertTrue(old.exists())
        self.assertEqual(len(list(self.root.glob('*.json'))), 2)

    def test_registry_all_profiles_select_without_full_rom_hashing(self):
        registry = json.loads((ROOT/'profiles.json').read_text())['profiles']
        for p in registry:
            header = bytearray(512); header[12:16] = bytes.fromhex(p['code_hex']); header[30] = p['revision']
            source = mock.Mock(size=p['source_size']); source.read.return_value = bytes(header)
            with mock.patch('stream_load.CompactedFiles', return_value=object()):
                plan = select_plan(source, [p])
            self.assertIsNotNone(plan, p['key']); source.sha256.assert_not_called()

    def test_graphics_and_extended_aperture_boundaries(self):
        for size, limit in [(128,128),(256,252),(512,464)]:
            self.assertEqual(transfer_limit(size*1024**2), limit*1024**2)
        for size in [0,511,513*1024**2]:
            with self.assertRaises(ValueError): transfer_limit(size)

    def test_cache_status_is_negotiated_and_only_sent_for_a_real_miss(self):
        status = struct.pack('<Qii', 0, 1, 12)
        with mock.patch.dict(os.environ, {'NDS_ROM_CACHE_STATUS': '1'}):
            cold = self.run_cache()
            self.assertEqual(cold[:16], status)
            expected = self.decode(cold[16:])
            hit = self.run_cache()
            self.assertNotEqual(hit[:16], status)
            self.assertEqual(self.decode(hit), expected)
            pieces = []
            cached_transfer(self.source, select_plan(self.source, [self.profile]),
                lambda data: pieces.append(bytes(data)), root='off', assembler=self.assemble)
            self.assertNotIn(status, pieces)
            self.assertEqual(self.decode(b''.join(pieces)), expected)


if __name__ == '__main__': unittest.main()
