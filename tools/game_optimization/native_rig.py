# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import json,subprocess,sys,base64,zlib,struct,os
# Promoted from the existing private native rig; game data lives in config.
setup_file=Path(os.environ['NDS_RIG_CONFIG']).resolve()
setup=json.loads(setup_file.read_text())
E=Path(setup['evidence_directory']).resolve()
assert E.is_dir()
SSH=setup['ssh']
assert isinstance(SSH,list) and SSH[0]=='ssh' and all(isinstance(x,str) for x in SSH)
action=sys.argv[1];label=sys.argv[2]
capture_after=action in ['inputshot','touchshot']
if capture_after:action=action[:-4]
assert action!='setup', 'Use the explicit isolated setup script'
assert label.replace('_','').isalnum() and not (E/(label+'.json')).exists()
config={'label':label,'action':action,'capture_after':capture_after,'setup':setup}
if action in ['peek','start','confirm','menu','input','benchmark','profile','query','measure']:
 import hashlib
 library=Path(setup['input_library'])
 assert hashlib.sha256(library.read_bytes()).hexdigest()==setup['input_library_sha256']
 config['input_library']=library.read_text()
if action in ['input','benchmark','profile','query','measure']:config['steps']=json.loads(sys.argv[3])
if action in ['touch','drag']:config['points']=json.loads(sys.argv[3])
code='C='+repr(config)+'\n'+r'''
from pathlib import Path
import json,hashlib,os,shutil,signal,subprocess,time,mmap,struct,base64,zlib
KIT=Path(C['setup']['kit'])
ROM=Path(C['setup']['rom'])
SAVE=Path(C['setup']['save'])
LEASE=Path('/tmp/nds-standalone-lease.json')
def sha(p):
 p=Path(p)
 if not p.is_file():return None
 digest=hashlib.sha256()
 with p.open('rb') as stream:
  for block in iter(lambda:stream.read(262144),b''):digest.update(block)
 return digest.hexdigest()
def protected(check_roms=True):
 # Bounded input and read-only probes cannot change another game/save.
 # Their PID, epoch, exact kit and sole save FD are checked by owner().
 # Audit the entire protected collection at entry/exit, not during gameplay.
 if not check_roms and C['action'] in ['input','touch','drag','snapshot','status','measure','benchmark','perf','profile','query','peek','start','confirm','menu']:
  return
 # Full preservation hashes are collected at session entry and final audit.
 # Per-trial launches/exits and input steps use metadata guards, avoiding
 # repeated CIFS reads of the same protected ROMs during board validation.
 # metadata guards detect changes without reading 370 MiB while rendering.
 # The owned process/save FD and executable hashes are still checked below.
 if not check_roms and C['setup'].get('protected_metadata'):
  for name,expected in C['setup']['protected_metadata'].items():
   p=Path(name)
   if not p.is_file():actual=None
   else:
    st=p.stat();actual=[st.st_size,st.st_mtime_ns,st.st_ino]
   if actual!=expected:
    # VFAT inode numbers can change after dentry eviction. Accept only an
    # inode-only change after independently rechecking the full frozen hash.
    assert actual is not None and actual[:2]==expected[:2],('protected metadata changed',name)
    assert sha(p)==C['setup']['protected'][name],('protected content changed',name)
    r.setdefault('verified_inode_changes',[]).append({'file':name,'old':expected,'new':actual})
  return
 for p,h in C['setup']['protected'].items():
  # Original ROMs are read-only inputs. Check their full hashes at session
  # entry and clean exit; avoid rereading hundreds of CIFS MiB per keypress.
  # Runtime identity, saves/settings, PID epochs and ownership remain checked.
  if str(p).lower().endswith('.nds') and not check_roms:
   assert Path(p).is_file(),('protected ROM missing',p)
   continue
  assert sha(p)==h,('protected changed',p)
def idle():
 assert Path('/tmp/CORENAME').read_text().strip()=='MENU'
 assert not Path('/tmp/nds-standalone-guard-ready').exists()
 if LEASE.exists():assert json.loads(LEASE.read_text()).get('done')
 for p in Path('/proc').glob('[0-9]*'):
  try:
   exe=(p/'exe').resolve()
   assert exe.name not in ['nds_standalone_host','nds_hybrid_3d_service'],str(exe)
  except FileNotFoundError:pass

def owner():
 d=json.loads(LEASE.read_text());assert d['phase']=='running' and not d.get('done')
 ident=d['host'];p=Path('/proc')/str(ident['pid'])
 assert p.joinpath('stat').read_text().split(') ')[1].split()[19]==str(ident['epoch'])
 assert p.joinpath('exe').resolve()==KIT/'nds_standalone_host'
 for name,h in C['setup']['kit_hashes'].items():
  if (C['action'] in ['benchmark','profile','query','measure','status','stop'] and name in ['NDS_Standalone.rbf','nds_standalone_host','support/nds_hybrid_3d_service','supervisor.py']) or not C['setup'].get('kit_metadata'):
   assert sha(KIT/name)==h
  else:
   st=(KIT/name).stat();actual=[st.st_size,st.st_mtime_ns,st.st_ino];expected=C['setup']['kit_metadata'][name]
   if actual!=expected:
    assert actual[:2]==expected[:2] and sha(KIT/name)==h,('kit metadata/content changed',name)
 fds=[]
 for f in (p/'fd').iterdir():
  try:fds.append(os.readlink(f))
  except FileNotFoundError:pass
 saves=[f for f in fds if f.endswith(('.sav','.dsv'))]
 if C['setup'].get('menu_only'):
  assert C['setup'].get('launch_without_rom')
  assert not any(f.lower().endswith(('.nds','.sav','.dsv')) for f in fds),fds
 else:
  assert saves==[str(SAVE)],saves
 helper=d['helper'];hp=Path('/proc')/str(helper['pid'])
 assert hp.joinpath('stat').read_text().split(') ')[1].split()[19]==str(helper['epoch'])
 assert hp.joinpath('exe').resolve()==KIT/'support/nds_hybrid_3d_service'
 if C['action'] in ['benchmark','profile','query','measure','status','stop']:
  assert sha(hp/'exe')==C['setup']['kit_hashes']['support/nds_hybrid_3d_service']
 for key,value in C['setup'].get('host_environment',{}).items():
  if key in ['NDS4MISTER_CASTLEVANIA_TILE_CACHE','NDS4MISTER_LIGHTING_REUSE','NDS4MISTER_TEXTURE_HISTORY','NDS4MISTER_PREFIX_TILE_REUSE','NDS4MISTER_RENDER_CACHE_STATS','NDS4MISTER_TIMING_PROFILE']:
   assert d['renderer_environment'].get(key)==value,('private renderer flag missing',key)
 if C['setup'].get('guest_trial'):
  env=dict(x.split('=',1) for x in (Path('/proc')/str(ident['pid'])/'environ').read_bytes().decode().split('\0') if '=' in x)
  expected={k:v for k,v in C['setup']['host_environment'].items() if k.startswith('NDS_GUEST_PATCH_')}
  assert {k:v for k,v in env.items() if k.startswith('NDS_GUEST_PATCH_')}==expected
 if C['action']!='stop':protected(False)
 return d,ident
r={'action':C['action'],'boot_id':Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
if C['action'] in ['launch','launch_beta']:
 idle();protected(False)
 for name,h in C['setup']['kit_hashes'].items():assert sha(KIT/name)==h
 log=Path('/tmp/nds-dv1menu-'+C['label']+'.log');assert not log.exists()
 with log.open('xb') as f:
  launch_env=os.environ.copy()
  if C['setup'].get('guest_trial'):
   for key in ['NDS_GUEST_PATCH_MANIFEST','NDS_GUEST_PATCH_SHA256','NDS_GUEST_PATCH_IDS','NDS_GUEST_PATCH_FALLBACK_FMV']:launch_env.pop(key,None)
  guest_file=C['setup'].get('guest_manifest_file','fmv/guest_trial_manifest.json')
  assert isinstance(guest_file,str) and Path(guest_file).parts==('fmv',Path(guest_file).name) and guest_file.endswith('.json')
  if C['setup'].get('guest_trial'):assert guest_file in C['setup']['kit_hashes']
  for key,value in C['setup'].get('host_environment',{}).items():
   guest_allowed=C['setup'].get('guest_trial') and ((key=='NDS_GUEST_PATCH_MANIFEST' and value==str(KIT/guest_file)) or (key=='NDS_GUEST_PATCH_SHA256' and value==C['setup']['kit_hashes'][guest_file]) or (key=='NDS_GUEST_PATCH_IDS' and value in C['setup'].get('allowed_guest_patch_ids',[])) or (key=='NDS_GUEST_PATCH_FALLBACK_FMV' and value=='1'))
   assert guest_allowed or (key in ['NDS4MISTER_LIGHTING_REUSE','NDS4MISTER_CASTLEVANIA_TILE_CACHE','NDS4MISTER_TEXTURE_HISTORY','NDS4MISTER_PREFIX_TILE_REUSE','NDS4MISTER_RENDER_CACHE_STATS','NDS4MISTER_TIMING_PROFILE'] and value in ['0','1']) or (key=='NDS_FMV_COLOR_FAST' and value in ['0','1']) or (key=='NDS_NSMB_PATCH' and value in ['off','lookup','skip','both'])
   launch_env[key]=value
  command=['python3',str(KIT/'auto_movies.py')]
  if C['action']=='launch_beta':
   launcher=Path(C['setup'].get('launcher','/media/fat/Scripts/NDS_FMV_Beta.sh'))
   manifest=json.loads((KIT/'manifest.json').read_text())
   assert manifest.get('private_test_ready')
   assert sha(launcher)==manifest['launcher_sha256']
   assert sha(KIT/'nds_standalone_host')==C['setup']['host_sha256']
   launch_env.pop('NDS_FMV_COLOR_FAST',None) # The actual launcher must enable it.
   if C['setup'].get('guest_trial'):
    for key in list(launch_env):
     if key.startswith('NDS_GUEST_PATCH_'):launch_env.pop(key) # Prove actual launcher selection.
   command=['sh',str(launcher)]
   if C['setup'].get('movie_test_game'):command+=['--game',C['setup']['movie_test_game']]
  rom_args=[] if C['action']=='launch_beta' and (C['setup'].get('movie_test_game') or C['setup'].get('launch_without_rom')) else ['--rom',str(ROM)]
  p=subprocess.Popen(command+rom_args+['--seconds',str(C['setup'].get('seconds',3600)),'--direct-video-target','retrotink'],stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True,env=launch_env)
 r.update(pid=p.pid,log=str(log))
elif C['action'] in ['peek','start','confirm','menu','input']:
 d,h=owner(); scope={'__name__':'bounded_input_library'};exec(C['input_library'],scope)
 import contextlib,io
 input_output=io.StringIO()
 with contextlib.redirect_stdout(input_output):scope['main']({'host':h,'steps':{'peek':[[6,[68]],[.2,[]]],'start':[[.2,[28]],[2,[]]],'confirm':[[.2,[45]],[2,[]]],'menu':[[.2,[88]],[2,[]]],'input':C.get('steps')}[C['action']]})
 r['input_trace']=[json.loads(line) for line in input_output.getvalue().splitlines() if line.strip()]
 assert [item['phase'] for item in r['input_trace']]==['ready','complete']
 r['input_trace_scope']='Native monotonic timestamps of synthetic key emission, not guest input recognition or a visual-event boundary.'
 owner();r['host']=h;r['steps']=C.get('steps')
elif C['action'] in ['touch','drag']:
 import fcntl
 d,h=owner();p=Path('/proc')/str(h['pid'])
 cfg=KIT/'NDS_touch.cfg';assert not cfg.exists() or cfg.read_text().strip()=='NDS-TouchRotation-v1\nNormal'
 points=C['points'];assert 0<len(points)<=12 and all(len(q)==2 and 0<=q[0]<256 and 0<=q[1]<192 for q in points)
 fd=os.open('/dev/uinput',os.O_WRONLY|os.O_NONBLOCK);created=False
 def event(t,c,v):os.write(fd,struct.pack('llHHi',0,0,t,c,v))
 def packet(dx=0,dy=0,button=None):
  assert p.joinpath('stat').read_text().split(') ')[1].split()[19]==str(h['epoch'])
  if dx:event(2,0,dx)
  if dy:event(2,1,dy)
  if button is not None:event(1,272,button)
  event(0,0,0);time.sleep(.07)
 try:
  for ev in (1,2):fcntl.ioctl(fd,0x40045564,ev)
  fcntl.ioctl(fd,0x40045565,272)
  for axis in (0,1):fcntl.ioctl(fd,0x40045566,axis)
  os.write(fd,struct.pack('80sHHHHI',b'NDS bounded mouse',3,0x1209,0x4e46,1,0)+bytes(64*4*4));fcntl.ioctl(fd,0x5501);created=True;time.sleep(1.7)
  for x,y in points:
   for _ in range(3):packet(-127,-127,0)
   dx=x;dy=min(255,(y*4+2)//3)
   while dx or dy:
    sx=min(127,dx);sy=min(127,dy);packet(sx,sy);dx-=sx;dy-=sy
   packet(button=1);time.sleep(.6)
   if C['action']=='drag':
    # Start at the requested pixel, then drag upward; games that require a
    # held stylus movement cannot be exercised by a stationary tap.
    for _ in range(4):packet(0,-20,None)
    time.sleep(1.2)
   packet(button=0);time.sleep(.65)
 finally:
  if created:packet(button=0);fcntl.ioctl(fd,0x5502)
  os.close(fd)
 owner();r['points']=points
elif C['action'] in ['benchmark','profile','query','measure']:
 if C['action']!='measure':assert C['setup'].get('admit_legacy_benchmark_boundaries') is True, 'Scene must qualify benchmark start/end semantics'
 d,h=owner();fd=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC)
 steps=C['steps']
 if C['action']=='measure':
  assert 5<=sum(x[0] for x in steps)<=60 and len(steps)>=2 and steps[-1]==[.1,[]]
  start_index,end_index=0,len(steps)-1
 else:
  assert 5<=sum(x[0] for x in steps)<=30 and len(steps)>4
  assert steps[0][0] in [.2,.5] and steps[0][1] in [[45],[28]] and steps[1] in [[.8,[]],[3,[]]] and steps[-2][0] in [.2,.5] and steps[-2][1]==[28] and steps[-1]==[1,[]]
  start_index,end_index=2,len(steps)-2
 lib=C['input_library'];needle="for duration, keys in steps:\n            assert alive"
 assert lib.count(needle)==1
 lib=lib.replace(needle,"for input_index, (duration, keys) in enumerate(steps):\n            mark_input(input_index)\n            assert alive")
 scope={'__name__':'bounded_input_library'};exec(lib,scope)
 import contextlib,io
 clock=Path('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq')
 def read_sample(head):
  w=list(struct.unpack('<32I',head[:128]));assert w[0]==0x31443348 and w[8:10]==[0,0]
  freq=clock.read_text().strip();assert freq=='1000000',freq
  process={}
  for role in ['host','helper']:
   info=d[role];path=Path('/proc')/str(info['pid']);stat=path.joinpath('stat').read_text().split(') ')[1].split()
   assert stat[19]==str(info['epoch'])
   process[role]={'cpu_ticks':int(stat[11])+int(stat[12]),'rss_pages':int(stat[21])}
  return dict(time=time.monotonic(),unix=time.time(),header=w,clock_khz=int(freq),process=process,clock_ticks_per_sec=os.sysconf('SC_CLK_TCK'))
 samples={};collector=None
 profile_path=Path('/tmp/nds-'+('query-' if C['action']=='query' else 'pc-')+C['label']+'.json')
 if C['action']=='query':
  assert not profile_path.exists()
  for name,expected_hash in C['setup']['query_hashes'].items():assert sha(KIT/name)==expected_hash
 if C['action']=='profile':
  assert not profile_path.exists()
  assert sha(KIT/'arm9_pc_profile.py')==C['setup']['profile_tool_sha256']
  if C['setup'].get('profile_native_sha256'):
   assert sha(KIT/'arm9_pc_sample')==C['setup']['profile_native_sha256']
 try:
  with mmap.mmap(fd,4096,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x3fc00000) as head:
   def mark(index):
    global collector
    if index==start_index:
     samples['before']=read_sample(head)
     if C['action']=='query':
      duration=sum(s[0] for s in steps[2:-2])
      collector=subprocess.Popen(['python3','-E','-s','-B',str(KIT/'query_wait_profile.py'),'--seconds',str(duration),'--output',str(profile_path),'--native',str(KIT/'query_wait_sample')],stdin=subprocess.DEVNULL)
     if C['action']=='profile':
      duration=sum(s[0] for s in steps[2:-2])
      native=(['--native',str(KIT/'arm9_pc_sample')] if C['setup'].get('profile_native_sha256') else [])
      collector=subprocess.Popen(['python3','-E','-s','-B',str(KIT/'arm9_pc_profile.py'),'--seconds',str(duration),'--output',str(profile_path)]+native,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
    if index==end_index:samples['after']=read_sample(head)
   scope['mark_input']=mark
   input_output=io.StringIO()
   with contextlib.redirect_stdout(input_output):scope['main']({'host':h,'steps':steps})
   r['input_trace']=[json.loads(line) for line in input_output.getvalue().splitlines() if line.strip()]
   assert [item['phase'] for item in r['input_trace']]==['ready','complete']
   r['input_trace_scope']='Native monotonic timestamps of synthetic key emission, not guest recognition. Convert using the surrounding samples; video alignment also requires clock and capture uncertainty.'
 finally:os.close(fd)
 if collector:
  assert collector.wait(timeout=45)==0
  r['query_profile' if C['action']=='query' else 'pc_profile']=json.loads(profile_path.read_text())
 owner();before=samples['before'];after=samples['after'];assert before['header'][2]==after['header'][2]
 seconds=after['time']-before['time']
 r.update(before=before,after=after,seconds=seconds,steps=steps,remote_finished_unix=time.time(),
   completed_updates_per_sec=((after['header'][12]&~1)-(before['header'][12]&~1))/2/seconds,
   frame_id_delta=(after['header'][19]-before['header'][19])&0xffffffff,
   qualifier='Completed screen-buffer publications and published frame identifiers during the recorded interval. Not unique animation, game-clock cadence or whole-game FPS')
elif C['action']=='snapshot':
 d,h=owner()
 fd=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC);pf=os.open('/dev/nds_mem_wc',os.O_RDONLY|os.O_SYNC)
 try:
  with mmap.mmap(fd,4096,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x3fc00000) as head, mmap.mmap(pf,0x200000,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x3fe00000) as fb:
   for _ in range(100):
    w=struct.unpack('<32I',head[:128])
    assert w[0]==0x31443348 and w[8]==w[9]==0 and w[20]<4
    if w[12]&1 or w[16]!=w[12] or w[17]!=0:time.sleep(.01);continue
    raw=b''.join(fb[w[20]*0x80000+i*0x40000:w[20]*0x80000+i*0x40000+192*1024] for i in (0,1))
    end=struct.unpack('<32I',head[:128])
    if w[12]==end[12] and w[2]==end[2]:break
   else:raise RuntimeError('no coherent frame')
   r['header']=list(w);r['pixels']=base64.b64encode(zlib.compress(raw)).decode()
 finally:os.close(fd);os.close(pf)
 owner()
elif C['action']=='progress':
 r['lease']=json.loads(LEASE.read_text()) if LEASE.exists() else {}
 r['core']=Path('/tmp/CORENAME').read_text().strip()
 r['host_log']=Path('/tmp/nds-standalone/host.log').read_text()[-5000:] if Path('/tmp/nds-standalone/host.log').exists() else ''
 r['renderer_log']=Path('/tmp/nds-hybrid-3d-service.log').read_text()[-1500:] if Path('/tmp/nds-hybrid-3d-service.log').exists() else ''
 r['save_size']=SAVE.stat().st_size if SAVE.is_file() else None
elif C['action']=='status':
 d,h=owner();r['lease']=d;r['save_size']=SAVE.stat().st_size;r['save_sha256']=sha(SAVE)
 fd=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC)
 try:
  with mmap.mmap(fd,4096,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x30000000) as cart:
   first=cart[:0x160];second=cart[:0x160];assert first==second
   r['loaded_cartridge_identity']={'code':first[12:16].decode('ascii'),'revision':first[30],'header_crc32':format(zlib.crc32(first),'08x'),'stable_two_reads':True}
  staged=[]
  for guard in C['setup'].get('staged_patch_guards',[]):
   offset=guard['cartridge_offset'];expected=bytes.fromhex(guard['expect'])
   extent=C['setup'].get('staged_cartridge_bytes',128*1024*1024)
   assert type(extent) is int and 512<=extent<=252*1024*1024
   assert 0<=offset and 0<len(expected)<=4096 and offset+len(expected)<=extent
   address=0x30000000+offset;page=address&~4095;lo=address-page
   with mmap.mmap(fd,(lo+len(expected)+4095)&~4095,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=page) as cart:
    value=bytes(cart[lo:lo+len(expected)])
    assert value==expected,('staged cartridge bytes differ',guard['id'])
    staged.append(dict(id=guard['id'],cartridge_offset=offset,sha256=hashlib.sha256(value).hexdigest()))
  r['staged_patch_guards']=staged
 finally:os.close(fd)
 r['host_log']=Path('/tmp/nds-standalone/host.log').read_text();r['renderer_log']=Path('/tmp/nds-hybrid-3d-service.log').read_text()[-20000:]
elif C['action']=='stop':
 d=json.loads(LEASE.read_text())
 if not d.get('done'):
  d,h=owner();os.kill(h['pid'],signal.SIGTERM)
 for _ in range(250):
  d=json.loads(LEASE.read_text())
  if d.get('done') and not Path('/tmp/nds-standalone-guard-ready').exists() and Path('/tmp/CORENAME').read_text().strip()=='MENU':break
  time.sleep(.1)
 else:raise RuntimeError('clean exit timeout')
 assert d.get('host_returncode')==0,d
 idle();protected(False);r['lease']=d;r['host_log']=Path('/tmp/nds-standalone/host.log').read_text();r['save_size']=SAVE.stat().st_size;r['save_sha256']=sha(SAVE)
else:raise ValueError(C['action'])
if C.get('capture_after'):
 d,h=owner()
 fd=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC);pf=os.open('/dev/nds_mem_wc',os.O_RDONLY|os.O_SYNC)
 try:
  with mmap.mmap(fd,4096,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x3fc00000) as head, mmap.mmap(pf,0x200000,flags=mmap.MAP_SHARED,prot=mmap.PROT_READ,offset=0x3fe00000) as fb:
   for _ in range(100):
    w=struct.unpack('<32I',head[:128])
    assert w[0]==0x31443348 and w[8]==w[9]==0 and w[20]<4
    if w[12]&1 or w[16]!=w[12] or w[17]!=0:time.sleep(.01);continue
    raw=b''.join(fb[w[20]*0x80000+i*0x40000:w[20]*0x80000+i*0x40000+192*1024] for i in (0,1))
    end=struct.unpack('<32I',head[:128])
    if w[12]==end[12] and w[2]==end[2]:break
   else:raise RuntimeError('no coherent frame')
   r['header']=list(w);r['pixels']=base64.b64encode(zlib.compress(raw)).decode()
 finally:os.close(fd);os.close(pf)
 owner()
print(json.dumps(r))
'''
p=subprocess.run(SSH+['python3 -'],input=code,text=True,capture_output=True,timeout=240)
if p.returncode:print(p.stdout,p.stderr);raise SystemExit(p.returncode)
data=json.loads(p.stdout);(E/(label+'.json')).write_text(json.dumps(data,indent=2)+'\n')
if action=='snapshot' or capture_after:
 from PIL import Image
 raw=zlib.decompress(base64.b64decode(data['pixels']));out=bytearray()
 for (v,) in struct.iter_unpack('<I',raw):out.extend(((v&63)*255//63,((v>>6)&63)*255//63,((v>>12)&63)*255//63))
 Image.frombytes('RGB',(256,384),bytes(out)).save(E/(label+'.png'))
print(json.dumps({k:v for k,v in data.items() if k not in ['protected','lease','host_log','renderer_log','pixels','steps','before','after','verified_inode_changes','input_trace']},indent=2))
