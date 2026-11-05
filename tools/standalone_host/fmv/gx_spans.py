# SPDX-License-Identifier: GPL-3.0-only
"""Precompute independent GX primitives without changing vertex/attribute values.

The runtime decision to omit a span is separately qualified per manifest.
No game addresses, ROM data or resource identity is embedded here.
"""
import struct
from gx_model import commands, inspect_model, signed, require

def pack(cmds):
 out=bytearray()
 for i in range(0,len(cmds),4):
  group=cmds[i:i+4];out.extend(bytes([op for op,p in group])+bytes(4-len(group)))
  for op,p in group:out.extend(struct.pack('<%dI'%len(p),*p))
 return bytes(out)

def spans(dl):
 color=tex=None;xyz=[None]*3;active=False;pending=[];segments=[];lo=[];hi=[];first=False;prefix=[]
 for off,op,p in commands(dl):
  require(op in {0,0x20,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x40,0x41},'Unsupported state command')
  if not pending:
   prefix=([(0x20,(color,))] if color is not None else [])+([(0x22,(tex,))] if tex is not None else [])
  if op==0:continue
  if op==0x20:color=p[0]
  if op==0x22:tex=p[0]
  if op==0x40:
   require(not active,'Nested BEGIN');active=True;first=True;lo=[32767]*3;hi=[-32768]*3
  if 0x23<=op<=0x28:
   require(active,'Vertex outside primitive');v=p[0]
   if op==0x23:xyz=[signed(v,16),signed(v>>16,16),signed(p[1],16)]
   elif op==0x24:xyz=[signed(v>>k,10)<<6 for k in (0,10,20)]
   elif op==0x28:xyz=[None if a is None else signed(a+signed(v>>k,10),16) for a,k in zip(xyz,(0,10,20))]
   else:
    for a,k in zip({0x25:(0,1),0x26:(0,2),0x27:(1,2)}[op],(0,16)):xyz[a]=signed(v>>k,16)
   require(None not in xyz,'Unknown starting vertex')
   lo=[min(a,b) for a,b in zip(lo,xyz)];hi=[max(a,b) for a,b in zip(hi,xyz)]
   if first:op=0x23;p=((xyz[0]&65535)|((xyz[1]&65535)<<16),xyz[2]&65535);first=False
  pending.append((op,p))
  if op==0x41:
   require(active and not first,'Empty/unmatched END');active=False
   segments.append(dict(cmds=prefix+pending,lo=lo,hi=hi));pending=[]
 require(not active and segments,'Incomplete primitive')
 if pending:segments[-1]['cmds']+=pending
 for s in segments:
  s['data']=pack(s.pop('cmds'));s['error']=sum(max(abs(a),abs(b)) for a,b in zip(s['lo'],s['hi']))+32
 return segments

def semantic(dl):
 color=tex=None;xyz=[None]*3;out=[];mode=None
 for _,op,p in commands(dl):
  if op==0x20:color=p[0]
  elif op==0x22:tex=p[0]
  elif op==0x40:mode=p[0];out.append(('begin',mode))
  elif op==0x41:out.append(('end',));mode=None
  elif 0x23<=op<=0x28:
   v=p[0]
   if op==0x23:xyz=[signed(v,16),signed(v>>16,16),signed(p[1],16)]
   elif op==0x24:xyz=[signed(v>>k,10)<<6 for k in (0,10,20)]
   elif op==0x28:xyz=[None if a is None else signed(a+signed(v>>k,10),16) for a,k in zip(xyz,(0,10,20))]
   else:
    for a,k in zip({0x25:(0,1),0x26:(0,2),0x27:(1,2)}[op],(0,16)):xyz[a]=signed(v>>k,16)
   out.append(('v',tuple(xyz),color,tex))
 return out,(xyz,color,tex)

def transform(data,model_offset):
 info=inspect_model(data,model_offset,True);size=info['model_bytes'];model=bytearray(data[model_offset:model_offset+size]);env=struct.unpack_from('<I',model,16)[0];extra=bytearray();stats=[];allsegments=[]
 for shape in info['shapes']:
  start=shape['display_list_offset'];dl=bytes(model[start:start+shape['display_list_bytes']]);ss=spans(dl)
  require(semantic(dl)==semantic(b''.join(s['data'] for s in ss)), 'Span transform changes geometry state')
  # Check independent selection with every second span omitted, preserving final state.
  original_events=semantic(dl)[0];primitive_events=[];part=[]
  for event in original_events:
   part.append(event)
   if event[0]=='end':primitive_events.append(part);part=[]
  for selection in ([len(ss)-1],list(range(0,len(ss)-1,2))+[len(ss)-1],list(range(1,len(ss)-1,2))+[len(ss)-1]):
   got,state=semantic(b''.join(ss[i]['data'] for i in selection));want=sum([primitive_events[i] for i in selection],[])
   require(got==want and state==semantic(dl)[1], 'Independent span state differs')
  allsegments.append(ss)
  if len(ss)<2:continue
  payload=bytearray();meta=bytearray(struct.pack('<II',0x434c5344,len(ss)));offset=8+24*len(ss)
  for s in ss:
   meta.extend(struct.pack('<II6hI',offset+len(payload),len(s['data']),*(s['lo']+s['hi']),s['error']));payload.extend(s['data'])
  new=bytes(meta+payload);desc=shape['descriptor_offset'];struct.pack_into('<II',model,desc+8,env+len(extra)-desc,len(new));extra.extend(new)
  stats.append(dict(shape=shape['index'],spans=len(ss),old_bytes=len(dl),new_bytes=len(new)))
 model[env:env]=extra;struct.pack_into('<I',model,0,len(model));struct.pack_into('<I',model,16,env+len(extra))
 # Restricted single-model MDL0 at the final NSBMD block; no unexplained offsets.
 require(data[:4]==b'BMD0' and data[20:24]==b'MDL0','Expected single MDL0')
 require(struct.unpack_from('<H',data,14)[0]==1 and model_offset+size==len(data),'Unsupported other blocks/models')
 output=bytearray(data[:model_offset])+model;struct.pack_into('<I',output,8,len(output));struct.pack_into('<I',output,24,len(output)-20)
 return bytes(output),stats,allsegments

