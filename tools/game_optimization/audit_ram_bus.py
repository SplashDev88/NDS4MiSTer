#!/usr/bin/env python3
"""Check observed sound reads against preceding observed main-RAM stores.

This validates the recorded ordering, not general write-watch completeness.
Uninitialized bytes and reads inconsistent with recorded writes stay explicit.
No source data or timing difference is masked or accepted.
"""
import argparse
import csv
import json
from pathlib import Path
from compare_event_traces import digest


def audit_rows(rows):
    memory = {}
    counts = dict(write=0, sound_read=0, sound_control=0)
    result = dict(records=0, counts=counts, fully_known_reads=0,
                  reads_with_unknown_bytes=0, inconsistent_reads=0,
                  first_unknown=[], first_inconsistent=[], accepted=False)
    for ordinal, row in enumerate(rows):
        if int(row['ordinal']) != ordinal:
            raise ValueError('RAM bus event ordinals must be continuous')
        kind = row['kind']
        if kind not in counts:
            raise ValueError('Unknown RAM bus event kind')
        width, address, value = int(row['width']), int(row['address'], 16), int(row['value'], 16)
        if width not in [8, 16, 32] or not 0 <= value < 1 << width or not 0 <= address <= 0xffffffff:
            raise ValueError('Invalid bus access')
        size = width // 8
        if address + size > 1 << 32 or (kind != 'sound_control' and not 0x02000000 <= address < address+size <= 0x02400000):
            raise ValueError('RAM bus access outside supported physical main RAM')
        counts[kind] += 1
        result['records'] += 1
        if kind == 'write':
            for offset in range(size):
                memory[address+offset] = ((value >> (8*offset)) & 255, ordinal)
        elif kind == 'sound_read':
            unknown, inconsistent = [], []
            for offset in range(size):
                at, actual = address+offset, (value >> (8*offset)) & 255
                previous = memory.get(at)
                if previous is None:
                    unknown.append(hex(at))
                elif previous[0] != actual:
                    inconsistent.append(dict(address=hex(at), observed=actual,
                                             prior_value=previous[0], write_ordinal=previous[1]))
            if unknown:
                result['reads_with_unknown_bytes'] += 1
                if len(result['first_unknown']) < 10:
                    result['first_unknown'].append(dict(read_ordinal=ordinal, addresses=unknown))
            else:
                result['fully_known_reads'] += 1
            if inconsistent:
                result['inconsistent_reads'] += 1
                if len(result['first_inconsistent']) < 10:
                    result['first_inconsistent'].append(dict(read_ordinal=ordinal, bytes=inconsistent))
    result['observed_reads_consistent'] = counts['sound_read'] > 0 and not (result['reads_with_unknown_bytes'] or result['inconsistent_reads'])
    result['scope'] = 'Observed main-RAM byte stores preceding observed sound fetches, in trace event order. Does not prove arbitrary host/state-loader/JIT write coverage or approve changed audio.'
    return result


def audit(path):
    with path.open() as stream:
        result = audit_rows(csv.DictReader(stream))
    result.update(input=str(path), input_sha256=digest(path))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    result = audit(args.trace)
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps(result, indent=2))
