#!/usr/bin/env python3
"""Verify that a release host changes only its version and equivalent string pointers."""
from pathlib import Path
import argparse,hashlib,json,struct

def sections(data):
    assert data[:7]==b'\x7fELF\x01\x01\x01'
    h=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    entries=[struct.unpack_from('<10I',data,h[6]+i*h[11]) for i in range(h[12])]
    s=entries[h[13]];names=data[s[4]:s[4]+s[5]]
    return {names[s[0]:].split(b'\0',1)[0].decode():(s,data[s[4]:s[4]+s[5]]) for s in entries if s[1]!=8}

def pointed_string(data,entries,address):
    s=next(s for s,b in entries.values() if s[3]<=address<s[3]+s[5])
    offset=s[4]+address-s[3]
    return data[offset:].split(b'\0',1)[0]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ['reference','host','output']:ap.add_argument('--'+n,type=Path,required=True)
    args=ap.parse_args();old=args.reference.read_bytes();new=args.host.read_bytes()
    a,b=sections(old),sections(new);assert a.keys()==b.keys()
    changed=[n for n in a if a[n]!=b[n]]
    assert set(changed)=={'.note.gnu.build-id','.rodata','.data.rel.ro'}
    assert old.count(b'NDS4MiSTer v1.0.3\0')==1
    assert a['.rodata'][1].replace(b'NDS4MiSTer v1.0.3\0',b'NDS4MiSTer v1.0.4\0')==b['.rodata'][1]
    # GCC shares standalone "3"/"4" menu strings with the suffix of the
    # version label. Relocations may move, but their string values must not.
    s,prior=a['.data.rel.ro'];t,current=b['.data.rel.ro'];assert s==t
    pointers=[]
    for offset in range(0,len(prior),4):
        x,y=prior[offset:offset+4],current[offset:offset+4]
        if x!=y:
            xp,yp=struct.unpack('<I',x)[0],struct.unpack('<I',y)[0]
            xs,ys=pointed_string(old,a,xp),pointed_string(new,b,yp)
            assert xs==ys and xs in (b'3',b'4')
            pointers.append(dict(offset=offset,before=xp,after=yp,value=xs.decode()))
    assert len(pointers)==4
    normalized=bytearray(new)
    for n in changed:
        sh,data=a[n];assert sh==b[n][0];normalized[sh[4]:sh[4]+sh[5]]=data
    assert bytes(normalized)==old
    assert all(a[n]==b[n] for n,(s,data) in a.items() if s[2]&4)
    result=dict(baseline_sha256=hashlib.sha256(old).hexdigest(),release_sha256=hashlib.sha256(new).hexdigest(),
        version_only_semantic_change=True,changed_sections=changed,equivalent_string_pointers=pointers,
        all_other_bytes_identical=True,executable_sections_identical=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

if __name__=='__main__':main()
