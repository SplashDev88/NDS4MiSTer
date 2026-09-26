#!/usr/bin/env python3
"""Select the EBO1 experiment or its v0.5.0 rollback; never load a ROM."""
from pathlib import Path
import errno
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path('/media/fat/Scripts/.NDS_EngineB_EBO1_20260925')
SERVICE = Path('/media/fat/Scripts/NDS_Support/nds_hybrid_3d_service')
LAUNCHER = Path('/media/fat/Scripts/NDS_Kickstart.sh')
CORENAME = Path('/tmp/CORENAME')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(value):
    # A core switch recreates the FIFO. Retry only opening it: a submitted
    # command must never be sent twice.
    for _ in range(150):
        try:
            fd = os.open('/dev/MiSTer_cmd', os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as error:
            if error.errno not in (errno.ENXIO, errno.ENOENT):
                raise
            time.sleep(.2)
    else:
        raise RuntimeError('MiSTer command input did not become ready.')
    try:
        os.write(fd, (value + '\n').encode())
    finally:
        os.close(fd)


def install_pair_helper(data, digest):
    # Keep the existing supervisor's executable path and single-process checks.
    temp = SERVICE.with_suffix('.ebo1-tmp')
    temp.write_bytes(data)
    temp.chmod(0o755)
    os.replace(temp, SERVICE)
    manifest = SERVICE.with_suffix('.sha256')
    temp = manifest.with_suffix('.ebo1-tmp')
    temp.write_text(digest + '  nds_hybrid_3d_service\n')
    os.replace(temp, manifest)
    os.sync()


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('ebo1', 'v050'):
        raise RuntimeError('Select this test using its Scripts entry.')
    choices = json.loads((ROOT / 'pairs.json').read_text())
    pair = choices['pairs'][sys.argv[1]]
    helper = ROOT / pair['helper']
    core = ROOT / pair['core']
    if sha(LAUNCHER) not in choices['allowed_launchers']:
        raise RuntimeError('Kickstart changed; prepare an updated test kit. Nothing was changed.')
    if sha(helper) != pair['helper_sha256'] or sha(core) != pair['core_sha256']:
        raise RuntimeError('Test core/helper checksum failed. Nothing was changed.')
    previous_data = SERVICE.read_bytes()
    previous_sha = hashlib.sha256(previous_data).hexdigest()
    if previous_sha not in choices['allowed_helpers']:
        raise RuntimeError('Unrecognized installed helper. Nothing was changed.')

    print('Loading ' + pair['name'] + '. No ROM will be loaded.', flush=True)
    if sys.argv[1] == 'v050':
        print('Rollback requires Engine B On. Set On, then Reset or load your ROM.', flush=True)
    else:
        print('Set Engine B (next Reset) Off or On, then Reset or load your ROM.', flush=True)
    if CORENAME.read_text().strip() != 'MENU':
        command('load_core /media/fat/menu.rbf')
    for _ in range(100):
        if CORENAME.read_text().strip() == 'MENU':
            break
        time.sleep(.2)
    else:
        raise RuntimeError('MiSTer did not return to MENU; helper unchanged.')
    subprocess.run(['sh', str(LAUNCHER), 'stop'], check=True)
    env = os.environ.copy()
    env.update(NDS4MISTER_PACKET_NC='0', NDS_GPU_STANDARD_PALETTE_CACHE='1',
               NDS4MISTER_GX_MATRIX_PREFIX='fast', NDS4MISTER_GX_QUERY_FAST_POLL='0')
    try:
        install_pair_helper(helper.read_bytes(), pair['helper_sha256'])
        subprocess.run(['sh', str(LAUNCHER), 'start'], env=env, check=True)
    except Exception:
        # Remain at MENU with the previous helper restored if startup fails.
        subprocess.run(['sh', str(LAUNCHER), 'stop'], check=True)
        install_pair_helper(previous_data, previous_sha)
        raise
    command('load_core ' + str(core))
    (ROOT / 'selected.json').write_text(json.dumps(
        dict(selection=sys.argv[1], pair=pair), indent=2) + '\n')
    print('Ready. Choose Load NDS in the core menu.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('NDS test selection stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
