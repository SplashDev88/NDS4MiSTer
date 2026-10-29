import hashlib
import copy
import json
from pathlib import Path
import tempfile
import unittest

from summarize_guest_pair import (normalize_checkpoint, guard_stats, normalize_autoload_memory,
                                  checked_autoload_contexts, autoload_comparison_rows, RAM_SPACES,
                                  overlay_comparison_body)


class OverlayCheckpointTest(unittest.TestCase):
    def test_retained_patch_context_normalizes_only_the_new_patch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); original = root/'original.bin'; baseline = root/'baseline.bin'
            source = bytes(range(128)); original.write_bytes(source)
            patch = dict(id='candidate', cpu='arm9', target='arm9.overlay', overlay=7,
                         overlay_file_id=7, overlay_ram='0x02000100', addr='0x02000108',
                         expect=source[8:16].hex(), replace='ff'*8,
                         overlay_sha256=hashlib.sha256(source).hexdigest())
            retained = dict(patch, id='retained', addr='0x02000120',
                            expect=source[32:40].hex(), replace='aa'*8)
            body = bytearray(source); body[32:40] = b'\xaa'*8; baseline.write_bytes(body)
            context = dict(id=7, base=patch['overlay_ram'], path=str(baseline),
                           sha256=hashlib.sha256(body).hexdigest(), original_path=str(original),
                           original_sha256=patch['overlay_sha256'], base_patch_ids=['retained'])
            manifest = root/'manifest.json'
            manifest.write_text(json.dumps(dict(patches=[retained, patch])))
            records = [dict(overlay_context=copy.deepcopy(context), base_patch_ids=['retained'],
                            manifest=str(manifest), manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                            admission=dict(requested=ids)) for ids in [['retained'], ['candidate','retained']]]
            before = bytearray(0x400000); before[256:384] = body
            after = before.copy(); after[264:272] = b'\xff'*8
            got, identities = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(got, before); self.assertEqual(identities, ['original','replacement'])
            self.assertEqual(got[288:296], b'\xaa'*8)  # Retained code is never restored/masked.
            after[288] ^= 1
            got, identities = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(got, after); self.assertEqual(identities, ['original','unmatched'])
            for mutate in [lambda r: r[1].update(base_patch_ids=[]),
                           lambda r: r[0]['admission'].update(requested=[]),
                           lambda r: r[1].update(manifest_sha256='0'*64)]:
                bad = copy.deepcopy(records); mutate(bad)
                with self.assertRaises(AssertionError):normalize_checkpoint(before, after, patch, bad)
            for bad in [dict(retained, addr=patch['addr'], expect=patch['expect']),
                        dict(retained, overlay=8), dict(retained, expect='00'*8),
                        dict(retained, id='candidate')]:
                c = dict(context, base_patch_ids=[bad['id']])
                with self.assertRaises(AssertionError):overlay_comparison_body(c, patch, [bad])
            body[60] ^= 1; baseline.write_bytes(body)
            forged = dict(context, sha256=hashlib.sha256(body).hexdigest())
            with self.assertRaises(AssertionError):overlay_comparison_body(forged, patch, [retained])

    def test_full_body_required_and_unknown_bytes_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'context.bin'
            body = bytes(range(64))
            path.write_bytes(body)
            digest = hashlib.sha256(body).hexdigest()
            patch = dict(target='arm9.overlay', overlay=7, overlay_ram='0x02000100',
                         addr='0x02000108', expect=body[8:16].hex(), replace='ff'*8,
                         overlay_sha256=digest)
            context = dict(id=7, base=patch['overlay_ram'], path=str(path), sha256=digest)
            records = [dict(overlay_context=context), dict(overlay_context=context)]
            before = bytearray(0x400000)
            before[256:320] = body
            after = before.copy()
            after[264:272] = b'\xff'*8
            normalized, ids = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(normalized, before)
            self.assertEqual(ids, ['original', 'replacement'])
            after[319] ^= 1
            normalized, ids = normalize_checkpoint(before, after, patch, records)
            self.assertEqual(normalized, after)
            self.assertEqual(ids, ['original', 'unmatched'])
            self.assertNotEqual(normalized, before)
            absent = bytearray(0x400000)
            self.assertEqual(normalize_checkpoint(absent, absent, patch, records)[1], ['unmatched']*2)
            path.write_bytes(body[:-1] + b'\xff')
            with self.assertRaises(AssertionError):
                normalize_checkpoint(before, after, patch, records)

    def test_initial_code_still_strict(self):
        patch = dict(target='arm9.bin/main_loaded', addr='0x02000100', expect='11'*8, replace='22'*8)
        before = bytearray(0x400000)
        before[256:264] = b'\x11'*8
        after = before.copy()
        after[256:264] = b'\x22'*8
        self.assertEqual(normalize_checkpoint(before, after, patch, [])[0], before)
        after[256] = 0
        with self.assertRaises(AssertionError):
            normalize_checkpoint(before, after, patch, [])


class CombinedWriteWatchTest(unittest.TestCase):
    def test_instruction_watch_is_explicit_and_uses_expected_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'bus.csv'
            path.write_text('ordinal,kind,frame,width,address,value\n'
                            '0,write,0,32,2000100,11223344\n'
                            '1,write,1,32,2000104,55667788\n')
            data = [dict(addr='0x02000104',expect='88776655')]
            code = dict(addr='0x02000100',expect='44332211')
            with self.assertRaises(AssertionError):
                guard_stats(path,data)
            result=guard_stats(path,data,code)
            self.assertEqual(result['guarded_bytes_observed'],8)
            self.assertEqual(result['instruction_bytes_included'],4)
            self.assertEqual(result['writes_not_matching_expected_bytes'],0)
            self.assertEqual(result['writes_after_frame0'],1)
            code['expect']='44332210'
            self.assertEqual(guard_stats(path,data,code)['writes_not_matching_expected_bytes'],1)
            code['addr']='0x02000108'
            with self.assertRaises(AssertionError):
                guard_stats(path,data,code)

    def test_conflicting_guard_bytes_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'bus.csv'
            path.write_text('ordinal,kind,frame,width,address,value\n')
            with self.assertRaises(AssertionError):
                guard_stats(path,[dict(addr='0x02000100',expect='11')],
                            dict(addr='0x02000100',expect='22'))


class AutoloadComparisonTest(unittest.TestCase):
    def contexts(self):
        return [dict(space=space, addr=hex(base+16), expect='1011121314151617',
                     replace='101112131415aa17') for space,(base,_) in RAM_SPACES.items()]

    def test_all_spaces_normalize_only_qualified_changes(self):
        contexts=self.contexts()
        for space,(_,size) in RAM_SPACES.items():
            with self.subTest(space=space):
                before=bytearray(size); before[16:24]=bytes.fromhex(contexts[0]['expect'])
                after=before.copy(); after[22]=0xaa
                normalized,ids=normalize_autoload_memory(after,space,contexts)
                self.assertEqual(normalized,before);self.assertEqual(list(ids.values()),['replacement'])
                self.assertEqual(after[22],0xaa)  # Input stays raw.
                after[17]^=1
                normalized,ids=normalize_autoload_memory(after,space,contexts)
                self.assertEqual(normalized,after);self.assertEqual(list(ids.values()),['unmatched'])
                absent=bytearray(size)
                self.assertEqual(normalize_autoload_memory(absent,space,contexts)[0],absent)
                self.assertEqual(list(normalize_autoload_memory(before,space,contexts)[1].values()),['original'])

    def test_bad_views_aliases_overlaps_and_extents_rejected(self):
        for space,(_,size) in RAM_SPACES.items():
            with self.assertRaises(AssertionError):normalize_autoload_memory(bytes(size-1),space,self.contexts())
        original=self.contexts()
        for field,value in [('space','itcm'),('addr','0x03000010'),('addr','0x037ffffc'),
                            ('expect','00'),('replace','00'*9)]:
            contexts=[dict(original[1],**{field:value})]
            with self.assertRaises((AssertionError,KeyError)):checked_autoload_contexts(contexts)
        for contexts in [[],original+[original[0]],original+[dict(original[0],addr='0x02000014')]]:
            with self.assertRaises(AssertionError):checked_autoload_contexts(contexts)

    def test_row_format_and_legacy_main_checkpoint_entry(self):
        contexts=self.contexts()
        text=autoload_comparison_rows(contexts)
        self.assertEqual(len(text.splitlines()),3)
        self.assertTrue(text.endswith('autoload arm7wram\n'))
        before=bytearray(0x400000);before[16:24]=bytes.fromhex(contexts[0]['expect'])
        after=before.copy();after[22]=0xaa
        records=[dict(autoload_contexts=contexts)]*2
        got,ids=normalize_checkpoint(before,after,dict(cpu='arm7'),records)
        self.assertEqual(got,before)
        before[16]=after[16]=0
        got,ids=normalize_checkpoint(before,after,dict(cpu='arm7'),records)
        self.assertEqual(got,after)  # Reused staging is never masked.
        bad=[records[0],dict(autoload_contexts=contexts[:1])]
        with self.assertRaises(AssertionError):normalize_checkpoint(before,after,dict(cpu='arm7'),bad)


if __name__ == '__main__':
    unittest.main()
