#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only collector for NDS_ARM9_PC_PROFILE diagnostic bitstreams.

Run on MiSTer while an isolated game session is active. No SPI, CPU halt,
register writes or memory writes. Histogram counts are observed wall-time
samples, not instructions, FPS, or proof that an entire frame was sampled.
"""
import argparse
from collections import Counter, defaultdict
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess
import time


def collect_native(seconds, interval, executable):
    run = subprocess.run([str(executable.resolve(strict=True)),str(round(seconds*1000)),str(round(interval*1e6))],
                         capture_output=True,text=True,timeout=seconds+45,check=True)
    lines=run.stdout.splitlines()
    magic,session,elapsed,cpu,count,gaps=lines[0].split(',')
    if magic!='NDS-PC-v1' or len(lines)-1!=int(count):
        raise RuntimeError('Invalid native sample stream')
    records=[];frames=defaultdict(Counter);flags=Counter()
    for line in lines[1:]:
        ns,pc,meta=map(int,line.split(','))
        if meta>>28!=0xb:raise RuntimeError('Invalid native sample tag')
        frame=(meta>>8)&65535;state=(meta>>24)&15
        records.append([ns/1e9,frame,pc,state,meta&255])
        frames[frame][pc,state]+=1;flags[state]+=1
    return dict(version=1,backend='native',session=int(session),seconds=seconds,
                elapsed_seconds=int(elapsed)/1e9,collector_cpu_seconds=int(cpu)/1e9,
                interval=interval,observed_samples=len(records),missed_sequence_minimum=int(gaps),
                flags={str(k):v for k,v in flags.items()},
                columns=['seconds','guest_frame16','architectural_r15','flags','sequence8'],
                samples=records,per_frame={str(k):[[pc,state,n] for (pc,state),n in v.most_common()]
                                         for k,v in frames.items()},
                limitations='Debug wall-time samples, not FPS. CPU time excludes post-capture serialization. '
                    'Gaps are modulo 256 lower bounds. Frame IDs wrap. Flags: reset=8,halt=4,DMA=2,Thumb=1.')


def collect(seconds, interval):
    frames = defaultdict(Counter)
    flags = Counter()
    records = []
    gaps = 0
    session = None
    previous = None
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    try:
        with mmap.mmap(fd, 4096, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ,
                       offset=0x3fc00000) as page:
            start = time.monotonic()
            cpu_start = time.process_time()
            def health():
                # Uncached MMIO reads are expensive on HPS. Faults are latched
                # and sessions change monotonically, so audit every 10 ms and
                # at both endpoints instead of rereading 128 bytes per sample.
                magic, = struct.unpack('<I', page[0:4])
                current_session, = struct.unpack('<I', page[8:12])
                faults = struct.unpack('<II', page[32:40])
                if magic != 0x31443348 or faults != (0, 0):
                    raise RuntimeError('No healthy H3D session')
                return current_session
            session = health()
            next_health = start + .01
            while time.monotonic()-start < seconds:
                now = time.monotonic()
                if now >= next_health:
                    if health() != session:
                        raise RuntimeError('Session changed; sample discarded')
                    next_health = now + .01
                raw = page[96:104]
                if raw != page[96:104]:
                    continue
                pc, meta = struct.unpack('<II', raw)
                elapsed = time.monotonic()-start
                if meta >> 28 != 0xb:
                    if elapsed > 1:
                        raise RuntimeError('Bitstream lacks NDS_ARM9_PC_PROFILE tag')
                    time.sleep(interval)
                    continue
                if raw != previous:
                    if previous is not None:
                        prev_meta = struct.unpack('<II', previous)[1]
                        gaps += ((meta-prev_meta-1) & 255)
                    previous = raw
                    frame = (meta >> 8) & 65535
                    state = (meta >> 24) & 15
                    # Retain the architectural R15 value. Mapping it to a
                    # current instruction requires the CPU's pipeline convention.
                    frames[frame][(pc, state)] += 1
                    flags[state] += 1
                    records.append([elapsed, frame, pc, state, meta & 255])
                time.sleep(interval)
            if health() != session:
                raise RuntimeError('Session changed; sample discarded')
            elapsed_seconds = time.monotonic()-start
            process_cpu_seconds = time.process_time()-cpu_start
    finally:
        os.close(fd)
    if not records:
        raise RuntimeError('No samples')
    return dict(version=1, session=session, seconds=seconds,
                elapsed_seconds=elapsed_seconds,
                collector_cpu_seconds=process_cpu_seconds,
                interval=interval, observed_samples=len(records),
                missed_sequence_minimum=gaps,
                flags={str(k):v for k,v in flags.items()},
                columns=['seconds','guest_frame16','architectural_r15','flags','sequence8'],
                samples=records,
                per_frame={str(k):[[pc,state,n] for (pc,state),n in v.most_common()]
                           for k,v in frames.items()},
                limitations='Debug wall-time samples; observer overhead is unqualified. '
                    'Gaps are modulo 256 lower bounds. Frame numbers wrap at 65536. '
                    'Flags: reset=8,halt=4,DMA hold=2,Thumb=1. '
                    'Architectural R15 is retained without assuming a PC bias.')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--seconds',type=float,default=20)
    p.add_argument('--interval',type=float,default=.0004)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--native',type=Path,help='Compiled arm9_pc_sample helper; formats results after sampling')
    a=p.parse_args()
    if not 1<=a.seconds<=60 or not .0001<=a.interval<=.01:
        p.error('bounded collection requires 1–60 seconds and 0.1–10 ms polling')
    # Reserve the destination before collecting; never overwrite evidence.
    with a.output.open('x') as f:
        result=(collect_native(a.seconds,a.interval,a.native) if a.native
                else collect(a.seconds,a.interval))
        json.dump(result,f,indent=2)
        f.write('\n')
