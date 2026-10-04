#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Own a bounded 1 GHz session on legacy and boost-gated MiSTer kernels."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

CPU = Path('/sys/devices/system/cpu')
STATE = Path('/tmp/nds-h3d-clock.json')
TARGET = 1000000


def read(path):
    return path.read_text().strip()


def write(path, value):
    path.write_text(str(value) + '\n')


def policies():
    # Both Cortex-A9 CPUs share one policy on 6.18. Do not configure it twice.
    return list(dict.fromkeys((CPU / ('cpu%d/cpufreq' % n)).resolve() for n in (0, 1)))


def probe():
    if not (CPU / 'cpu0/cpufreq/scaling_max_freq').exists():
        subprocess.run(['modprobe', 'socfpga-cpufreq'], check=True, timeout=10)
    for root in policies():
        if not os.access(root / 'scaling_max_freq', os.W_OK):
            raise RuntimeError('CPU clock control is unavailable: ' + str(root))
        available = []
        for name in ('scaling_available_frequencies', 'scaling_boost_frequencies'):
            if (root / name).exists():
                available += read(root / name).split()
        if str(TARGET) not in available:
            raise RuntimeError('CPU does not advertise the required 1 GHz frequency')
        governors = read(root / 'scaling_available_governors').split()
        if not all(g in governors for g in ('powersave', 'performance')):
            raise RuntimeError('CPU lacks the required clock governors')


def snapshot():
    return {'policies': [dict(path=str(root), **{
        name: read(root / name) for name in
        ('scaling_min_freq', 'scaling_max_freq', 'scaling_governor', 'boost')
        if (root / name).exists()}) for root in policies()],
        'boost': read(CPU / 'cpufreq/boost') if (CPU / 'cpufreq/boost').exists() else None}


def low_clock(roots):
    # Boost may reset policy->max to 1.2 GHz. Hold the minimum governor until
    # the 1 GHz ceiling is installed, so that frequency is never selected.
    for root in roots:
        minimum = read(root / 'cpuinfo_min_freq')
        write(root / 'scaling_min_freq', minimum)
        write(root / 'scaling_governor', 'powersave')


def restore():
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text())
    roots = [Path(p['path']) for p in state['policies']]
    # Never follow a saved arbitrary path, including after a malformed file.
    if roots != policies():
        raise RuntimeError('Saved CPU policies no longer match this kernel')
    low_clock(roots)
    if state['boost'] is not None and read(CPU / 'cpufreq/boost') != state['boost']:
        write(CPU / 'cpufreq/boost', state['boost'])
    for root, saved in zip(roots, state['policies']):
        if 'boost' in saved and read(root / 'boost') != saved['boost']:
            write(root / 'boost', saved['boost'])
        write(root / 'scaling_max_freq', saved['scaling_max_freq'])
        write(root / 'scaling_min_freq', saved['scaling_min_freq'])
        write(root / 'scaling_governor', saved['scaling_governor'])
    STATE.unlink()


def start():
    probe()
    if not STATE.exists():
        tmp = STATE.with_suffix('.new')
        with open(tmp, 'x') as out:
            json.dump(snapshot(), out)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE)
    try:
        roots = policies()
        low_clock(roots)
        if (CPU / 'cpufreq/boost').exists() and read(CPU / 'cpufreq/boost') != '1':
            write(CPU / 'cpufreq/boost', 1)
        for root in roots:
            if (root / 'boost').exists() and read(root / 'boost') != '1':
                write(root / 'boost', 1)
            write(root / 'scaling_max_freq', TARGET)
            write(root / 'scaling_governor', 'performance')
        for attempt in range(20):
            if all(read(r / 'scaling_max_freq') == str(TARGET) and
                   read(r / 'scaling_cur_freq') == str(TARGET) for r in roots):
                return
            time.sleep(0.05)
        raise RuntimeError('CPU did not reach the requested 1 GHz clock')
    except BaseException:
        restore()
        raise


def main():
    os.umask(0o077)
    with open(str(STATE) + '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        {'probe': probe, 'start': start, 'restore': restore}[sys.argv[1]]()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('H3D clock: ' + str(error), file=sys.stderr)
        sys.exit(1)
