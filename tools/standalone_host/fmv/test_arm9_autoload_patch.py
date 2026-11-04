# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic compressed-boot admission; no commercial game bytes/assets."""
import copy
import hashlib
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

from ndspy import code, codeCompression
from guest_byte_patch import assemble
from prepare import Source


class Arm9AutoloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'original.nds'
        boot = bytearray(bytes.fromhex('0000a0e1')*6144)
        struct.pack_into('<2I', boot, 0x3c, 0xdec00621, 0x2106c0de)
        payload = bytearray(bytes.fromhex('0000a0e1')*2048)
        payload[16:24] = bytes.fromhex('010c54e30400003a')
        arm = code.MainCodeFile.fromSections([
            code.MainCodeFile.Section(boot, 0x02000000, 0, implicit=True),
            code.MainCodeFile.Section(payload, 0x01ff8000, 0)], 0x02000000)
        arm.codeSettingsOffs = 0x20
        self.stored = bytes(arm.save(compress=True))
        header = bytearray(512); header[12:16] = b'TEST'
        struct.pack_into('<4I', header, 0x20, 512, 0x02000000, 0x02000000, len(self.stored))
        self.raw = bytes(header)+self.stored+b'UNCHANGED_OTHER_CARTRIDGE_DATA'
        self.path.write_bytes(self.raw)
        self.fd = os.open(self.path, os.O_RDONLY)
        self.source = Source(self.fd)
        sha = lambda b: hashlib.sha256(b).hexdigest()
        self.manifest = dict(schema_version=1, header_bytes=352,
            game_code='TEST', revision=0, header_sha1=hashlib.sha1(header[:352]).hexdigest(),
            rom_sha256=sha(self.raw), arm9_sha256=sha(self.stored),
            arm9_crc32=f'{zlib.crc32(self.stored):08x}', arm9_code_settings_offset='0x20',
            delivery='recompress-arm9-autoload-v1', patches=[dict(
                id='one', cpu='arm9', target='arm9.bin/autoload:1',
                section_base='0x01ff8000', section_bss_bytes=0, section_sha256=sha(payload),
                addr='0x01ff8010', mode='arm', expect=payload[16:24].hex(),
                replace='800054e30400003a', enabled=False,
                data_guards=[dict(addr='0x01ff8030', expect=payload[48:56].hex())])])

    def tearDown(self):
        os.close(self.fd)
        self.temp.cleanup()

    def run_image(self, manifest=None, ids=('one',)):
        image, report = assemble(self.source, manifest or self.manifest, ids)
        return b''.join(image.blocks()), report

    def test_only_declared_decoded_bytes_change_and_source_is_unchanged(self):
        got, report = self.run_image()
        self.assertEqual(report['state'], 'applied_to_virtual_image')
        self.assertEqual(len(got), len(self.raw))
        self.assertEqual(got[:512], self.raw[:512])
        end = 512+len(self.stored)
        self.assertEqual(got[end:], self.raw[end:])
        expected = bytearray(codeCompression.decompress(self.stored))
        expected[24592:24600] = bytes.fromhex(self.manifest['patches'][0]['replace'])
        self.assertEqual(codeCompression.decompress(got[512:end]), expected)
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_identical_control_is_original_complete_stream(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['patches'][0]['replace'] = manifest['patches'][0]['expect']
        got, report = self.run_image(manifest)
        self.assertEqual(report['state'], 'applied_to_virtual_image')
        self.assertEqual(got, self.raw)

    def test_guards_and_overlaps_fall_back_atomically(self):
        cases = []
        for field, value in [('target','arm9.bin/autoload:0'), ('target','arm9.bin/autoload:01'),
                             ('cpu','arm7'), ('addr','0x01ff8011'), ('addr','0x01ffa000'),
                             ('section_base','0x01ff8004'), ('section_sha256','0'*64),
                             ('section_bss_bytes',False), ('expect','00'*8),
                             ('hook','service'), ('scratch_bytes',4), ('overlay',0)]:
            manifest = copy.deepcopy(self.manifest)
            manifest['patches'][0][field] = value; cases.append(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest['patches'][0]['data_guards'] = [dict(addr='0x01ff8010', expect=manifest['patches'][0]['expect'])]
        cases.append(manifest)
        manifest = copy.deepcopy(self.manifest); manifest['arm9_code_settings_offset']='0x24'; cases.append(manifest)
        for manifest in cases:
            got, report = self.run_image(manifest)
            self.assertEqual(got, self.raw); self.assertEqual(report['applied'], [])
            self.assertEqual(report['state'], 'skipped')
        manifest = copy.deepcopy(self.manifest)
        manifest['patches'].append(dict(manifest['patches'][0], id='two'))
        self.assertEqual(self.run_image(manifest, ['one','two'])[0], self.raw)

    def test_resized_or_incorrect_decoded_output_is_rejected(self):
        original_save = code.MainCodeFile.save
        for resized in [True,False]:
            def broken(instance, **kwargs):
                output = original_save(instance, **kwargs)
                return output+b'\0' if resized else self.stored
            with patch.object(code.MainCodeFile, 'save', broken):
                got, report = self.run_image()
            self.assertEqual(got, self.raw); self.assertEqual(report['state'], 'skipped')

    def test_identical_control_does_not_invoke_encoder(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['patches'][0]['replace'] = manifest['patches'][0]['expect']
        with patch.object(code.MainCodeFile, 'save', side_effect=AssertionError('unnecessary encoding')):
            got, report = self.run_image(manifest)
        self.assertEqual(got, self.raw)
        self.assertEqual(report['state'], 'applied_to_virtual_image')

    def test_appended_decoded_boot_changes_only_declared_bytes_and_metadata(self):
        for changed in (False, True):
            manifest = copy.deepcopy(self.manifest)
            manifest['delivery'] = 'append-decoded-arm9-autoload-v1'
            if not changed:
                manifest['patches'][0]['replace'] = manifest['patches'][0]['expect']
            with patch.object(codeCompression, 'compress', side_effect=AssertionError('encoder used')):
                got, report = self.run_image(manifest)
            self.assertEqual(report['state'], 'applied_to_virtual_image')
            first, _, _, length = struct.unpack_from('<4I', got, 0x20)
            self.assertGreaterEqual(first, len(self.raw))
            self.assertEqual(first % 512, 0)
            self.assertEqual(got[512:len(self.raw)], self.raw[512:])
            expected = bytearray(codeCompression.decompress(self.stored))
            struct.pack_into('<I', expected, 0x20+20, 0)
            expected[24592:24600] = bytes.fromhex(manifest['patches'][0]['replace'])
            self.assertEqual(got[first:first+length], expected)
            self.assertEqual(self.path.read_bytes(), self.raw)

    def test_appended_decoded_boot_rejects_undeclared_encoder_change(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['delivery'] = 'append-decoded-arm9-autoload-v1'
        original_save = code.MainCodeFile.save
        def broken(instance, **kwargs):
            result = bytearray(original_save(instance, **kwargs)); result[4096] ^= 1
            return result
        with patch.object(code.MainCodeFile, 'save', broken):
            got, report = self.run_image(manifest)
        self.assertEqual(got, self.raw)
        self.assertEqual(report['state'], 'skipped')

    def test_appended_decoded_boot_keeps_original_byte_guards(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['delivery'] = 'append-decoded-arm9-autoload-v1'
        manifest['patches'][0]['expect'] = 'ff'*8
        got, report = self.run_image(manifest)
        self.assertEqual(got, self.raw)
        self.assertEqual(report['state'], 'skipped')


if __name__ == '__main__':
    unittest.main()
