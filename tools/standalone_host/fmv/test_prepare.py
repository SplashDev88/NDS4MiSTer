# SPDX-License-Identifier: GPL-3.0-or-later
import base64
import hashlib
import json
import os
import random
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from prepare import Source, VirtualRom, CompactedFiles, movie, digest, profile_for, reframe_movie, extension_layout
from types import SimpleNamespace


class PrepareTests(unittest.TestCase):
    def test_ecclesia_scratch_starts_after_existing_itcm(self):
        section = SimpleNamespace(ramAddress=0x01ff8000, data=bytes(0x7280), bssSize=0)
        with self.assertRaisesRegex(ValueError, 'occupied'):
            extension_layout({}, [section])
        profile = dict(extension_ram=0x01fff280, extension_bytes=0xbc0)
        self.assertEqual(extension_layout(profile, [section]), (0x01fff280, 0xbc0))
        # BSS and aliased autoloads are occupied even without file payload.
        for item in [SimpleNamespace(ramAddress=0x01ff8000, data=bytes(0x7280), bssSize=1),
                     SimpleNamespace(ramAddress=0x7280, data=b'x', bssSize=0),
                     SimpleNamespace(ramAddress=0x8000, data=bytes(0x8001), bssSize=0)]:
            with self.assertRaisesRegex(ValueError, 'occupied'):
                extension_layout(profile, [item])
        self.assertEqual(extension_layout({}, []), (0x01fff000, 0xe40))
        for address, size in [(0x01fff281, 0xbc0), (0x01fff280, 0xbe0),
                              (0x02000000, 0xe40), (0x01ff7000, 0x100),
                              (0x01fff280, -32), (0x01fff280, 0x41)]:
            with self.assertRaisesRegex(ValueError, 'invalid'):
                extension_layout(dict(extension_ram=address, extension_bytes=size), [])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'source.nds'
        self.path.write_bytes(bytes(range(256))*4)
        self.fd = os.open(self.path,os.O_RDONLY)
        self.source = Source(self.fd)

    def tearDown(self):
        os.close(self.fd); self.temp.cleanup()

    def test_virtual_slices_and_expansion(self):
        original=self.path.read_bytes()
        rom=VirtualRom(self.source,2048)
        rom.add(10,b'abc');rom.add(1000,b'Q'*40);rom.finish()
        expected=bytearray(original+b'\xff'*1024)
        expected[10:13]=b'abc';expected[1000:1040]=b'Q'*40
        for a,b in [(0,2048),(9,14),(12,1010),(1010,1050),(2048,2048)]:
            self.assertEqual(b''.join(rom.blocks(a,b)),bytes(expected[a:b]))
        self.assertEqual(self.path.read_bytes(),original)

    def test_overlapping_patches_fail(self):
        rom=VirtualRom(self.source,1024);rom.add(10,b'1234');rom.add(11,b'23')
        with self.assertRaises(ValueError):rom.finish()

    def test_source_mutation_fails(self):
        self.path.write_bytes(b'new source')
        with self.assertRaises(ValueError):self.source.unchanged()

    def test_same_header_profiles_select_exact_hash_independent_of_order(self):
        original = self.path.read_bytes()
        common = dict(code_hex=original[12:16].hex(), revision=original[30],
                      source_size=len(original))
        known = dict(common, source_sha256=digest(original))
        other = dict(common, source_sha256='0'*64)
        progress = []
        self.assertIs(profile_for(self.source, [other, known], progress.append), known)
        self.assertTrue(progress)
        progress.clear()
        self.assertIs(profile_for(self.source, [known, other], progress.append), known)
        self.assertEqual(progress, [])  # Full identity read only once per source FD.
        with self.assertRaises(ValueError):
            profile_for(self.source, [known, dict(known)])
        self.assertIsNone(profile_for(self.source, [other, dict(other)]))

    def test_cached_identity_rejects_changed_source(self):
        self.assertEqual(self.source.sha256(), digest(self.path.read_bytes()))
        self.path.write_bytes(b'changed')
        with self.assertRaises(ValueError):self.source.sha256()

    def compact_fixture(self):
        # Non-file prefix and physically unordered file IDs. Include an empty
        # file and a movie that grows; every unindexed gap is erased padding.
        raw = bytearray(b'\xff'*4096)
        struct.pack_into('<II',raw,0x48,512,5*8)
        entries = [(1800,1803),(700,704),(1408,1413),(2048,2048),(2560,2564)]
        for i,(a,b) in enumerate(entries):
            struct.pack_into('<II',raw,512+8*i,a,b)
            raw[a:b] = bytes([i+1])*(b-a)
        oldfat = raw[512:552]
        table = bytearray(oldfat)
        relocated = [(1152,1155),(700,704),(1024,1029),(1280,1280),(1280,1287)]
        for i,(a,b) in enumerate(relocated):struct.pack_into('<II',table,8*i,a,b)
        spec = dict(prefix=1024,alignment=128,source_fat_sha256=digest(oldfat),
                    output_fat_sha256=digest(table),files_end=1287)
        movie = dict(id=4,output_offset=1280,output_bytes=7)
        self.path.write_bytes(raw)
        expected = bytearray(b'\xff'*len(raw));expected[:1024]=raw[:1024]
        expected[512:552]=table
        expected[1024:1029]=raw[1408:1413];expected[1152:1155]=raw[1800:1803]
        return raw,spec,[movie],expected

    def test_compacted_file_reads_cross_spans_and_preserve_source(self):
        original,spec,movies,expected = self.compact_fixture()
        backing = CompactedFiles(Source(self.fd),spec,movies)
        rng = random.Random(947)
        ranges = [(0,4096),(511,553),(699,705),(1028,1156),(4096,4096)]
        ranges += [sorted([rng.randrange(4097),rng.randrange(4097)]) for _ in range(100)]
        for a,b in ranges:self.assertEqual(backing.read(a,b-a),expected[a:b])
        image = VirtualRom(backing,4096);image.add(1280,b'newfilm');image.finish()
        expected[1280:1287]=b'newfilm'
        self.assertEqual(b''.join(image.blocks()),expected)
        self.assertEqual(self.path.read_bytes(),original)
        for a,n in [(-1,1),(4096,1),(1,-1)]:
            with self.assertRaises(ValueError):backing.read(a,n)

    def test_compaction_rejects_inconsistent_metadata(self):
        _,spec,movies,_ = self.compact_fixture()
        for key,value in [('alignment',64),('prefix',540),('source_fat_sha256','0'*64),
                          ('output_fat_sha256','0'*64),('files_end',1288)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                CompactedFiles(Source(self.fd),dict(spec,**{key:value}),movies)
        for changed in [[dict(movies[0],output_offset=1408)],movies*2,
                        [dict(movies[0],id=1)],[dict(movies[0],id=99)]]:
            with self.assertRaises(ValueError):CompactedFiles(Source(self.fd),spec,changed)

    def test_compaction_rejects_crossing_and_overlapping_source_files(self):
        for start,end in [(1000,1030),(1409,1415),(4090,4100)]:
            raw,spec,movies,_ = self.compact_fixture()
            struct.pack_into('<II',raw,512,start,end)
            spec['source_fat_sha256']=digest(raw[512:552]);self.path.write_bytes(raw)
            with self.assertRaises(ValueError):CompactedFiles(Source(self.fd),spec,movies)

    def test_unknown_and_changed_known_rom_stream_unchanged(self):
        # A recognizable game code alone never authorizes patching.
        original=bytearray(self.path.read_bytes());original[12:16]=b'BMTE';original[30]=0
        self.path.write_bytes(original)
        r,w=os.pipe()
        proc=subprocess.Popen([sys.executable,'-B',str(Path(__file__).with_name('stream.py')),
            str(self.fd),str(w),str(os.getpid())],pass_fds=(self.fd,w),stderr=subprocess.PIPE)
        os.close(w)
        with os.fdopen(r,'rb') as f:out=f.read()
        _,error=proc.communicate(timeout=10)
        self.assertEqual(proc.returncode,0,error)
        self.assertIn(b'FMV_AUTO_FALLBACK',error)
        self.assertEqual(out[:16],struct.pack('<Qii',len(original),0,0))
        self.assertEqual(out[16:-16],original)
        self.assertEqual(out[-16:],struct.pack('<Qii',len(original),0,8))
        self.assertEqual(self.path.read_bytes(),original)

    def test_mobiclip_reframe_preserves_audio_payload_and_keyframes(self):
        # Two synthetic frames; independent audio count and keyframe offset.
        raw=bytearray(52);raw[:4]=b'MODS';struct.pack_into('<I',raw,8,2)
        payloads=[b'\x00\x80movie-audio-A',b'\x00\x00movie-audio-B']
        offsets=[]
        for i,p in enumerate(payloads):
            offsets.append(len(raw));raw.extend(struct.pack('<I',len(p)<<14 | (i+1)));raw.extend(p)
        key_at=len(raw);raw.extend(struct.pack('<II',0,offsets[0]));struct.pack_into('<III',raw,36,key_at,key_at,1)
        rows=b''.join(struct.pack('<4I',0x43424453 | (0x8000 if i==0 else 0),6,20,i) for i in range(2))
        expected=bytearray(raw[:52])
        for i,p in enumerate(payloads):expected.extend(struct.pack('<I',(len(p)+16)<<14 | (i+1))+rows[i*16:i*16+16]+p)
        expected.extend(raw[key_at:]);struct.pack_into('<III',expected,32,len(payloads[0])+16,key_at+32,key_at+32)
        self.path.write_bytes(raw);source=Source(self.fd)
        spec=dict(source_offset=0,source_bytes=len(raw),source_sha256=digest(raw),descriptors=base64.b64encode(zlib.compress(rows)).decode(),frames=2,family='mobiclip',output_bytes=len(expected),output_sha256=digest(expected))
        self.assertEqual(movie(source,spec),expected)
        spec['source_sha256']='0'*64
        with self.assertRaises(ValueError):movie(source,spec)

    def test_registry_has_only_verified_generated_hooks_and_metadata(self):
        root=Path(__file__).parent
        registry=json.loads((root/'profiles.json').read_text())
        self.assertEqual(registry['version'],1)
        self.assertEqual({p['key'] for p in registry['profiles']},
                         {'NINO','NINO_EN10','SJ','CHRONO','FF12','SONIC',
                          'YQUP','YQUJ','AXFP','AXFJ','CSNP','C5RJ','BMTJ',
                          'ACBE0','ACBP0','ACBJ0','ACBJ1','YR9E0','YR9P0','YR9J0','YR9K0'})
        for p in registry['profiles']:
            self.assertEqual(p['assembled_sha256'],p['qualified_image_sha256'])
            for s in p['stubs']:self.assertEqual(digest((root/'guest'/s['file']).read_bytes()),s['sha256'])
            for m in p['movies']:
                rows=zlib.decompress(base64.b64decode(m['descriptors']))
                self.assertEqual(len(rows),m['frames']*16)
                for i in range(m['frames']):self.assertEqual(struct.unpack_from('<I',rows,i*16+12)[0],i)

    def test_later_mobiclip_quantizers_and_original_seek_points(self):
        raw=bytearray(52);raw[:4]=b'MODS';struct.pack_into('<I',raw,8,1)
        payload=b'\x00\x80VIDEO-AUDIO';raw.extend(struct.pack('<I',len(payload)<<14|3)+payload)
        at=len(raw);raw.extend(struct.pack('<II',0,52));struct.pack_into('<III',raw,36,0,at,1)
        for q in (12,43,48,161):
            rows=struct.pack('<4I',0x4342c453,6,q,0)
            out=reframe_movie(raw,'mobiclip',rows,1)
            self.assertEqual(out[72:72+len(payload)],payload)
            self.assertEqual(struct.unpack_from('<II',out,at+16),(0,52))
        for q in (11,162,65535):
            with self.assertRaises(ValueError):
                reframe_movie(raw,'mobiclip',struct.pack('<4I',0x4342c453,6,q,0),1)

    def test_vx_envelope_keeps_audio_timing_and_trailer(self):
        raw=bytearray(48);raw[:4]=b'VXDS';struct.pack_into('<I',raw,4,1)
        struct.pack_into('<III',raw,16,30<<16,27,32768)
        payload=b'VIDEO-AUDIO';raw.extend(struct.pack('<HH',len(payload)+2,5)+payload)
        ao=len(raw);raw.extend(b'AUDIO-TABLE');ko=len(raw);raw.extend(struct.pack('<II',0,48))
        struct.pack_into('<4I',raw,32,len(payload)+4,ao,ko,1)
        rows=struct.pack('<4I',0x31585646,4,27|(2<<16),0)
        out=reframe_movie(raw,'vx',rows,1)
        self.assertEqual(out[:32],raw[:32])
        self.assertEqual(struct.unpack_from('<HH',out,48),(len(payload)+18,5))
        self.assertEqual(out[68:68+len(payload)],payload)
        self.assertEqual(out[ao+16:ko+16],b'AUDIO-TABLE')
        self.assertEqual(struct.unpack_from('<II',out,ko+16),(0,48))
        with self.assertRaises(ValueError):reframe_movie(raw,'unknown',rows,1)

if __name__=='__main__':unittest.main()
