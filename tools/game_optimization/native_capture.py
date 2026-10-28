# SPDX-License-Identifier: GPL-3.0-or-later
"""Record an owned native trial using the existing OBS and bounded-input rig."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time

config_path, sequence_path = map(lambda p: Path(p).resolve(), sys.argv[1:3])
label = sys.argv[3]
assert len(sys.argv) == 4 and label.replace('_', '').isalnum()
C, sequence = [json.loads(p.read_text()) for p in [config_path, sequence_path]]
E, STATE = Path(C['evidence_directory']), Path(C['state_path'])
output = E / (label + '_CAPTURE.json')
assert not output.exists()
state = json.loads(STATE.read_text())
native = state['current_jobs']['native']
assert native and native['status'] == 'running' and native['config'] == str(config_path)
assert state['coordination']['hardware_owner'] == state['thread_id']
assert state['current_jobs']['local'] is None and state['current_jobs']['controller'] is None
for name in ['obs_library', 'capture_quality_library']:
    path = Path(C[name])
    assert hashlib.sha256(path.read_bytes()).hexdigest() == C[name + '_sha256']
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if name == 'obs_library': OBS = module.OBS
    else: capture_quality = module.capture_quality

def write(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)

def rig(action, suffix, steps=None):
    args = [sys.executable, str(Path(__file__).with_name('native_rig.py')), action, label + suffix]
    if steps is not None: args.append(json.dumps(steps))
    subprocess.run(args, env=dict(os.environ, NDS_RIG_CONFIG=str(config_path)), check=True, timeout=250)
    return json.loads((E / (label + suffix + '.json')).read_text())

def check(value):
    assert all(value['lease'][key] == native[key] for key in ['host', 'helper'])
    assert value['save_size'] == C['save_bytes']
    assert all(value['loaded_cartridge_identity'][k] == v for k,v in C['loaded_cartridge_identity'].items())

state['current_jobs']['local'] = dict(kind='native_capture', pid=os.getpid(), receipt=str(output))
state['active_jobs'] = [v for v in state['current_jobs'].values() if v]
write(STATE, state)
record = dict(state='preflight', config=str(config_path), sequence=str(sequence_path),
              sequence_sha256=hashlib.sha256(sequence_path.read_bytes()).hexdigest(),
              created_utc=datetime.now(timezone.utc).isoformat(), accepted=False)
obs, owns, started = None, False, None

def stop():
    global owns
    status = obs.call('GetRecordStatus')
    if not status['outputActive'] or abs(status['outputDuration']-(time.monotonic()-started)*1000)>3000:
        owns=False
        raise RuntimeError('Recording ownership changed; external recording left untouched')
    record['record_status_before_stop']=status
    record['recording']=obs.call('StopRecord')
    owns=False
    for _ in range(100):
        if not obs.call('GetRecordStatus')['outputActive']:return
        time.sleep(.1)
    raise RuntimeError('Owned recording did not stop')

try:
    check(rig('status','_BEFORE_STATUS'))
    rig('snapshot','_BEFORE')
    obs=OBS()
    assert not obs.call('GetRecordStatus')['outputActive'] and not obs.call('GetStreamStatus')['outputActive']
    assert obs.call('GetCurrentProgramScene')['currentProgramSceneName']==C['obs_scene']
    record['video_settings']=obs.call('GetVideoSettings')
    record['stats_before']=obs.call('GetStats')
    record['record_start_request_local']=time.time()
    obs.call('StartRecord');started=time.monotonic();owns=True
    record['record_started_local']=time.time()
    record['stats_recording_started']=obs.call('GetStats')
    record['state']='recording';write(output,record)
    for i,section in enumerate(sequence['sections']):
        action=section['action'];assert action in ['input','measure']
        record.setdefault('sections',[]).append(dict(index=i,label=section['label'],local_start=time.time()))
        result=rig(action,'_SECTION_'+str(i),section['steps'])
        record['sections'][-1].update(local_end=time.time(),receipt=str(E/(label+'_SECTION_'+str(i)+'.json')))
        write(output,record)
    record['stats_after']=obs.call('GetStats')
    record['capture_quality']=capture_quality(record)
    stop()
    rig('snapshot','_AFTER')
    check(rig('status','_AFTER_STATUS'))
    record['state']='captured_pending_review'
except BaseException as error:
    record.update(state='failed',error=repr(error));raise
finally:
    try:
        if owns:stop()
    finally:
        if obs:obs.close()
        record['finished_utc']=datetime.now(timezone.utc).isoformat();write(output,record)
        state=json.loads(STATE.read_text());assert state['current_jobs']['local']['pid']==os.getpid()
        state['current_jobs']['local']=None;state['active_jobs']=[v for v in state['current_jobs'].values() if v];write(STATE,state)
print(json.dumps({k:record.get(k) for k in ['state','recording','capture_quality']},indent=2))
