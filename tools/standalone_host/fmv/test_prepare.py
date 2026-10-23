# SPDX-License-Identifier: GPL-3.0-or-later
import base64
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
from prepare import Source, VirtualRom, movie, digest


class PrepareTests(unittest.TestCase):
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
        self.assertEqual(len(registry['profiles']),5)
        for p in registry['profiles']:
            self.assertEqual(p['assembled_sha256'],p['qualified_image_sha256'])
            for s in p['stubs']:self.assertEqual(digest((root/'guest'/s['file']).read_bytes()),s['sha256'])
            for m in p['movies']:
                rows=zlib.decompress(base64.b64decode(m['descriptors']))
                self.assertEqual(len(rows),m['frames']*16)
                for i in range(m['frames']):self.assertEqual(struct.unpack_from('<I',rows,i*16+12)[0],i)

if __name__=='__main__':unittest.main()
