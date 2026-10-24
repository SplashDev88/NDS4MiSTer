# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import os
from pathlib import Path
import struct
import tempfile
import unittest
from prepare import Source, VirtualRom, CompactedFiles, digest
from stream_load import select_plan, transfer


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)/'source.nds'
        raw = bytearray(b'\xff'*4096)
        raw[12:16] = b'B2KJ'; raw[30] = 0
        struct.pack_into('<II', raw, 0x48, 512, 5*8)
        entries = [(1800,1803),(700,704),(1408,1413),(2048,2048),(2560,2564)]
        for i,(a,b) in enumerate(entries):
            struct.pack_into('<II',raw,512+8*i,a,b)
            raw[a:b] = bytes([i+1])*(b-a)
        table = bytearray(raw[512:552])
        relocated = [(1152,1155),(700,704),(1024,1029),(1280,1280),(1280,1287)]
        for i,(a,b) in enumerate(relocated):struct.pack_into('<II',table,8*i,a,b)
        self.profile = dict(code_hex=b'B2KJ'.hex(),revision=0,source_size=len(raw),output_size=len(raw),
                            source_sha256=digest(raw),key='synthetic',movies=[dict(id=4,output_offset=1280,output_bytes=7)],
                            compact_files=dict(prefix=1024,alignment=128,source_fat_sha256=digest(raw[512:552]),
                                               output_fat_sha256=digest(table),files_end=1287))
        self.raw = bytes(raw);self.path.write_bytes(raw)
        self.fd = os.open(self.path,os.O_RDONLY)
        self.source = Source(self.fd)

    def tearDown(self):
        os.close(self.fd);self.temp.cleanup()

    def assembled(self, source, profile, **kwargs):
        self.assertEqual(source.sha256(),profile['source_sha256'])
        image = VirtualRom(CompactedFiles(source,profile['compact_files'],profile['movies']),source.size)
        image.add(1280,b'newfilm');image.add(0,b'changed-header')
        return image.finish()

    def wire(self, source=None, profile=None, assembler=None):
        source=source or self.source;profile=profile or self.profile
        pieces=[];plan=select_plan(source,[profile]);self.assertIsNotNone(plan)
        transfer(source,plan,lambda b:pieces.append(bytes(b)),assembler=assembler or self.assembled)
        return b''.join(pieces)

    def decode(self, wire):
        size,error,op=struct.unpack_from('<Qii',wire);self.assertEqual((size,error,op),(4096,0,9))
        output=bytearray(b'\xff'*size);at=16;progress=[];prepared=False;complete=False
        while at<len(wire):
            offset,length,op=struct.unpack_from('<Qii',wire,at);at+=16
            if op==10:
                self.assertLessEqual(offset+length,size);output[offset:offset+length]=wire[at:at+length];at+=length
            elif op==7:progress.append(offset)
            elif op==11:self.assertFalse(prepared);self.assertEqual(progress[-1],size);prepared=True
            elif op==8:
                self.assertTrue(prepared);self.assertEqual(offset,size);self.assertEqual(at,len(wire));complete=True
            else:self.fail('Unknown record')
        self.assertTrue(complete);self.assertEqual(progress,sorted(progress))
        return bytes(output)

    def test_framed_image_matches_original_virtual_assembly(self):
        expected=b''.join(self.assembled(self.source,self.profile).blocks())
        self.assertEqual(self.decode(self.wire()),expected)
        self.assertEqual(self.path.read_bytes(),self.raw)

    def test_bulk_source_is_read_once_and_wholly_hashed(self):
        plan=select_plan(self.source,[self.profile]);read=self.source.read;calls=[]
        def counted(at,size):calls.append((at,size));return read(at,size)
        self.source.read=counted;pieces=[]
        # A prepared fixture prevents metadata rereads in the test oracle.
        image=self.assembled(Source(self.fd),self.profile)
        transfer(self.source,plan,lambda b:pieces.append(bytes(b)),assembler=lambda *a,**kw:image)
        self.assertEqual(calls,[(0,len(self.raw))])
        self.assertEqual(self.source.sha256(),digest(self.raw))
        self.assertEqual(self.decode(b''.join(pieces)),b''.join(image.blocks()))

    def test_wrong_full_hash_overwrites_every_provisional_byte_with_original(self):
        p=dict(self.profile,source_sha256='0'*64)
        def must_not_assemble(*args,**kwargs):self.fail('Unknown ROM must not install hooks')
        self.assertEqual(self.decode(self.wire(profile=p,assembler=must_not_assemble)),self.raw)

    def test_failed_hook_guard_also_restores_all_original_bytes(self):
        def fail(*args,**kwargs):raise ValueError('hook site differs')
        self.assertEqual(self.decode(self.wire(assembler=fail)),self.raw)

    def test_source_changes_never_get_a_completion_marker(self):
        plan=select_plan(self.source,[self.profile]);pieces=[]
        def emit(b):
            pieces.append(bytes(b))
            if len(pieces)==1:self.path.write_bytes(b'short')
        with self.assertRaises(ValueError):transfer(self.source,plan,emit,assembler=self.assembled)
        self.assertEqual(len(pieces),1)

    def test_file_table_and_ambiguous_plans_do_not_authorize_streaming(self):
        bad=dict(self.profile,compact_files=dict(self.profile['compact_files'],source_fat_sha256='0'*64))
        self.assertIsNone(select_plan(self.source,[bad]))
        self.assertIsNone(select_plan(self.source,[self.profile,self.profile]))
        self.assertIsNone(select_plan(self.source,[dict(self.profile,output_size=8192)]))


if __name__=='__main__':unittest.main()
