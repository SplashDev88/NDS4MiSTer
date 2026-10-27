#!/usr/bin/env python3
"""Check non-interpolated channel output against observed samples and commands.

Uses the existing SPU SetCnt/Run arithmetic: volume/shift/pan derive from the
recorded writes, and CurSample from the recorded decoder steps. Does not
resynthesize audio, fit lag, change traces or approve an output difference.
"""
import argparse
import csv
import json
from pathlib import Path
import numpy as np
from compare_spu_samples import load_records


def control_states(root):
    state = [0] * 16
    updates = [[] for _ in range(16)]
    with (root / 'spu_writes.csv').open() as source:
        for row in csv.DictReader(source):
            address, width, value = int(row['address'], 16), int(row['width']), int(row['value'], 16)
            if not 0x04000400 <= address < 0x04000500:
                continue
            offset, channel = address & 15, (address >> 4) & 15
            if (width, offset) not in [(8, 0), (8, 1), (8, 2), (8, 3), (16, 0), (16, 2), (32, 0)]:
                continue
            mask = ((1 << width) - 1) << (8 * offset)
            state[channel] = ((state[channel] & ~mask) | (value << (8 * offset))) & 0xff7f837f
            updates[channel].append((int(row['mix_calls']), state[channel]))
    return updates


def iter_observations(root):
    with (root / 'spu_starts.csv').open() as source:
        if any(int(row['interpolation']) != 0 for row in csv.DictReader(source)):
            raise ValueError('This explanation requires interpolation disabled')
    with (root / 'spu_sample_summary.csv').open() as source:
        totals = list(csv.DictReader(source))
    if [int(row['channel']) for row in totals] != list(range(16)):
        raise ValueError('Invalid channel summary')
    controls = control_states(root)
    for channel, counts in enumerate(totals):
        samples = load_records(root / f'spu_samples_{channel}.bin', int(counts['decoded_samples']))
        output = load_records(root / f'spu_output_{channel}.bin', int(counts['output_samples']))
        mix = output[:, 1]
        if len(samples) and np.any(samples[1:, 1] < samples[:-1, 1]):
            raise ValueError('Non-monotonic decoded mix indices')
        raw = np.zeros(len(output), dtype=np.int64)
        if len(samples):
            at = np.searchsorted(samples[:, 1], mix, side='right') - 1
            valid = at >= 0
            valid &= samples[np.maximum(at, 0), 0] == output[:, 0]
            raw[valid] = (samples[at[valid], 3] & 0xffff).astype(np.uint16).view(np.int16).astype(np.int64)
        cnt = np.zeros(len(output), dtype=np.uint32)
        if controls[channel]:
            entries = np.array(controls[channel], dtype=np.uint64)
            if np.any(entries[1:, 0] < entries[:-1, 0]):
                raise ValueError('Non-monotonic control-write mix indices')
            # A write observed after mix k affects subsequent mix callbacks.
            at = np.searchsorted(entries[:, 0], mix, side='left') - 1
            valid = at >= 0
            cnt[valid] = entries[at[valid], 1]
        volume = (cnt & 127).astype(np.int64)
        volume[volume == 127] = 128
        shift = np.array([4, 3, 2, 0], dtype=np.int64)[(cnt >> 8) & 3]
        pan = (cnt >> 16) & 127
        pan[pan == 127] = 128
        predicted = (raw << shift) * volume
        predicted[(cnt & 0x80000000) == 0] = 0
        actual = output[:, 2].view('<i4').astype(np.int64)
        changed = (predicted != actual) | (pan != output[:, 3])
        summary = dict(channel=channel,records=len(output),unexplained_records=int(changed.sum()),
                              first_unexplained=[dict(record=output[i].tolist(),raw_sample=int(raw[i]),
                                                     cnt=hex(int(cnt[i])),predicted=int(predicted[i]),pan=int(pan[i]))
                                                 for i in np.flatnonzero(changed)[:10]])
        yield dict(output=output, raw=raw, cnt=cnt, volume=volume, shift=shift, pan=pan, actual=actual), summary


def observe(root):
    """Materialize observations for callers that explicitly need every channel."""
    pairs = list(iter_observations(root))
    return [record for record, _ in pairs], [summary for _, summary in pairs]


def compare(control, candidate):
    result = dict(control=str(control),candidate=str(candidate),control_checks=[],candidate_checks=[],
                  channels=[],accepted=False)
    # Keep only one pair of channels live; full-replay output can be large.
    pairs = zip(iter_observations(control), iter_observations(candidate))
    for channel, ((left, ar), (right, br)) in enumerate(pairs):
        result['control_checks'].append(ar)
        result['candidate_checks'].append(br)
        if not np.array_equal(left['output'][:, 1], right['output'][:, 1]):
            raise ValueError('Different output mix coverage; do not silently align it')
        value = left['actual'] != right['actual']
        pan = left['pan'] != right['pan']
        sample = left['raw'] != right['raw']
        effective = (left['volume'] != right['volume']) | (left['shift'] != right['shift']) | ((left['cnt'] ^ right['cnt']) & 0x80000000 != 0)
        result['channels'].append(dict(channel=channel,value_or_pan_differences=int(np.count_nonzero(value|pan)),
                                       different_sample_only=int(np.count_nonzero((value|pan)&sample&~effective&~pan)),
                                       different_control_only=int(np.count_nonzero((value|pan)&~sample&(effective|pan))),
                                       both_sample_and_control=int(np.count_nonzero((value|pan)&sample&(effective|pan))),
                                       neither_explains=int(np.count_nonzero((value|pan)&~sample&~effective&~pan))))
    result['scope']='Exact channel-output arithmetic check in recorded windows using actual decoded steps and control writes. No audio resynthesis or phase fitting. Unobserved resets/configuration or interpolation would require additional evidence; this is not native or audibility qualification.'
    return result


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('control',type=Path)
    parser.add_argument('candidate',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():raise FileExistsError(args.output)
    result=compare(args.control,args.candidate)
    with args.output.open('x') as output:json.dump(result,output,indent=2);output.write('\n')
    print(json.dumps(result,indent=2))
