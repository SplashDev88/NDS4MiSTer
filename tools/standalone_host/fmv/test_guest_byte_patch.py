# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic admission and real disposable-worker protocol checks."""
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

from guest_byte_patch import assemble, from_environment, SELECTION_KEYS
from prepare import Source, read_overlay


class GuestPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rom = self.root/'original.nds'
        self.manifest_path = self.root/'manifest.json'
        raw = bytearray(1024)
        raw[12:16] = b'TEST'
        struct.pack_into('<4I', raw, 0x20, 512, 0x02000000, 0x02000000, 512)
        raw[512:] = bytes.fromhex('0000a0e1')*128
        self.raw = bytes(raw)
        self.rom.write_bytes(raw)
        self.fd = os.open(self.rom, os.O_RDONLY)
        self.source = Source(self.fd)
        self.manifest = dict(schema_version=1, header_bytes=352,
            header_sha1=hashlib.sha1(raw[:352]).hexdigest(), rom_sha256=hashlib.sha256(raw).hexdigest(),
            arm9_sha256=hashlib.sha256(raw[512:]).hexdigest(), game_code='TEST', revision=0,
            arm9_crc32=f'{zlib.crc32(raw[512:]):08x}', patches=[dict(
                id='one', cpu='arm9', target='arm9.bin/main_loaded', addr='0x02000020', mode='arm',
                expect=raw[544:552].hex(), replace='0100a0e30200a0e3', enabled=False,
                data_guards=[dict(addr='0x02000080', expect=raw[640:648].hex())])])

    def tearDown(self):
        os.close(self.fd)
        self.temp.cleanup()

    def environment(self, manifest=None, selection='one'):
        raw = json.dumps(self.manifest if manifest is None else manifest).encode()
        self.manifest_path.write_bytes(raw)
        return dict(zip(SELECTION_KEYS, [str(self.manifest_path), hashlib.sha256(raw).hexdigest(), selection]))

    def result(self, env):
        image, report = from_environment(self.source, env)
        return b''.join(image.blocks()), report

    def expected(self):
        raw = bytearray(self.raw)
        raw[544:552] = bytes.fromhex(self.manifest['patches'][0]['replace'])
        return bytes(raw)

    def test_explicit_disabled_candidate_changes_only_guarded_bytes(self):
        got, report = self.result(self.environment())
        self.assertEqual(got, self.expected())
        self.assertEqual(report['state'], 'applied_to_virtual_image')
        self.assertFalse(self.manifest['patches'][0]['enabled'])
        self.assertEqual(self.rom.read_bytes(), self.raw)

    def test_manifest_pin_partial_missing_and_invalid_selection_fall_back(self):
        good = self.environment()
        cases = [{}, dict(good, NDS_GUEST_PATCH_SHA256='0'*64),
                 dict(good, NDS_GUEST_PATCH_MANIFEST=str(self.root/'missing'))]
        cases += [{k:v for k,v in good.items() if k != missing} for missing in SELECTION_KEYS]
        cases += [dict(good, NDS_GUEST_PATCH_IDS=s) for s in ['', 'unknown', 'one,one', 'one,', ' one']]
        for env in cases:
            with self.subTest(env=env):
                got, report = self.result(env)
                self.assertEqual(got, self.raw)
                self.assertEqual(report['state'], 'skipped')

    def test_identity_and_original_guards_fail_atomically(self):
        cases = []
        for field in ['header_sha1','rom_sha256','arm9_sha256','game_code','arm9_crc32']:
            m = copy.deepcopy(self.manifest); m[field] = 'wrong'; cases.append(m)
        m = copy.deepcopy(self.manifest); m['revision'] = 1; cases.append(m)
        for field, value in [('expect','00'*8), ('cpu','arm7'), ('target','overlay:12'),
                             ('addr','0x02000021'), ('hook','new-service'), ('scratch_bytes',8),
                             ('overlay',12), ('replace','00'*4)]:
            m = copy.deepcopy(self.manifest); m['patches'][0][field] = value; cases.append(m)
        m = copy.deepcopy(self.manifest); m['patches'][0]['data_guards'][0]['expect'] = '00'*8; cases.append(m)
        for m in cases:
            got, report = self.result(self.environment(m))
            self.assertEqual(got, self.raw)
            self.assertEqual(report['state'], 'skipped')

    def test_multiple_selection_and_overlap_fall_back_as_one_transaction(self):
        m = copy.deepcopy(self.manifest)
        second = dict(m['patches'][0], id='two', addr='0x02000040')
        m['patches'].append(second)
        got, report = self.result(self.environment(m, 'one,two'))
        expected = bytearray(self.expected()); expected[576:584] = bytes.fromhex(second['replace'])
        self.assertEqual(got, expected); self.assertEqual(len(report['applied']), 2)
        for address in ['0x02000020','0x02000080']:
            second['addr'] = address
            got, report = self.result(self.environment(m, 'one,two'))
            self.assertEqual(got, self.raw); self.assertEqual(report['applied'], [])

    def test_source_change_is_not_a_successful_fallback(self):
        env = self.environment()
        self.rom.write_bytes(b'short')
        with self.assertRaises(ValueError): self.result(env)

    def worker(self, env):
        environment = {k:v for k,v in os.environ.items() if not k.startswith('NDS_')}
        environment.update(env, NDS_ROM_LOAD_PROGRESS='1', NDS_ROM_STREAM_PATCHES='1')
        return subprocess.run([sys.executable, '-E', '-s', '-B',
            str(Path(__file__).with_name('stream.py')), str(self.fd), '1', str(os.getpid())],
            env=environment, pass_fds=(self.fd,), capture_output=True, timeout=10)

    def decode(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        data = result.stdout; at = 0; last_work = -1
        while True:
            size, error, op = struct.unpack_from('<Qii', data, at); at += 16
            self.assertEqual(error, 0)
            if op == 0: break
            self.assertIn(op, [7,13])
            if op == 13:
                self.assertGreaterEqual(size, last_work); last_work = size
        self.assertEqual(size, len(self.raw))
        image = data[at:at+size]; at += size
        self.assertEqual(struct.unpack_from('<Qii', data, at), (size,0,8))
        self.assertEqual(len(data), at+16)
        return image

    def test_real_worker_validated_completion_and_original_file(self):
        result = self.worker(self.environment())
        self.assertEqual(self.decode(result), self.expected())
        self.assertIn(b'GUEST_PATCH_RESULT', result.stderr)
        self.assertNotIn(b'FMV_AUTO_APPLIED', result.stderr)
        self.assertEqual(self.rom.read_bytes(), self.raw)

    def test_real_worker_wrong_pin_and_no_selection_preserve_original(self):
        env = self.environment(); env['NDS_GUEST_PATCH_SHA256'] = '0'*64
        self.assertEqual(self.decode(self.worker(env)), self.raw)
        self.assertEqual(self.decode(self.worker({})), self.raw)


class OverlayPatchTests(GuestPatchTests):
    def setUp(self):
        super().setUp()
        raw = bytearray(self.raw + bytes(1024))
        struct.pack_into('<II', raw, 0x48, 1024, 16)
        struct.pack_into('<II', raw, 0x50, 1056, 64)
        # Two distinct overlay IDs reuse the same RAM address. Selecting one
        # must never patch the other's file merely because its bytes match.
        for index, first in enumerate((1280, 1536)):
            struct.pack_into('<II', raw, 1024 + index*8, first, first+64)
            struct.pack_into('<8I', raw, 1056 + index*32,
                             index, 0x02100000, 64, 32, 0, 0, index, 0)
            raw[first:first+64] = bytes.fromhex('c046')*32
        self.raw = bytes(raw)
        self.rom.write_bytes(raw)
        self.source = Source(self.fd)
        self.manifest.update(header_sha1=hashlib.sha1(raw[:352]).hexdigest(),
                             rom_sha256=hashlib.sha256(raw).hexdigest())
        self.overlay_patch = dict(id='overlay-one', cpu='arm9', target='arm9.overlay',
            overlay=1, overlay_ram='0x02100000', overlay_file_id=1,
            overlay_sha256=hashlib.sha256(raw[1536:1600]).hexdigest(),
            addr='0x02100010', mode='thumb', expect=raw[1552:1560].hex(),
            replace='0120022103220423', enabled=False,
            data_guards=[dict(addr='0x02100030', expect=raw[1584:1592].hex())])
        self.manifest['patches'].append(self.overlay_patch)

    def test_overlay_only_and_mixed_selection_preserve_other_files_and_metadata(self):
        for selection in ['overlay-one', 'one,overlay-one']:
            with self.subTest(selection=selection):
                got, report = self.result(self.environment(selection=selection))
                expected = bytearray(self.expected() if 'one,' in selection else self.raw)
                expected[1552:1560] = bytes.fromhex(self.overlay_patch['replace'])
                self.assertEqual(got, expected)
                self.assertEqual(report['overlays'][0]['id'], 1)
                self.assertEqual(report['overlays'][0]['output_sha256'],
                                 hashlib.sha256(expected[1536:1600]).hexdigest())
                self.assertEqual(got[1280:1344], self.raw[1280:1344])
                self.assertEqual(got[:512], self.raw[:512])
                self.assertEqual(got[1024:1120], self.raw[1024:1120])
                self.assertEqual(self.rom.read_bytes(), self.raw)

    def test_noop_overlay_is_full_image_identical_and_repeat_reads_are_stable(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['patches'][1]['replace'] = self.overlay_patch['expect']
        image, report = assemble(self.source, manifest, ['overlay-one'])
        self.assertEqual(report['state'], 'applied_to_virtual_image')
        self.assertEqual(b''.join(image.blocks()), self.raw)
        image, _ = assemble(self.source, self.manifest, ['overlay-one'])
        first = b''.join(image.blocks(1536, 1600))
        self.assertEqual(b''.join(image.blocks(1536, 1600)), first)
        self.assertEqual(b''.join(image.blocks(1280, 1344)), self.raw[1280:1344])
        # Repeat source reads are not a substitute for a game's reload test.

    def test_overlay_identity_mode_span_and_guard_failures_are_atomic(self):
        cases = [('overlay', 0), ('overlay', 2), ('overlay', -1), ('overlay', True),
                 ('overlay_file_id', 0), ('overlay_ram', '0x02100004'),
                 ('overlay_sha256', '0'*64), ('cpu', 'arm7'),
                 ('addr', '0x02100011'), ('addr', '0x0210003c'),
                 ('addr', '0x02100040'), ('expect', '00'*8),
                 ('mode', 'unknown'), ('scratch_bytes', 8), ('hook', 'service')]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                m = copy.deepcopy(self.manifest); m['patches'][1][field] = value
                got, report = self.result(self.environment(m, 'one,overlay-one'))
                self.assertEqual(got, self.raw)
                self.assertEqual(report['state'], 'skipped')
                self.assertEqual(report['applied'], [])
        m = copy.deepcopy(self.manifest)
        m['patches'][1]['data_guards'][0]['expect'] = '00'*8
        self.assertEqual(self.result(self.environment(m, 'overlay-one'))[0], self.raw)
        m = copy.deepcopy(self.manifest)
        m['patches'][1]['addr'] = '0x02100030'
        self.assertEqual(self.result(self.environment(m, 'overlay-one'))[0], self.raw)

    def test_overlay_metadata_and_compression_flags_reject(self):
        changes = [(1088, '<I', 9), (1088+8, '<I', 68),
                   (1088+24, '<I', 2), (1088+28, '<I', 0x01000040),
                   (1088+28, '<I', 0x02000000), (1036, '<I', 1535),
                   (1036, '<I', len(self.raw)+4), (0x54, '<I', 63),
                   (0x4c, '<I', 15)]
        original = self.raw
        for offset, fmt, value in changes:
            with self.subTest(offset=offset, value=value):
                raw = bytearray(original); struct.pack_into(fmt, raw, offset, value)
                self.rom.write_bytes(raw); self.source = Source(self.fd)
                m = copy.deepcopy(self.manifest)
                m.update(header_sha1=hashlib.sha1(raw[:352]).hexdigest(),
                         rom_sha256=hashlib.sha256(raw).hexdigest())
                got, report = self.result(self.environment(m, 'one,overlay-one'))
                self.assertEqual(got, raw)
                self.assertEqual(report['state'], 'skipped')

    def test_shared_reader_preserves_compressed_fmv_overlay_support(self):
        from ndspy import codeCompression
        decoded = bytes.fromhex('0000a0e1')*1024
        compressed = codeCompression.compress(decoded, isArm9=False)
        self.assertLess(len(compressed), len(decoded))
        raw = bytearray(self.raw)
        raw.extend(bytes(max(0, 1536+len(compressed)-len(raw))))
        raw[1536:1536+len(compressed)] = compressed
        struct.pack_into('<II', raw, 1032, 1536, 1536+len(compressed))
        struct.pack_into('<I', raw, 1088+8, len(decoded))
        struct.pack_into('<I', raw, 1088+28, 0x01000000 | len(compressed))
        self.rom.write_bytes(raw); self.source = Source(self.fd)
        loaded = read_overlay(self.source, raw[:512], 1, 0x02100000)
        self.assertEqual(loaded['stored'], compressed)
        self.assertEqual(loaded['decoded'], decoded)

    def test_uncompressed_overlay_footer_is_not_guessed_as_compression(self):
        raw = bytearray(self.raw)
        # A plausible BLZ footer with invalid padding is still ordinary data
        # when the overlay table says uncompressed.
        raw[1592:1600] = struct.pack('<II', 0x10000010, 32)
        self.rom.write_bytes(raw); self.source = Source(self.fd)
        loaded = read_overlay(self.source, raw[:512], 1, 0x02100000)
        self.assertEqual(loaded['decoded'], raw[1536:1600])

    def test_real_overlay_worker_uses_existing_stream_protocol(self):
        expected = bytearray(self.raw)
        expected[1552:1560] = bytes.fromhex(self.overlay_patch['replace'])
        result = self.worker(self.environment(selection='overlay-one'))
        self.assertEqual(self.decode(result), expected)
        self.assertEqual(self.rom.read_bytes(), self.raw)


class Arm7AutoloadPatchTests(GuestPatchTests):
    def setUp(self):
        super().setUp()
        # Separate implicit boot prefix, two copy payloads, then final table.
        # The first section is main RAM; only section two is a supported WRAM target.
        arm7 = bytearray(bytes.fromhex('0000a0e1')*70)
        struct.pack_into('<5I', arm7, 0x20,
                         0x02380100, 0x02380118, 0x02380080, 0x02380080, 0x02380080)
        struct.pack_into('<6I', arm7, 0x100,
                         0x027e0000, 32, 0, 0x037f8000, 96, 32)
        raw = bytearray(self.raw + arm7)
        struct.pack_into('<4I', raw, 0x30, 1024, 0x02380000, 0x02380000, len(arm7))
        self.raw = bytes(raw)
        self.rom.write_bytes(raw); self.source = Source(self.fd)
        self.repin(self.manifest, raw)
        self.manifest['arm7_code_settings_offset'] = '0x20'
        self.autoload_patch = dict(id='autoload-two', cpu='arm7', target='arm7.bin/autoload:2',
            section_base='0x037f8000', section_bss_bytes=32,
            section_sha256=hashlib.sha256(arm7[0xa0:0x100]).hexdigest(),
            addr='0x037f8010', mode='arm', expect=arm7[0xb0:0xb8].hex(),
            replace='0100a0e30200a0e3', enabled=False,
            data_guards=[dict(addr='0x037f8050', expect=arm7[0xf0:0xf8].hex())])
        self.manifest['patches'].append(self.autoload_patch)

    def repin(self, manifest, raw):
        first, _, _, size = struct.unpack_from('<4I', raw, 0x30)
        manifest.update(header_sha1=hashlib.sha1(raw[:352]).hexdigest(),
            rom_sha256=hashlib.sha256(raw).hexdigest(),
            arm7_sha256=hashlib.sha256(raw[first:first+size]).hexdigest(),
            arm7_crc32=f'{zlib.crc32(raw[first:first+size]):08x}')

    def test_autoload_only_and_mixed_selection_preserve_prefix_table_and_other_section(self):
        for selection in ['autoload-two', 'one,autoload-two']:
            with self.subTest(selection=selection):
                got, report = self.result(self.environment(selection=selection))
                expected = bytearray(self.expected() if selection.startswith('one,') else self.raw)
                expected[1200:1208] = bytes.fromhex(self.autoload_patch['replace'])
                self.assertEqual(got, expected)
                self.assertEqual(report['state'], 'applied_to_virtual_image')
                self.assertEqual(report['arm7_autoloads'][0]['index'], 2)
                self.assertEqual(report['arm7_autoloads'][0]['cartridge_offset'], 1184)
                self.assertEqual(report['arm7_autoloads'][0]['bss_bytes'], 32)
                self.assertEqual(got[1024:1184], self.raw[1024:1184])
                self.assertEqual(got[1280:], self.raw[1280:])
                self.assertEqual(self.rom.read_bytes(), self.raw)

    def test_autoload_noop_control_and_repeated_reads(self):
        m = copy.deepcopy(self.manifest); m['patches'][1]['replace'] = self.autoload_patch['expect']
        image, report = assemble(self.source, m, ['autoload-two'])
        self.assertEqual(report['state'], 'applied_to_virtual_image')
        self.assertEqual(b''.join(image.blocks()), self.raw)
        image, report = assemble(self.source, self.manifest, ['autoload-two'])
        self.assertEqual(b''.join(image.blocks(1184, 1280)), b''.join(image.blocks(1184, 1280)))
        self.assertEqual(self.rom.read_bytes(), self.raw)

    def test_autoload_identity_and_boundaries_fail_atomically(self):
        cases = [('target', 'arm7.bin/autoload:0'), ('target', 'arm7.bin/autoload:1'),
                 ('target', 'arm7.bin/autoload:3'), ('target', 'arm7.bin/autoload:-1'),
                 ('target', 'arm7.bin/autoload:02'), ('target', 'arm7.bin/autoload:x'),
                 ('section_base', '0x03800000'), ('section_bss_bytes', 0),
                 ('section_bss_bytes', True), ('section_sha256', '0'*64),
                 ('addr', '0x037f8011'), ('addr', '0x037f805c'), ('addr', '0x037f8060'),
                 ('expect', '00'*8), ('cpu', 'arm9'), ('overlay', 1),
                 ('hook', 'new-service'), ('scratch_bytes', 8)]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                m = copy.deepcopy(self.manifest); m['patches'][1][field] = value
                got, report = self.result(self.environment(m, 'one,autoload-two'))
                self.assertEqual(got, self.raw); self.assertEqual(report['applied'], [])
                self.assertEqual(report['state'], 'skipped')
        for field, value in [('arm7_sha256', '0'*64), ('arm7_crc32', '00000000'),
                             ('arm7_code_settings_offset', '0x24'),
                             ('arm7_code_settings_offset', '-4')]:
            m = copy.deepcopy(self.manifest); m[field] = value
            self.assertEqual(self.result(self.environment(m, 'autoload-two'))[0], self.raw)
        for field in ['arm7_sha256', 'arm7_crc32', 'arm7_code_settings_offset']:
            m = copy.deepcopy(self.manifest); del m[field]
            self.assertEqual(self.result(self.environment(m, 'autoload-two'))[0], self.raw)
        m = copy.deepcopy(self.manifest); m['patches'][1]['addr'] = '0x037f8050'
        self.assertEqual(self.result(self.environment(m, 'autoload-two'))[0], self.raw)

    def test_malformed_raw_table_is_not_authorized_by_rehashed_identity(self):
        # Each corruption is repinned, so the table/mapping checks must reject it.
        changes = [(0x20, 0x02380104), (0x24, 0x02380114), (0x28, 0x02380084),
                   (0x28, 0x02380030), (0x104, 0xfffffffc), (0x104, 28),
                   (0x10c, 0x037f8001), (0x10c, 0x036f8000),
                   (0x10c, 0x03810000), (0x110, 100), (0x110, 92),
                   (0x114, 0xfffffff0), (0x114, 31)]
        for at, value in changes:
            with self.subTest(at=at, value=hex(value)):
                raw = bytearray(self.raw); struct.pack_into('<I', raw, 1024+at, value)
                self.rom.write_bytes(raw); self.source = Source(self.fd)
                m = copy.deepcopy(self.manifest); self.repin(m, raw)
                got, report = self.result(self.environment(m, 'one,autoload-two'))
                self.assertEqual(got, raw); self.assertEqual(report['state'], 'skipped')
                self.assertEqual(report['applied'], [])

    def test_real_autoload_worker_uses_existing_protocol(self):
        expected = bytearray(self.raw); expected[1200:1208] = bytes.fromhex(self.autoload_patch['replace'])
        self.assertEqual(self.decode(self.worker(self.environment(selection='autoload-two'))), expected)
        self.assertEqual(self.rom.read_bytes(), self.raw)


if __name__ == '__main__': unittest.main()
