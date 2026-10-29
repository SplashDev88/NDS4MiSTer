# SPDX-License-Identifier: GPL-3.0-or-later
"""Configured ownership wrapper around the existing native rig launch/stop flow."""
from pathlib import Path
from datetime import datetime, timezone
import json
import os
import subprocess
import sys

config_path = Path(sys.argv[1]).resolve()
action, label = sys.argv[2:4]
assert len(sys.argv) == 4 and action in ['launch', 'stop']
assert label.replace('_', '').isalnum()
C = json.loads(config_path.read_text())
E = Path(C['evidence_directory'])
STATE = Path(C['state_path'])
SSH = C['ssh']
env = dict(os.environ, NDS_RIG_CONFIG=str(config_path))


def write(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def update(job, **details):
    state = json.loads(STATE.read_text())
    assert state['current_evidence'] == str(E)
    state['current_jobs']['native'] = job
    state['active_jobs'] = [v for v in state['current_jobs'].values() if v]
    state['coordination'].update(hardware_owner=state['thread_id'] if job else None,
                                 hardware_available=not bool(job))
    state['updated_utc'] = datetime.now(timezone.utc).isoformat()
    state.update(details)
    write(STATE, state)


def remote(code, timeout=120):
    result = subprocess.run(SSH + ['python3 -'], input=code, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return json.loads(result.stdout)


def rig(operation, suffix):
    subprocess.run([sys.executable, str(Path(__file__).with_name('native_rig.py')),
                    operation, label + suffix], env=env, check=True)
    return json.loads((E / (label + suffix + '.json')).read_text())


state = json.loads(STATE.read_text())
assert state['current_evidence'] == str(E)
if action == 'launch':
    assert not any(state['current_jobs'].values())
    assert state['coordination'].get('hardware_owner') is None
    preflight = E / (label + '_PREFLIGHT.json')
    assert not preflight.exists()
    checked = remote('C=' + repr(C) + '\n' + r'''
from pathlib import Path
import hashlib,json,zlib
assert Path('/tmp/CORENAME').read_text().strip()=='MENU'
assert not Path('/tmp/nds-standalone-guard-ready').exists()
lease=Path('/tmp/nds-standalone-lease.json')
if lease.exists():assert json.loads(lease.read_text()).get('done')
for p in Path('/proc').glob('[0-9]*'):
 try:exe=(p/'exe').resolve()
 except FileNotFoundError:continue
 assert exe.name not in ['nds_standalone_host','nds_hybrid_3d_service']
rom=Path(C['rom']);assert rom.is_symlink() and rom.resolve()==Path(C['original_rom']).resolve()
h=hashlib.sha256()
with rom.open('rb') as stream:
 header=stream.read(352);h.update(header)
 for block in iter(lambda:stream.read(262144),b''):h.update(block)
assert h.hexdigest()==C['rom_sha256']
identity={'code':header[12:16].decode('ascii'),'revision':header[30],'header_crc32':format(zlib.crc32(header),'08x')}
assert identity==C.get('source_cartridge_identity',C['loaded_cartridge_identity'])
save=Path(C['save']).read_bytes();assert len(save)==C['save_bytes']
assert hashlib.sha256(save).hexdigest()==C['seed_sha256'], 'Reset only the disposable save from its admitted seed before launching'
print(json.dumps({'rom_sha256':h.hexdigest(),'identity':identity,'save_sha256':hashlib.sha256(save).hexdigest(),'save_bytes':len(save),'boot_id':Path('/proc/sys/kernel/random/boot_id').read_text().strip()}))
''')
    write(preflight, checked)
    job = dict(kind='configured_native_trial', profile=C['profile'],
               config=str(config_path), status='launching', controller_pid=os.getpid(),
               label=label, evidence=str(E))
    update(job)
    launch_action = C.get('launch_action', 'launch')
    assert launch_action in ['launch', 'launch_beta']
    launched = rig(launch_action, '_LAUNCH')
    live = remote('PID=' + repr(launched['pid']) + '\nC=' + repr(C) + '\n' + r'''
from pathlib import Path
import json,os,time
for _ in range(900):
 d=json.loads(Path('/tmp/nds-standalone-lease.json').read_text())
 if d.get('supervisor',{}).get('pid')==PID and d.get('phase')=='running' and not d.get('done') and d.get('host') and d.get('helper'):
  p=Path('/proc',str(d['host']['pid']))
  assert p.joinpath('stat').read_text().split(') ')[1].split()[19]==str(d['host']['epoch'])
  assert p.joinpath('exe').resolve()==Path(C['kit'])/'nds_standalone_host'
  hp=Path('/proc',str(d['helper']['pid']))
  assert hp.joinpath('stat').read_text().split(') ')[1].split()[19]==str(d['helper']['epoch'])
  assert hp.joinpath('exe').resolve()==Path(C['kit'])/'support/nds_hybrid_3d_service'
  saves=[]
  for f in (p/'fd').iterdir():
   try:q=os.readlink(f)
   except FileNotFoundError:continue
   if q.endswith(('.sav','.dsv')):saves.append(q)
  if saves==[C['save']]:break
 assert Path('/proc',str(PID)).exists()
 time.sleep(.1)
else:raise RuntimeError('Fresh running lease timeout')
print(json.dumps(d))
''', 100)
    write(E / (label + '_LEASE.json'), live)
    job.update(status='running', host=live['host'], helper=live['helper'])
    update(job, native_session=dict(owner=state['thread_id'], phase='running',
            kit=C['kit'], save=C['save'], host=live['host'], helper=live['helper'],
            receipt=str(E / (label + '_LEASE.json'))))
    status = rig('status', '_FLAGS')
    assert status['save_size'] == C['save_bytes']
    assert {k: status['loaded_cartridge_identity'][k] for k in C['loaded_cartridge_identity']} == C['loaded_cartridge_identity']
    print('Configured native session identity and isolated save verified.')
else:
    native = state['current_jobs']['native']
    assert native and native['config'] == str(config_path)
    assert state['coordination']['hardware_owner'] == state['thread_id']
    result = rig('stop', '_STOP')
    update(None, native_session=dict(owner=None, core='MENU', active_nds_processes=0,
            last_owned_host_returncode=result['lease']['host_returncode'],
            receipt=str(E / (label + '_STOP.json'))))
    print('Owned native session stopped; MENU restored.')
