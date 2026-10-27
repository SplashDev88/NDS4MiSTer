#!/usr/bin/env python3
"""Verify the disposable native loader against previously pinned image hashes.

No ROM file is created. This checks stream identity/admission, not guest
execution, native performance, or on-board cache/reset behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(262144), b''): h.update(block)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('rom', type=Path)
    p.add_argument('manifest', type=Path)
    p.add_argument('fixture', type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    assert not a.output.exists()
    fixture = json.loads(a.fixture.read_text())
    assert sha(a.rom) == fixture['rom_sha256']
    assert sha(a.manifest) == fixture['manifest_sha256']
    directory = Path(__file__).resolve().parents[1]/'standalone_host/fmv'
    before = a.rom.stat()
    rows = []
    for case in fixture['cases']:
        env = {k:v for k,v in os.environ.items() if not k.startswith('NDS_')}
        env.update(NDS_ROM_LOAD_PROGRESS='1', NDS_ROM_STREAM_PATCHES='1')
        if case['patch_ids']:
            env.update(NDS_GUEST_PATCH_MANIFEST=str(a.manifest.resolve()),
                       NDS_GUEST_PATCH_SHA256=fixture['manifest_sha256'],
                       NDS_GUEST_PATCH_IDS=','.join(case['patch_ids']))
        with a.rom.open('rb') as source:
            result = subprocess.run([sys.executable, '-E', '-s', '-B', str(directory/'stream.py'),
                str(source.fileno()), '1', str(os.getpid())], pass_fds=(source.fileno(),),
                env=env, capture_output=True, timeout=180)
        assert result.returncode == 0, result.stderr.decode()
        wire = memoryview(result.stdout)
        at = 0; last_progress = -1; work_updates = 0
        while True:
            size, error, operation = struct.unpack_from('<Qii', wire, at); at += 16
            assert error == 0
            if operation == 0: break
            assert operation in (7,13), operation
            if operation == 13:
                assert last_progress <= size <= 9900
                last_progress = size; work_updates += 1
        assert size == before.st_size and size <= 252*1024*1024
        digest = hashlib.sha256(wire[at:at+size]).hexdigest(); at += size
        assert digest == case['virtual_image_sha256'], (case['name'], digest)
        assert struct.unpack_from('<Qii', wire, at) == (size,0,8)
        assert len(wire) == at+16
        records = [json.loads(line.split(' ',1)[1]) for line in result.stderr.decode().splitlines()
                   if line.startswith('GUEST_PATCH_RESULT ')]
        if case['patch_ids']:
            assert len(records) == 1 and records[0]['state'] == 'applied_to_virtual_image'
            assert records[0]['requested'] == sorted(case['patch_ids'])
            assert sorted(x['id'] for x in records[0]['applied']) == sorted(case['patch_ids'])
            assert records[0]['manifest_sha256'] == fixture['manifest_sha256']
        else:
            assert not records
        rows.append(dict(name=case['name'], bytes=size, image_sha256=digest,
                         completed=True, work_updates=work_updates, admission=records))
        del wire, result
    after = a.rom.stat()
    assert (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) == (
        after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)
    assert sha(a.rom) == fixture['rom_sha256']
    receipt = dict(state='passed_native_worker_stream_identity', cases=rows,
        manifest_sha256=fixture['manifest_sha256'], fixture_sha256=sha(a.fixture),
        original_rom_unchanged=True, worker_sources={name:sha(directory/name) for name in
            ['stream.py','guest_byte_patch.py','prepare.py','hook_guard.py','load_progress.py']},
        limitations='Host-side stream validation only; native MiSTer execution/performance remains unmeasured.')
    a.output.write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(dict(state=receipt['state'], cases=len(rows), original_rom_unchanged=True)))


if __name__ == '__main__': main()
