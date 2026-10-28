#!/usr/bin/env python3
"""Summarize existing normalized geometry events; never infer removability."""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import statistics
import struct


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def summarize(rows, first, last):
    kinds, commands, setters, repeated, callers = (Counter() for _ in range(5))
    state, streams, geometry = {}, [], []
    opened = False
    stream, stream_first, leading, trailing = [], None, 0, 0
    previous_time, records, dma_words, unknown_cpu_words = None, 0, 0, 0
    # These one-parameter state assignments are recurrence leads, not bypasses.
    assignments = {0x10, 0x29, 0x2a, 0x2b, 0x30, 0x31, 0x60}
    for ordinal, row in enumerate(rows):
        require(int(row['ordinal']) == ordinal, 'Noncontiguous event ordinals')
        frame, timestamp = int(row['replay_frame']), int(row['timestamp'])
        require(first <= frame < last, 'Event outside capture window')
        require(previous_time is None or timestamp >= previous_time, 'Time moved backwards')
        previous_time, records = timestamp, ordinal + 1
        kind = row['kind']
        require(kind in ('command', 'frame', 'register'), 'Unknown event kind')
        kinds[kind] += 1
        a, b, c = (int(row[key], 16) for key in ('a', 'b', 'c'))
        require(all(0 <= x <= 0xffffffff for x in (a, b, c)), 'Invalid word')
        if kind == 'frame':
            geometry.append({'replay_frame': frame, 'core_frame': int(row['core_frame']),
                             'vertices': a, 'polygons': b, 'flush_attributes': c})
            continue
        if kind != 'command':
            continue
        require(a <= 255 and c == 0, 'Invalid command record')
        commands[a] += 1
        dma = int(row['dma_executing_mask'], 16)
        valid = int(row['last_profile_valid'])
        require(valid in (0, 1), 'Invalid PC-valid flag')
        if dma:
            dma_words += 1
        elif valid:
            callers[(int(row['last_profile_pc'], 16), int(row['lr'], 16),
                     int(row['last_profile_opcode'], 16))] += 1
        else:
            unknown_cpu_words += 1
        if a in assignments:
            setters[a] += 1
            if state.get(a) == b:
                repeated[a] += 1
            state[a] = b
        # A window may start/end halfway through a submitted frame. Only
        # intervals bounded by two observed SWAP_BUFFERS packets are complete.
        if not opened:
            leading += 1
        else:
            stream.append((a, b))
            if stream_first is None:
                stream_first = frame
        if a == 0x50:
            if opened:
                digest = hashlib.sha256(b''.join(struct.pack('<BI', *x) for x in stream)).hexdigest()
                streams.append({'first_replay_frame': stream_first, 'last_replay_frame': frame,
                                'parameter_packets': len(stream), 'command_parameter_sha256': digest})
            opened, stream, stream_first = True, [], None
    trailing = len(stream)
    require(records > 0 and commands and geometry and streams, 'Insufficient geometry capture')
    hashes = [x['command_parameter_sha256'] for x in streams]
    def distribution(key):
        values = [x[key] for x in geometry]
        return {'min': min(values), 'median': statistics.median(values), 'max': max(values)}
    return {
        'records': records, 'capture_frames': [first, last], 'event_counts': dict(kinds),
        'command_parameter_packets': {hex(k): v for k, v in commands.most_common()},
        'cpu_context_parameter_packets': sum(callers.values()),
        'dma_parameter_packets': dma_words, 'unattributed_parameter_packets': unknown_cpu_words,
        'CPU_contexts': [{'last_profile_pc': hex(pc), 'lr': hex(lr),
                          'last_profile_opcode': hex(op), 'parameter_packets': count}
                         for (pc, lr, op), count in callers.most_common(30)],
        'state_assignment_recurrence': [
            {'command': hex(k), 'packets': setters[k], 'same_as_previous_assignment': repeated[k]}
            for k in sorted(setters)],
        'complete_swap_intervals': len(streams), 'distinct_swap_interval_payloads': len(set(hashes)),
        'adjacent_identical_swap_intervals': sum(a == b for a, b in zip(hashes, hashes[1:])),
        'excluded_leading_parameter_packets': leading, 'excluded_trailing_parameter_packets': trailing,
        'geometry_frame_samples': len(geometry), 'vertices': distribution('vertices'),
        'polygons': distribution('polygons'), 'swap_intervals': streams, 'geometry_frames': geometry,
        'limits': [
            'Normalized command parameter packets are not grouped multi-parameter commands or native cycle shares.',
            'Identical command/parameter streams do not prove identical VRAM, palettes, matrices or all external dependencies.',
            'Repeated state assignments are leads, not safe deletions; preserve pipeline, query, IRQ and timing effects.',
            'CPU contexts are instantaneous instruction/LR observations, not proven function entries or call stacks. DMA events are not attributed to a CPU caller.',
            'Frame events report the existing renderer geometry counters at its flush boundary, not unique visual FPS or visibility.',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--window', type=Path, required=True)
    parser.add_argument('--qualification', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    qualification = json.loads(args.qualification.read_text())
    require(qualification['state'] == 'passed_full_unchanged_replay', 'Observer not qualified')
    for path in (args.trace, args.window):
        require(qualification['pins'][str(path.resolve())] == sha(path), 'Capture pin differs')
    bounds = list(csv.DictReader(args.window.open()))
    require(len(bounds) == 1, 'Invalid window metadata')
    first, last = (int(bounds[0][k]) for k in ('first_frame', 'last_frame_exclusive'))
    with args.trace.open() as stream:
        result = summarize(csv.DictReader(stream), first, last)
    require(result['records'] == int(bounds[0]['records']), 'Record total differs')
    result['state'] = 'qualified_geometry_census_no_patch'
    result['pins'] = {str(p.resolve()): sha(p) for p in
                      (args.trace, args.window, args.qualification, Path(__file__))}
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('swap_intervals', 'geometry_frames', 'pins')}))


if __name__ == '__main__':
    main()
