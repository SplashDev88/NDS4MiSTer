# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic geometry and atomic loader tests; no game assets or code."""
import copy
import hashlib
import struct
import unittest
from ndspy import lz10
from prepare import Source
from guest_byte_patch import assemble
from gx_spans import spans, pack, semantic, transform, group_spans, polygons, split_independent_polygons
from gx_model import inspect_model
from gx_span_asset import transform_archive
import test_arm9_autoload_patch as boot_fixtures

sha = lambda b: hashlib.sha256(b).hexdigest()


def geometry_fixture(color=31):
    return pack([(0x20,(color,)), (0x22,(0x100020,)), (0x40,(0,)),
        (0x23,(1 | (2<<16),3)), (0x25,(4 | (5<<16),)), (0x26,(6 | (7<<16),)), (0x41,()),
        (0x40,(0,)), (0x27,(8 | (9<<16),)), (0x28,(1 | (2<<10) | (3<<20),)),
        (0x23,(0xffff | (0xfffe<<16),0xfffd)), (0x41,()), (0x20,(0x1234,))])


def archive_fixture(color=31):
    dl = geometry_fixture(color); model = bytearray(120)+dl
    struct.pack_into('<5I',model,0,len(model),64,64,64,len(model))
    model[0x17:0x1a]=bytes([1,1,1])
    struct.pack_into('<BBHHHI',model,64,0,1,40,8,0,0x17f)
    struct.pack_into('<HHI',model,80,4,8,40)
    model[88:104]=b'synthetic-shape\0'
    struct.pack_into('<HHIII',model,104,0,16,0,16,len(dl))
    prefix=bytearray(68)
    struct.pack_into('<4sHHIHHI',prefix,0,b'BMD0',0xfeff,2,len(prefix)+len(model),16,1,20)
    struct.pack_into('<4sI',prefix,20,b'MDL0',len(prefix)+len(model)-20)
    model=bytes(prefix+model); body=model+b'\xff'*(-len(model)%4)
    start=len(body); body+=b'UNCHANGED-MEMBER'; end=len(body); body+=b'\xff'*(-len(body)%4)
    fat=struct.pack('<4sIHH4I',b'BTAF',28,2,0,0,len(model),start,end)
    blocks=fat+b'BTNF'+struct.pack('<I',16)+bytes(8)+b'GMIF'+struct.pack('<I',len(body)+8)+body
    arc=struct.pack('<4sHHIHH',b'NARC',0xfeff,0x100,16+len(blocks),16,3)+blocks
    return lz10.compress(arc),model


class SpanTests(unittest.TestCase):
    def test_skipping_first_primitive_preserves_remaining_geometry_and_final_state(self):
        dl=geometry_fixture(); ss=spans(dl)
        self.assertEqual(len(ss),2)
        self.assertEqual(semantic(b''.join(s['data'] for s in ss)),semantic(dl))
        events,state=semantic(ss[1]['data'])
        self.assertEqual([v[1] for v in events if v[0]=='v'],[(6,8,9),(7,10,12),(-1,-2,-3)])
        self.assertEqual(state,([-1,-2,-3],0x1234,0x100020))
        self.assertEqual(ss[1]['lo'],[-1,-2,-3]); self.assertEqual(ss[1]['hi'],[7,10,12])

    def test_unknown_unsupported_and_incomplete_state_is_rejected(self):
        bad=[pack([(0x10,(1,))]),pack([(0x40,(0,)),(0x25,(0,)),(0x41,())]),
             pack([(0x40,(0,)),(0x41,())]),pack([(0x23,(0,0))]),
             pack([(0x40,(0,)),(0x40,(0,))]),b'\x23',bytes([0xff,0,0,0])]
        for data in bad:
            with self.subTest(data=data.hex()),self.assertRaises(ValueError):spans(data)


class AtomicAssetTests(unittest.TestCase):
    setUp=boot_fixtures.Arm9AutoloadTests.setUp
    tearDown=boot_fixtures.Arm9AutoloadTests.tearDown
    run_image=boot_fixtures.Arm9AutoloadTests.run_image

    def setup_asset(self):
        data,model=archive_fixture(); raw=bytearray(self.raw); fat=(len(raw)+511)&~511; asset=fat+512
        raw.extend(bytes(asset-len(raw))); raw.extend(data)
        struct.pack_into('<II',raw,0x48,fat,8); struct.pack_into('<II',raw,fat,asset,asset+len(data))
        self.path.write_bytes(raw); self.raw=bytes(raw); self.source=Source(self.fd)
        m=copy.deepcopy(self.manifest); m.update(delivery='append-decoded-arm9-gx-spans-v1',
            rom_sha256=sha(raw),header_sha1=hashlib.sha1(raw[:352]).hexdigest())
        second=copy.deepcopy(m['patches'][0]); second.update(id='two',addr='0x01ff8050',
            expect='0000a0e1'*2,replace='0100a0e10200a0e1',data_guards=[]); m['patches'].append(second)
        cfg=dict(transform='narc-model-gx-spans-v1',file_id=0,member=0,member_sha256=sha(model),
            model_offset=68,stored_sha256=sha(data)); output,_=transform_archive(data,cfg)
        cfg['output_sha256']=sha(output); m['asset']=cfg
        return m,output,fat,asset

    def test_code_and_asset_are_atomic_and_source_is_unchanged(self):
        m,output,fat,original=self.setup_asset(); image,report=assemble(self.source,m,['one','two'])
        self.assertEqual(report['state'],'applied_to_virtual_image'); got=b''.join(image.blocks())
        lo,hi=struct.unpack_from('<II',got,fat)
        self.assertGreaterEqual(lo,len(self.raw)); self.assertEqual(got[lo:hi],output)
        self.assertEqual(got[original:len(self.raw)],self.raw[original:])
        self.assertEqual(self.path.read_bytes(),self.raw)
        self.assertIn(b'UNCHANGED-MEMBER',lz10.decompress(output))

    def test_partial_unknown_and_disabled_selections_leave_whole_original(self):
        m,_,_,_=self.setup_asset()
        for ids in [[],['one'],['two'],['unknown'],['one','two','unknown']]:
            got,report=self.run_image(m,ids); self.assertEqual(got,self.raw); self.assertEqual(report['applied'],[])

    def test_resource_failure_rolls_back_code_and_metadata(self):
        m,_,_,_=self.setup_asset()
        for key,value in [('stored_sha256','0'*64),('member_sha256','0'*64),('output_sha256','0'*64),
                          ('member',2),('member',True),('model_offset',True),('model_offset',999999),
                          ('file_id',True),('file_id',1),('transform','unknown')]:
            bad=copy.deepcopy(m); bad['asset'][key]=value
            with self.subTest(key=key,value=value):
                got,report=self.run_image(bad,['one','two']); self.assertEqual(got,self.raw)
                self.assertEqual(report['state'],'skipped'); self.assertEqual(report['applied'],[])

    def test_bad_code_guard_prevents_resource_change(self):
        m,_,_,_=self.setup_asset(); m['patches'][1]['expect']='ff'*8
        got,report=self.run_image(m,['one','two']); self.assertEqual(got,self.raw); self.assertEqual(report['applied'],[])

    def setup_two_assets(self):
        m,output,fat,original=self.setup_asset()
        raw=bytearray(self.raw)
        second,model=archive_fixture(color=1023)
        raw.extend(bytes(-len(raw)%4)); start=len(raw); raw.extend(second)
        struct.pack_into('<I',raw,0x4c,16)
        struct.pack_into('<II',raw,fat+8,start,len(raw))
        self.path.write_bytes(raw); self.raw=bytes(raw); self.source=Source(self.fd)
        m.update(rom_sha256=sha(raw),header_sha1=hashlib.sha1(raw[:352]).hexdigest())
        first=m.pop('asset'); cfg=dict(first,file_id=1,stored_sha256=sha(second),
                                     member_sha256=sha(model))
        second_output,_=transform_archive(second,cfg); cfg['output_sha256']=sha(second_output)
        m['assets']=[first,cfg]
        return m,[output,second_output],fat

    def test_two_resources_keep_both_fat_rows_and_payloads(self):
        m,outputs,fat=self.setup_two_assets(); got,report=self.run_image(m,['one','two'])
        self.assertEqual(report['state'],'applied_to_virtual_image')
        rows=[struct.unpack_from('<II',got,fat+8*i) for i in range(2)]
        self.assertLessEqual(rows[0][1],rows[1][0])
        self.assertNotEqual(outputs[0],outputs[1])
        for (lo,hi),output in zip(rows,outputs):
            self.assertGreaterEqual(lo,len(self.raw)); self.assertEqual(got[lo:hi],output)
        self.assertEqual([a['file_id'] for a in report['assets']],[0,1])
        self.assertEqual(self.path.read_bytes(),self.raw)

    def test_completed_resources_service_the_existing_reader_deadline(self):
        m,_,_=self.setup_two_assets(); verification=[]
        self.source.sha256(verification.append)
        self.source=Source(self.fd)
        progress=[]
        _,report=assemble(self.source,m,['one','two'],progress.append)
        self.assertEqual(report['state'],'applied_to_virtual_image')
        self.assertEqual(progress,verification+[self.source.size]*2)
        m['assets'][1]['output_sha256']='0'*64; progress=[]
        self.source=Source(self.fd)
        image,report=assemble(self.source,m,['one','two'],progress.append)
        self.assertEqual(report['state'],'skipped')
        self.assertEqual(progress,verification+[self.source.size])
        self.assertEqual(b''.join(image.blocks()),self.raw)

    def test_second_resource_failure_rolls_back_everything(self):
        m,_,_=self.setup_two_assets()
        for key in ['stored_sha256','member_sha256','output_sha256']:
            bad=copy.deepcopy(m); bad['assets'][1][key]='0'*64
            with self.subTest(key=key):
                got,report=self.run_image(bad,['one','two']); self.assertEqual(got,self.raw)
                self.assertEqual(report['state'],'skipped'); self.assertEqual(report['applied'],[])
                self.assertNotIn('assets',report); self.assertNotIn('asset',report)

    def test_ambiguous_duplicate_or_invalid_resource_lists_fail_closed(self):
        m,_,_=self.setup_two_assets()
        bads=[dict(m,asset=m['assets'][0]),dict(m,assets=[]),dict(m,assets={}),
              dict(m,assets=[m['assets'][0]]*2),dict(m,assets=[None]),
              dict(m,assets=[dict(m['assets'][0],file_id=True)]),
              dict(m,assets=[dict(m['assets'][0],file_id=i) for i in range(33)])]
        for bad in bads:
            got,report=self.run_image(bad,['one','two']); self.assertEqual(got,self.raw)
            self.assertEqual(report['applied'],[])


def v2_model_fixture(texture=False, scale_shift=6):
    first=geometry_fixture(); second=pack([(0x21,(123,))])+geometry_fixture(1023)
    model=bytearray(160)+first+second
    struct.pack_into('<5I',model,0,len(model),64,64,64,len(model))
    model[0x17:0x1a]=bytes([1,2,2])
    struct.pack_into('<2I',model,28,4096<<scale_shift,4096>>scale_shift)
    struct.pack_into('<BBHHHI',model,64,0,2,64,8,0,0x17f)
    struct.pack_into('<HH2I',model,84,4,12,64,80)
    model[96:112]=b'plain-shape\0\0\0\0\0'
    model[112:128]=b'lit-shape\0\0\0\0\0\0\0'
    struct.pack_into('<HHIII',model,128,0,16,0,32,len(first))
    struct.pack_into('<HHIII',model,144,0,16,0,16+len(first),len(second))
    prefix=bytearray(68)
    struct.pack_into('<4sHHIHHI',prefix,0,b'BMD0',0xfeff,2,68+len(model),16,1,20)
    struct.pack_into('<4sI',prefix,20,b'MDL0',48+len(model))
    prefix[29]=1;struct.pack_into('<I',prefix,48,48)
    data=bytes(prefix+model)
    if texture:
        tex=b'TEX0'+struct.pack('<I',24)+b'UNCHANGEDTEXTURE'
        data=bytearray(data[:16])+struct.pack('<2I',24,len(data)+4)+data[20:]+tex
        struct.pack_into('<H',data,14,2);struct.pack_into('<I',data,8,len(data))
        return bytes(data),72
    return data,68


class SpanV2Tests(unittest.TestCase):
    def test_independent_polygon_splitting_preserves_order_attributes_and_vertex_count(self):
        for mode,size in [(0,3),(1,4)]:
            cmds=[(0x40,(mode,))]
            for i in range(12*size):
                xyz=((32760+i*3)&65535,(i*911)&65535,(-i*701)&65535)
                cmds += [(0x20,(i*13,)),(0x22,(i*179,)),
                         (0x23,(xyz[0]|(xyz[1]<<16),xyz[2]))]
            cmds += [(0x41,()),(0x20,(255,)),(0x22,(0x12345678,))]
            original=pack(cmds);changed=split_independent_polygons(original,3)
            self.assertEqual(polygons(changed),polygons(original))
            self.assertEqual(len(spans(changed)),4)
            self.assertEqual(sum(e[0]=='v' for e in semantic(changed)[0]),12*size)
            self.assertEqual(semantic(changed)[1],semantic(original)[1])

    def test_strips_are_not_restarted_or_duplicated(self):
        for mode in [2,3]:
            cmds=[(0x20,(31,)),(0x22,(17,)),(0x40,(mode,))]
            cmds += [(0x23,(i|(i<<16),i)) for i in range(40)]
            cmds.append((0x41,()));original=pack(cmds)
            self.assertEqual(split_independent_polygons(original,2),original)

    def test_normalized_header_and_error_margin(self):
        data,offset=v2_model_fixture()
        for normalization in range(4):
            output,_,segments=transform(data,offset,{'shape_indices':[0]},normalization)
            descriptor=offset+128
            at=descriptor+struct.unpack_from('<I',output,descriptor+8)[0]
            self.assertEqual(struct.unpack_from('<IHBB',output,at),(0x334c5344,2,6,normalization))
            for index,s in enumerate(segments[0]):
                expected=(sum(max(abs(a),abs(b)) for a,b in zip(s['lo'],s['hi']))+32)*(2 if normalization else 1)
                self.assertEqual(struct.unpack_from('<I',output,at+8+24*index+20)[0],expected)
        for invalid in (-1,4,True,'1'):
            with self.assertRaises(ValueError):transform(data,offset,{'shape_indices':[0]},invalid)

    def test_selective_shape_and_texture_are_preserved(self):
        for texture in (False,True):
            for shift in (3,4,5,6,7):
                data,offset=v2_model_fixture(texture,shift)
                output,stats,segments=transform(data,offset,{'shape_indices':[0]})
                self.assertEqual([s['shape'] for s in stats],[0])
                old=inspect_model(data,offset)
                a=old['shapes'][1];descriptor=offset+a['descriptor_offset']
                self.assertEqual(data[descriptor:descriptor+16],output[descriptor:descriptor+16])
                lo=offset+a['display_list_offset'];hi=lo+a['display_list_bytes']
                self.assertEqual(data[lo:hi],output[lo:hi])
                descriptor=offset+old['shapes'][0]['descriptor_offset']
                at=descriptor+struct.unpack_from('<I',output,descriptor+8)[0]
                self.assertEqual(struct.unpack_from('<IHH',output,at),(0x324c5344,2,shift))
                self.assertEqual(segments[1],[])
                if texture:
                    oldtex=struct.unpack_from('<I',data,20)[0];newtex=struct.unpack_from('<I',output,20)[0]
                    self.assertEqual(data[oldtex:],output[newtex:])
                    self.assertEqual(newtex-oldtex,len(output)-len(data))

    def test_grouping_preserves_geometry_and_encloses_every_primitive(self):
        original=spans(geometry_fixture())
        grouped=group_spans(original,2)
        self.assertEqual(semantic(grouped[0]['data']),semantic(geometry_fixture()))
        for item in original:
            self.assertTrue(all(a<=b for a,b in zip(grouped[0]['lo'],item['lo'])))
            self.assertTrue(all(a>=b for a,b in zip(grouped[0]['hi'],item['hi'])))
        data,offset=v2_model_fixture()
        output,stats,_=transform(data,offset,{'shape_indices':[0],'group_size':2})
        self.assertEqual(output,data)
        self.assertEqual(stats,[])

    def test_unsupported_shapes_and_bad_options_fail_closed(self):
        data,offset=v2_model_fixture()
        for options in [{},{'shape_indices':[1]},{'shape_indices':[]},
                        {'shape_indices':[True]},{'shape_indices':[0,0]},
                        {'shape_indices':[2]},{'shape_indices':[0],'group_size':0},
                        {'shape_indices':[0],'group_size':True},{'unknown':1}]:
            with self.subTest(options=options),self.assertRaises(ValueError):transform(data,offset,options)
        bad=bytearray(data);struct.pack_into('<I',bad,offset+28,123456)
        with self.assertRaises(ValueError):transform(bytes(bad),offset,{'shape_indices':[0]})

    def test_bad_container_offsets_and_unknown_blocks_are_rejected(self):
        data,offset=v2_model_fixture(True)
        for at,value,fmt in [(8,len(data)-1,'I'),(16,28,'I'),(20,len(data)+4,'I'),(33,2,'B'),(52,44,'I')]:
            bad=bytearray(data);struct.pack_into('<'+fmt,bad,at,value)
            with self.subTest(at=at),self.assertRaises(ValueError):transform(bytes(bad),offset,{'shape_indices':[0]})
        bad=bytearray(data);at=struct.unpack_from('<I',bad,20)[0];bad[at:at+4]=b'BAD0'
        with self.assertRaises(ValueError):transform(bytes(bad),offset,{'shape_indices':[0]})


if __name__=='__main__':unittest.main()
