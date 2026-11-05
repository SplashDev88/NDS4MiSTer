#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce an authored Thumb helper inside a guarded existing function extent.

No ROM access or deployment. Build addresses and table identities come from a
reviewed manifest. Any compiler/link output drift fails its expected hash.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def elf(path):
    b=path.read_bytes()
    assert b[:7]==b'\x7fELF\x01\x01\x01' and struct.unpack_from('<H',b,18)[0]==40
    off=struct.unpack_from('<I',b,32)[0];size,count,strings=struct.unpack_from('<3H',b,46)
    rows=[struct.unpack_from('<10I',b,off+i*size) for i in range(count)]
    names=b[rows[strings][4]:rows[strings][4]+rows[strings][5]]
    sections={names[r[0]:].split(b'\0')[0].decode():r for r in rows}
    text=sections['.text'];body=bytearray(b[text[4]:text[4]+text[5]])
    symbols=[]
    sym=sections['.symtab'];st=rows[sym[6]];strings=b[st[4]:st[4]+st[5]]
    for at in range(sym[4],sym[4]+sym[5],16):
        name,value,length,info,other,section=struct.unpack_from('<IIIBBH',b,at)
        symbols.append((strings[name:].split(b'\0')[0].decode(),section))
    rel=sections.get('.rel.text');relocs=[]
    if rel:
        for at in range(rel[4],rel[4]+rel[5],8):
            offset,info=struct.unpack_from('<II',b,at)
            relocs.append((offset,info&255,symbols[info>>8]))
    return body,relocs


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('manifest',type=Path)
    ap.add_argument('--output',type=Path,required=True);ap.add_argument('--clang',default='clang');a=ap.parse_args()
    m=json.loads(a.manifest.read_text())['build'];assert m['recipe']=='compact-oam-and-cull-thumb-v1'
    sources=Path(__file__).resolve().parent/'guest_code';bodies=[];commands=[]
    with tempfile.TemporaryDirectory() as tmp:
        for source,defines in [('oam_compact.c',m['oam_defines']),('course_span_cull.c',m['cull_defines'])]:
            target=Path(tmp)/(source+'.o');cmd=[a.clang,'--target=arm-none-eabi','-march=armv5te','-mthumb','-Oz','-ffreestanding','-fno-builtin','-fwrapv','-fno-strict-aliasing']
            assert all(k.replace('_','').isalnum() and int(v,0)>=0 for k,v in defines.items())
            cmd+=['-D'+k+'='+v for k,v in sorted(defines.items())]+['-c',str(sources/source),'-o',str(target)]
            subprocess.run(cmd,check=True);commands.append(cmd);bodies.append(elf(target))
    (oam,relocs),(helper,helper_relocs)=bodies;assert not helper_relocs
    entry=int(m['entry'],0);thumb=entry+8;mul=thumb+len(oam)
    assert entry%4==0 and len(oam)%4==0
    for offset,kind,symbol in relocs:
        assert kind==10 and symbol==('__aeabi_lmul',0)
        delta=mul-(thumb+offset+4);assert delta%2==0 and -0x400000<=delta<0x400000
        struct.pack_into('<HH',oam,offset,0xf000|((delta>>12)&0x7ff),0xf800|((delta>>1)&0x7ff))
    stub=bytes.fromhex('7847c046')+struct.pack('<5I',0xe00c0390,0xe02cc192,0xe0810092,0xe081100c,0xe12fff1e)
    blob=struct.pack('<2I',0xe28fc001,0xe12fff1c)+oam+stub+helper
    padding=m.get('padding_bytes',0)
    assert type(padding) is int and padding in (0,2,4)
    blob+=bytes.fromhex('c046')*(padding//2)
    assert len(blob)==m['extent_bytes'] and hashlib.sha256(blob).hexdigest()==m['expected_sha256'],'Compiler output differs from qualified bytes'
    with a.output.open('xb') as f:f.write(blob)
    print(json.dumps(dict(bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest(),entry=hex(entry),cull_entry=hex(mul+len(stub)+1))))


if __name__=='__main__':main()
