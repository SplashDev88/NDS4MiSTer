#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only packed GX list census; coordinates, never a timing/safety approval.

Parameter counts and vertex updates follow GPU3D.cpp. Reset known coordinates
at each list boundary; never infer inherited hardware state from another list.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import struct


def require(ok, message):
 if not ok: raise ValueError(message)

COUNTS={0:0,0x10:1,0x11:0,0x12:1,0x13:1,0x14:1,0x15:0,0x16:16,0x17:12,0x18:16,0x19:12,0x1a:9,0x1b:3,0x1c:3,0x20:1,0x21:1,0x22:1,0x23:2,0x24:1,0x25:1,0x26:1,0x27:1,0x28:1,0x29:1,0x2a:1,0x2b:1,0x30:1,0x31:1,0x32:1,0x33:1,0x34:32,0x40:1,0x41:0,0x50:1,0x60:1,0x70:3,0x71:2,0x72:1}
def commands(data):
 pos=0
 while pos<len(data):
  require(pos+4<=len(data), "Truncated command word")
  ids=data[pos:pos+4];pos+=4
  for c in ids:
   require(c in COUNTS, "Unknown command: "+hex(c))
   n=COUNTS[c];require(pos+n*4<=len(data), "Truncated command parameters")
   p=struct.unpack_from('<%dI'%n,data,pos);pos+=n*4
   yield c,p
 require(pos==len(data), "Invalid stream extent")
def sx(n,b):return (n^(1<<(b-1)))-(1<<(b-1))
def analyze(data):
 prev=[None]*3;counters=collections.Counter()
 for c,p in commands(data):
  counters['commands']+=1
  counters['parameter_words']+=len(p)
  if c==0:counters['nop']+=1
  if c==0x23:
   v=[p[0]&65535,p[0]>>16,p[1]&65535];counters['vtx16']+=1
   if all(x&63==0 for x in v):counters['vtx10_exact']+=1
   elif any(x==y for x,y in zip(v,prev)):counters['partial_exact']+=1
   elif all(y is not None and -512<=sx((x-y)&65535,16)<=511 for x,y in zip(v,prev)):counters['delta_exact']+=1
   prev=v
  elif c==0x24:prev=[((p[0]>>s)&1023)<<6 for s in (0,10,20)]
  elif c in (0x25,0x26,0x27):
   a,b={0x25:(0,1),0x26:(0,2),0x27:(1,2)}[c];prev[a]=p[0]&65535;prev[b]=p[0]>>16
  elif c==0x28:prev=[None if x is None else (x+sx((p[0]>>s)&1023,10))&65535 for x,s in zip(prev,(0,10,20))]
 return dict(counters)

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('input',type=Path)
 parser.add_argument('--offset',type=lambda n:int(n,0),default=0)
 parser.add_argument('--length',type=lambda n:int(n,0),required=True)
 parser.add_argument('--sha256',required=True,help='Required identity of the complete input')
 parser.add_argument('--output',type=Path,required=True)
 args=parser.parse_args();raw=args.input.read_bytes()
 require(hashlib.sha256(raw).hexdigest()==args.sha256,'Input identity differs')
 require(args.offset%4==0 and args.length>0 and args.length%4==0 and 0<=args.offset<args.offset+args.length<=len(raw),'Invalid list extent')
 data=raw[args.offset:args.offset+args.length]
 result=dict(input_sha256=args.sha256,list_sha256=hashlib.sha256(data).hexdigest(),offset=args.offset,length=args.length,counts=analyze(data),limits=['Coordinates only; no command is changed.', 'Pipeline timing, source lifetime, packed-list bounds and all other effects require separate validation.'])
 args.output.write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__':main()
