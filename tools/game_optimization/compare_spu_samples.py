#!/usr/bin/env python3
"""Compare the existing oracle's little-endian 16-byte audio trace records.

FIFO/decoded events pair by channel, start generation and ordinal. Different
lengths stay explicit. Output events pair by exact mix index, never an estimated
lag. This is diagnostic evidence, not permission to accept differing audio.
"""
import argparse
import csv
import json
from pathlib import Path
import numpy as np
from compare_event_traces import digest


def load_records(path, expected):
    if path.stat().st_size != expected * 16:
        raise ValueError('Audio record length/count mismatch: ' + str(path))
    return np.memmap(path, dtype='<u4', mode='r', shape=(expected, 4)) if expected else np.empty((0, 4), dtype='<u4')


def compare_generations(first, second, starts):
    result = dict(rows=[len(first), len(second)], paired=0, payload_mismatches=0,
                  unpaired=[0, 0], differing_mix_indices=0, min_mix_delta=None,
                  max_mix_delta=None, differing_generations=[], first_mismatches=[])
    groups = []
    limits = [starts, starts] if isinstance(starts, int) else starts
    for data, limit in zip([first, second], limits):
        if len(data) and (np.any(data[1:, 0] < data[:-1, 0]) or
                          np.any(data[1:, 1] < data[:-1, 1]) or
                          np.any(data[:, 0] == 0) or np.any(data[:, 0] > limit)):
            raise ValueError('Invalid audio generation or mix order')
        ids, offsets, counts = np.unique(data[:, 0], return_index=True, return_counts=True)
        groups.append({int(g): (int(at), int(n)) for g, at, n in zip(ids, offsets, counts)})
    for generation in sorted(set(groups[0]) | set(groups[1])):
        a, ac = groups[0].get(generation, (0, 0))
        b, bc = groups[1].get(generation, (0, 0))
        count = min(ac, bc)
        left, right = first[a:a+count], second[b:b+count]
        changed = np.any(left[:, 2:] != right[:, 2:], axis=1)
        mismatches = int(changed.sum())
        result['paired'] += count
        result['payload_mismatches'] += mismatches
        result['unpaired'][0] += ac - count
        result['unpaired'][1] += bc - count
        delta = right[:, 1].astype(np.int64) - left[:, 1].astype(np.int64)
        result['differing_mix_indices'] += int(np.count_nonzero(delta))
        if count:
            lo, hi = int(delta.min()), int(delta.max())
            result['min_mix_delta'] = lo if result['min_mix_delta'] is None else min(lo, result['min_mix_delta'])
            result['max_mix_delta'] = hi if result['max_mix_delta'] is None else max(hi, result['max_mix_delta'])
        if ac != bc or mismatches:
            result['differing_generations'].append(dict(generation=generation, counts=[ac, bc], payload_mismatches=mismatches))
        for at in np.flatnonzero(changed)[:max(0, 10-len(result['first_mismatches']))]:
            result['first_mismatches'].append(dict(generation=generation, ordinal=int(at),
                                                 control=left[at].tolist(), candidate=right[at].tolist()))
    result['complete_payload_match'] = not (result['payload_mismatches'] or any(result['unpaired']))
    return result


def compare_mix_output(first, second, *, mixed=False):
    for data in [first, second]:
        if len(data) and np.any(data[1:, 1] <= data[:-1, 1]):
            raise ValueError('Output mix indices must be strictly increasing')
    common, ai, bi = np.intersect1d(first[:, 1], second[:, 1], assume_unique=True, return_indices=True)
    left, right = first[ai], second[bi]
    columns = [2, 3] if mixed else [0, 2, 3]
    changed = np.any(left[:, columns] != right[:, columns], axis=1)
    result = dict(rows=[len(first), len(second)], paired=len(common),
                  unpaired=[len(first)-len(common), len(second)-len(common)],
                  payload_mismatches=int(changed.sum()), first_mismatches=[
                      dict(mix_index=int(common[i]), control=left[i].tolist(), candidate=right[i].tolist())
                      for i in np.flatnonzero(changed)[:10]])
    if mixed and len(common):
        delta = right[:, 2:].astype(np.uint16).view(np.int16).astype(np.int32) - left[:, 2:].astype(np.uint16).view(np.int16).astype(np.int32)
        result['max_signed16_delta'] = int(np.abs(delta).max())
    result['complete_payload_match'] = not (result['payload_mismatches'] or any(result['unpaired']))
    return result


def compare(control, candidate):
    def table(root, name):
        with (root / name).open() as source:
            return list(csv.DictReader(source))
    totals = [table(root, 'spu_sample_summary.csv') for root in [control, candidate]]
    starts = [table(root, 'spu_starts.csv') for root in [control, candidate]]
    windows = [table(root, 'spu_output_windows.csv') for root in [control, candidate]]
    if windows[0] != windows[1]:
        raise ValueError('Different output capture windows')
    for summary in totals:
        if [int(r['channel']) for r in summary] != list(range(16)):
            raise ValueError('Invalid channel summary')
    report = dict(control=str(control), candidate=str(candidate), format_version=1,
                  output_windows=windows[0], channels=[], input_sha256={}, accepted=False)
    for channel in range(16):
        counts = [summary[channel] for summary in totals]
        begin = [[r for r in rows if int(r['channel']) == channel] for rows in starts]
        for rows, summary in zip(begin, counts):
            if [int(r['generation']) for r in rows] != list(range(1, int(summary['starts'])+1)):
                raise ValueError('Invalid channel start generations')
        entry = dict(channel=channel, starts=[len(x) for x in begin], start_payload_mismatches=0,
                     first_start_mismatches=[], start_unpaired=abs(len(begin[0])-len(begin[1])))
        for a, b in zip(*begin):
            changed = [key for key in a if key not in ['frame', 'mix_calls'] and a[key] != b[key]]
            if changed:
                entry['start_payload_mismatches'] += 1
                if len(entry['first_start_mismatches']) < 10:
                    entry['first_start_mismatches'].append(dict(columns=changed, control=a, candidate=b))
        for kind, column in [('fifo', 'fifo_words'), ('samples', 'decoded_samples'), ('output', 'output_samples')]:
            paths = [root / f'spu_{kind}_{channel}.bin' for root in [control, candidate]]
            arrays = [load_records(path, int(summary[column])) for path, summary in zip(paths, counts)]
            entry[kind] = (compare_mix_output(*arrays) if kind == 'output' else
                           compare_generations(*arrays, starts=entry['starts']))
            for path in paths:
                report['input_sha256'][str(path)] = digest(path)
        report['channels'].append(entry)
    paths = [root / 'spu_mixed.bin' for root in [control, candidate]]
    mixed_counts = [int(table(root, 'spu_mixed_summary.csv')[0]['records']) for root in [control, candidate]]
    report['mixed'] = compare_mix_output(*[load_records(path, count) for path, count in zip(paths, mixed_counts)], mixed=True)
    for root in [control, candidate]:
        for name in ['spu_sample_summary.csv', 'spu_starts.csv', 'spu_output_windows.csv', 'spu_mixed_summary.csv', 'spu_mixed.bin']:
            path = root / name
            report['input_sha256'][str(path)] = digest(path)
    report['scope'] = 'Actual observed FIFO words and decoded steps, grouped by channel/start generation. Output compared at equal mix indices in declared windows. Unpaired records remain explicit; no estimated-lag alignment or non-bit-exact acceptance.'
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('control', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    result = compare(args.control, args.candidate)
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps([{key: value for key, value in row.items() if key in ['channel', 'starts', 'start_payload_mismatches', 'start_unpaired']} | {
        name: {key: row[name][key] for key in ['rows', 'payload_mismatches', 'unpaired', 'complete_payload_match']}
        for name in ['fifo', 'samples', 'output']} for row in result['channels']], indent=2))
    print('Mixed output:', json.dumps(result['mixed']))
