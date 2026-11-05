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

def group_spans(items, count):
 """Group consecutive primitives, preserving their original order and state."""
 result=[]
 for i in range(0,len(items),count):
  group=items[i:i+count]
  lo=[min(s['lo'][j] for s in group) for j in range(3)]
  hi=[max(s['hi'][j] for s in group) for j in range(3)]
  result.append(dict(data=b''.join(s['data'] for s in group),lo=lo,hi=hi,
                     error=sum(max(abs(a),abs(b)) for a,b in zip(lo,hi))+32))
 return result

def polygons(dl):
 """Ordered vertex/attribute tuples, following GPU3D::SubmitVertex ordering."""
 events,state=semantic(dl);out=[];vertices=[];mode=None
 for event in events:
  if event[0]=='begin':mode=event[1];vertices=[]
  elif event[0]=='v':vertices.append(event[1:])
  elif event[0]=='end':
   require(mode in (0,1,2,3),'Unsupported primitive mode')
   if mode in (0,1):
    size=3+mode;require(len(vertices)%size==0,'Incomplete independent polygon')
    out.extend(tuple(vertices[i:i+size]) for i in range(0,len(vertices),size))
   elif mode==2:
    out.extend(tuple((vertices[i+1],vertices[i],vertices[i+2]) if i%2 else vertices[i:i+3]) for i in range(len(vertices)-2))
   else:
    require(len(vertices)%2==0,'Incomplete quad strip')
    out.extend((vertices[i],vertices[i+1],vertices[i+3],vertices[i+2]) for i in range(0,len(vertices)-2,2))
 return out,state

def encode_vertex(xyz,previous):
 if previous is not None:
  for op,axes,unchanged in [(0x25,(0,1),2),(0x26,(0,2),1),(0x27,(1,2),0)]:
   if xyz[unchanged]==previous[unchanged]:return op,((xyz[axes[0]]&65535)|((xyz[axes[1]]&65535)<<16),)
  delta=[signed(a-b,16) for a,b in zip(xyz,previous)]
  if all(-512<=x<=511 for x in delta):return 0x28,(sum((x&1023)<<(10*j) for j,x in enumerate(delta)),)
 return 0x23,((xyz[0]&65535)|((xyz[1]&65535)<<16),xyz[2]&65535)

def split_independent_polygons(dl,limit):
 """Split only independent triangle/quad lists; strips retain their reuse.

 The ordered polygons, every submitted vertex and final attributes are exact.
 No strip restart, overlapping vertex, lighting, matrix or material change.
 """
 original=spans(dl);raw_parts=[];pending=[];output=[];changed=False
 for _,op,params in commands(dl):
  pending.append((op,params))
  if op==0x41:raw_parts.append(pending);pending=[]
 if pending:raw_parts[-1].extend(pending)
 require(len(original)==len(raw_parts),'Primitive partition differs')
 for span,raw in zip(original,raw_parts):
  events,state=semantic(span['data']);mode=next(e[1] for e in events if e[0]=='begin')
  vertices=[e[1:] for e in events if e[0]=='v'];count=len(polygons(span['data'])[0])
  if mode>=2 or count<=limit or any(None in v[1:] for v in vertices):output.extend(raw);continue
  changed=True;size=3+mode
  for at in range(0,len(vertices),limit*size):
   chunk=vertices[at:at+limit*size];output.append((0x40,(mode,)));color=tex=previous=None
   for xyz,c,t in chunk:
    if c!=color:output.append((0x20,(c,)));color=c
    if t!=tex:output.append((0x22,(t,)));tex=t
    output.append(encode_vertex(xyz,previous));previous=xyz
   output.append((0x41,()))
  output.extend([(0x20,(state[1],)),(0x22,(state[2],))])
 result=pack(output) if changed else dl
 require(polygons(result)==polygons(dl),'Polygon splitting changes geometry/state')
 return result

def replace_model_v2(data,offset,size,model):
 """Keep a trailing TEX0 block byte-for-byte and relocate its block offset."""
 require(data[:4]==b'BMD0' and struct.unpack_from('<I',data,8)[0]==len(data),
         'Invalid NSBMD identity/length')
 header,count=struct.unpack_from('<HH',data,12)
 require(header==16 and count in (1,2),'Unsupported NSBMD blocks')
 starts=list(struct.unpack_from('<%dI'%count,data,16))
 ends=starts[1:]+[len(data)]
 require(starts[0]==16+4*count,'Unexpected NSBMD header extent')
 for i,(start,end) in enumerate(zip(starts,ends)):
  require(start%4==0 and start+8<=end<=len(data) and
          data[start:start+4]==(b'MDL0' if i==0 else b'TEX0') and
          struct.unpack_from('<I',data,start+4)[0]==end-start,
          'Unsupported NSBMD block layout')
 mdl=starts[0]
 require(data[mdl+9]==1 and offset==mdl+struct.unpack_from('<I',data,mdl+28)[0]
         and offset+size==ends[0], 'Expected one final model in MDL0')
 delta=len(model)-size
 output=bytearray(data[:offset])+model+data[offset+size:]
 struct.pack_into('<I',output,8,len(output))
 struct.pack_into('<I',output,mdl+4,ends[0]-mdl+delta)
 for i,start in enumerate(starts[1:],1):struct.pack_into('<I',output,16+4*i,start+delta)
 return bytes(output)

def transform(data,model_offset,options=None,normalize=None):
 info=inspect_model(data,model_offset,True);size=info['model_bytes'];model=bytearray(data[model_offset:model_offset+size]);env=struct.unpack_from('<I',model,16)[0];extra=bytearray();stats=[];allsegments=[]
 v2=options is not None
 if normalize is not None:
  require(v2 and type(normalize) is int and 0<=normalize<=3,'Invalid matrix normalization')
 selected=set(range(len(info['shapes'])));group_size=1;shift=6;max_polygons=None
 if v2:
  require(isinstance(options,dict) and set(options)<= {'shape_indices','group_size','max_polygons'},'Invalid span options')
  indices=options.get('shape_indices',list(selected));group_size=options.get('group_size',1)
  require(isinstance(indices,list) and indices and all(type(i) is int and 0<=i<len(info['shapes']) for i in indices)
          and len(set(indices))==len(indices),'Invalid shape selection')
  require(type(group_size) is int and 1<=group_size<=16,'Invalid primitive grouping')
  max_polygons=options.get('max_polygons')
  require(max_polygons is None or (type(max_polygons) is int and 2<=max_polygons<=64),'Invalid polygon splitting limit')
  selected=set(indices)
  scale,reciprocal=info['position_scale_words'];shift=scale.bit_length()-13
  require(3<=shift<=7 and scale==4096<<shift and reciprocal==4096>>shift,
          'Unsupported model position scale')
 for shape in info['shapes']:
  if shape['index'] not in selected:
   allsegments.append([]);continue
  start=shape['display_list_offset'];dl=bytes(model[start:start+shape['display_list_bytes']]);old_bytes=len(dl)
  if max_polygons is not None:dl=split_independent_polygons(dl,max_polygons)
  ss=spans(dl)
  original_semantics=semantic(dl)
  require(original_semantics==semantic(b''.join(s['data'] for s in ss)), 'Span transform changes geometry state')
  # Check independent selection with every second span omitted, preserving final state.
  original_events=original_semantics[0];primitive_events=[];part=[]
  for event in original_events:
   part.append(event)
   if event[0]=='end':primitive_events.append(part);part=[]
  if group_size>1:
   ss=group_spans(ss,group_size)
   primitive_events=[sum(primitive_events[i:i+group_size],[]) for i in range(0,len(primitive_events),group_size)]
  for selection in ([len(ss)-1],list(range(0,len(ss)-1,2))+[len(ss)-1],list(range(1,len(ss)-1,2))+[len(ss)-1]):
   got,state=semantic(b''.join(ss[i]['data'] for i in selection));want=[event for i in selection for event in primitive_events[i]]
   require(got==want and state==original_semantics[1], 'Independent span state differs')
  allsegments.append(ss)
  if len(ss)<2:continue
  require(len(ss)<=65535,'Too many primitive groups')
  if normalize is not None:
   # Matrix arithmetic shifts lose <1 unit per component. A clip-plane
   # sum/difference loses <2; doubling the existing per-axis margin plus
   # 64 translation units bounds that error conservatively.
   for s in ss:
    if normalize:s['error']*=2
   header=struct.pack('<IHBB',0x334c5344,len(ss),shift,normalize)
  else:header=struct.pack('<IHH',0x324c5344,len(ss),shift) if v2 else struct.pack('<II',0x434c5344,len(ss))
  payload=bytearray();meta=bytearray(header);offset=8+24*len(ss)
  for s in ss:
   meta.extend(struct.pack('<II6hI',offset+len(payload),len(s['data']),*(s['lo']+s['hi']),s['error']));payload.extend(s['data'])
  new=bytes(meta+payload);desc=shape['descriptor_offset'];struct.pack_into('<II',model,desc+8,env+len(extra)-desc,len(new));extra.extend(new)
  stats.append(dict(shape=shape['index'],spans=len(ss),old_bytes=old_bytes,new_bytes=len(new)))
 model[env:env]=extra;struct.pack_into('<I',model,0,len(model));struct.pack_into('<I',model,16,env+len(extra))
 if v2:return replace_model_v2(data,model_offset,size,model),stats,allsegments
 # Restricted single-model MDL0 at the final NSBMD block; no unexplained offsets.
 require(data[:4]==b'BMD0' and data[20:24]==b'MDL0','Expected single MDL0')
 require(struct.unpack_from('<H',data,14)[0]==1 and model_offset+size==len(data),'Unsupported other blocks/models')
 output=bytearray(data[:model_offset])+model;struct.pack_into('<I',output,8,len(output));struct.pack_into('<I',output,24,len(output)-20)
 return bytes(output),stats,allsegments
