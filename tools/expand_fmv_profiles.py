#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline qualification of all MODS/VXDS files in exact, locally owned ROMs.

Decoder CSVs come from the native comparison tools, named KEY_FILEID.csv.
Output contains hashes/packet metadata only. ROM files are never modified.
This is a developer tool; runtime never discovers or enables unknown assets.
"""
import argparse
import base64
import copy
import csv
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

sys.path.insert(0, str(Path(__file__).parent/'standalone_host/fmv'))
from prepare import Source, assemble, digest, reframe_movie


def expand(profile, path, metadata, report):
    p = copy.deepcopy(profile)
    raw = path.read_bytes()
    assert digest(raw) == p['source_sha256'], 'original ROM identity differs'
    fat, size = struct.unpack_from('<II', raw, 0x48)
    entries = [struct.unpack_from('<II', raw, fat+i*8) for i in range(size//8)]
    old = {m['id']: m for m in p['movies']}
    p['movies'] = []
    payloads = {}
    for fid, (a,b) in enumerate(entries):
        magic = raw[a:a+4]
        if magic not in (b'MODS', b'VXDS'): continue
        asset = raw[a:b]; vx = magic == b'VXDS'
        count,w,h = struct.unpack_from('<III', asset, 4 if vx else 8)
        assert (w,h) == (256,192)
        key = 'NINO' if p['key']=='NINO_EN10' else p['key']
        rows = list(csv.DictReader((metadata/(key+'_'+str(fid)+'.csv')).open()))
        assert len(rows)==count
        # Only two decoder contexts can be active concurrently. Reuse a
        # plane's context across movies; sequence zero resets reference frames.
        if key in ('SJ','CHRONO'): stream=0
        elif key=='NINO': stream=2 if fid==9242 else 1
        else:
            # Names are qualification input, not runtime matching criteria.
            names=report['names'][p['key']]
            name=names[str(fid)]
            stream=2 if (key=='FF12' and name.endswith('_L.vx')) or (key=='SONIC' and name.startswith('BS_')) else 1
        desc=bytearray();pos=48 if vx else 52
        for frame,r in enumerate(rows):
            assert int(r['frame'])==frame
            packet=asset[pos+4:]
            bits=int(r['bits']); quant=int(r['quantizer'])
            keybit=0 if vx else struct.unpack_from('<H',packet)[0]&0x8000
            consumed=((bits+15)//16)*2+(-4 if vx else 4 if keybit else 0)
            if vx:
                assert quant==struct.unpack_from('<I',asset,20)[0]
                pos+=struct.unpack_from('<H',asset,pos)[0]+2
            else: pos+=(struct.unpack_from('<I',asset,pos)[0]>>14)+4
            desc.extend(struct.pack('<4I',0x31585646 if vx else 0x43424453|keybit,consumed,quant|(stream<<16),frame))
        if fid in old:
            assert bytes(desc)==zlib.decompress(base64.b64decode(old[fid]['descriptors'])), 'existing descriptors changed'
        family='vx' if vx else 'mobiclip'
        transformed=reframe_movie(asset,family,desc,count)
        # Independent inverse-envelope audit: every original video/audio byte,
        # audio count, header timing value and keyframe identity is retained.
        op=np=48 if vx else 52
        offsets={}
        for frame in range(count):
            oz=(struct.unpack_from('<H',asset,op)[0]+2) if vx else ((struct.unpack_from('<I',asset,op)[0]>>14)+4)
            nz=(struct.unpack_from('<H',transformed,np)[0]+2) if vx else ((struct.unpack_from('<I',transformed,np)[0]>>14)+4)
            assert nz==oz+16 and asset[op+4:op+oz]==transformed[np+20:np+nz]
            audio_old=struct.unpack_from('<H',asset,op+2)[0] if vx else struct.unpack_from('<I',asset,op)[0]&16383
            audio_new=struct.unpack_from('<H',transformed,np+2)[0] if vx else struct.unpack_from('<I',transformed,np)[0]&16383
            assert audio_old==audio_new
            offsets[op]=np;op+=oz;np+=nz
        ao,ko,kc=struct.unpack_from('<III',asset,36);na,nk,nc=struct.unpack_from('<III',transformed,36)
        assert asset[:32]==transformed[:32] and kc==nc
        assert transformed[np:nk]==asset[op:ko]
        for i in range(kc):
            fr,at=struct.unpack_from('<II',asset,ko+i*8)
            assert struct.unpack_from('<II',transformed,nk+i*8)==(fr,offsets[at])
        assert transformed[nk+kc*8:]==asset[ko+kc*8:]
        m=dict(id=fid,family=family,source_offset=a,source_bytes=b-a,source_sha256=digest(asset),output_bytes=len(transformed),output_sha256=digest(transformed),frames=count,descriptors=base64.b64encode(zlib.compress(desc,9)).decode())
        payloads[fid]=transformed;p['movies'].append(m)
    assert set(old)<=set(payloads), 'lost existing movie'
    # Obtain unchanged patched ARM9/overlays from the accepted profile.
    with path.open('rb') as f:
        previous=assemble(Source(f.fileno()),profile)
        arm=b''.join(previous.blocks(profile['arm9_offset'],profile['arm9_offset']+profile['arm9_bytes']))
        ovs=[b''.join(previous.blocks(v['output_offset'],v['output_offset']+v['output_bytes'])) for v in profile['overlays']]
    align=lambda n:(n+511)&~511
    if p['key'].startswith('NINO'):
        prefix=0x21c200 if p['key']=='NINO' else 0x21c000;cursor=prefix;previous_end=prefix;table=bytearray(raw[fat:fat+size])
        replacements={m['id']:m for m in p['movies']}
        for fid,(a,b) in sorted(enumerate(entries),key=lambda x:(*x[1],x[0])):
            if a<prefix:
                assert b<=prefix and fid not in replacements
                continue
            assert a>=previous_end and not set(raw[previous_end:a])-{255}, 'non-padding outside FAT'
            previous_end=b;cursor=(cursor+127)&~127
            n=replacements[fid]['output_bytes'] if fid in replacements else b-a
            if fid in replacements:replacements[fid]['output_offset']=cursor
            struct.pack_into('<II',table,8*fid,cursor,cursor+n);cursor+=n
        assert not set(raw[previous_end:])-{255}, 'unindexed trailer'
        p['compact_files']=dict(prefix=prefix,alignment=128,source_fat_sha256=digest(raw[fat:fat+size]),output_fat_sha256=digest(table),files_end=cursor)
        cursor=align(cursor)
    else:
        start=(max(b for a,b in entries)+4095)&~4095
        cursor=start
        for m in p['movies']:cursor=align(cursor+m['output_bytes'])
        projected=align(cursor+len(arm))
        for data in ovs:projected=align(projected+len(data))
        # Avoid doubling the cartridge transfer for a small boundary crossing.
        # Every movie is redirected through FAT, so an abandoned old movie span
        # can hold one other reconstructed movie. Source reads still use the
        # immutable original FD. The complete FAT payload audit below verifies
        # that no live file is overwritten by this reuse.
        relocated=None
        if projected>len(raw):
            choices=[]
            for m in p['movies']:
                if align(m['output_bytes'])<projected-len(raw):continue
                for hole in p['movies']:
                    if hole['id']!=m['id'] and hole['source_bytes']>=m['output_bytes'] and hole['source_offset']%512==0:
                        choices.append((m['output_bytes'],hole['source_bytes'],m['id'],hole['id']))
            if choices:
                _,_,fid,owner=min(choices)
                relocated=next(m for m in p['movies'] if m['id']==fid)
                hole=next(m for m in p['movies'] if m['id']==owner)
                relocated['output_offset']=hole['source_offset']
        cursor=start
        for m in p['movies']:
            if m is relocated:continue
            m['output_offset']=cursor;cursor=align(cursor+m['output_bytes'])
        assert not set(raw[start:])-{255}
    p['arm9_offset']=cursor;cursor=align(cursor+len(arm))
    for ov,data in zip(p['overlays'],ovs):
        ov['output_offset']=cursor;cursor=align(cursor+len(data))
    p['used']=cursor
    assert cursor<=464*1024*1024
    outsize=128*1024
    while outsize<max(cursor,len(raw)):outsize*=2
    p['output_size']=outsize;p['capacity']=outsize.bit_length()-18
    with path.open('rb') as f:
        virtual=assemble(Source(f.fileno()),p);h=hashlib.sha256()
        for block in virtual.blocks():h.update(block)
        header=b''.join(virtual.blocks(0,512));newfat=b''.join(virtual.blocks(fat,fat+size))
        # Audit all regular file contents, not just the movies.
        overlay_files={v['id']:data for v,data in zip(p['overlays'],ovs)}
        # Overlay ID and FAT ID are distinct in general.
        ot=struct.unpack_from('<I',raw,0x50)[0]
        overlay_files={struct.unpack_from('<I',raw,ot+i*32+24)[0]:data for i,data in overlay_files.items()}
        for fid,(a,b) in enumerate(entries):
            x,y=struct.unpack_from('<II',newfat,fid*8)
            actual=b''.join(virtual.blocks(x,y))
            assert actual==payloads.get(fid,overlay_files.get(fid,raw[a:b])), ('file content',fid)
        limit=(464 if outsize>256*1024*1024 else 252)*1024*1024
        assert all(block==b'\xff'*len(block) for block in virtual.blocks(min(limit,outsize),outsize))
    p['qualified_image_sha256']=p['assembled_sha256']=h.hexdigest()
    report['profiles'][p['key']]=dict(movies=len(p['movies']),frames=sum(m['frames'] for m in p['movies']),files_verified=len(entries),used=cursor,headroom=limit-cursor,virtual_header_crc32=hex(zlib.crc32(header[:0x160])),virtual_sha256=h.hexdigest(),all_movie_payloads_audio_counts_and_seek_tables_preserved=True)
    return p


def main():
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('--inventory',type=Path,required=True);a.add_argument('--metadata',type=Path,required=True);a.add_argument('--profiles',type=Path,required=True);a.add_argument('--output',type=Path,required=True);a.add_argument('--report',type=Path,required=True);args=a.parse_args()
    inv=json.loads(args.inventory.read_text());registry=json.loads(args.profiles.read_text());report=dict(profiles={},names={k:{str(m['id']):m['path'] for m in g['movies']} for k,g in inv.items()})
    jp={m['id']:m['source_sha256'] for m in inv['NINO']['movies']}
    en={m['id']:m['source_sha256'] for m in inv['NINO_EN10']['movies']}
    assert jp==en, 'English movie bytes differ; collect separate decoder metadata'
    out=[]
    for p in registry['profiles']:
        result=expand(p,Path(inv[p['key']]['rom']),args.metadata,report);out.append(result);print(p['key'],report['profiles'][p['key']],flush=True)
    registry['profiles']=out;args.output.write_text(json.dumps(registry,indent=2)+'\n');args.report.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
