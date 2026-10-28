#!/usr/bin/env python3
"""Validate the existing oracle's three-column button-input format before a run.

The oracle uses formatted stream extraction. A comment or malformed token can
silently stop extraction, so this preflight rejects it rather than accepting a
partial route. Blank lines and overlapping intervals retain their existing
semantics; the oracle combines overlapping button masks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def validate(data, frames):
    if not 0 < frames <= 0xffffffff:
        raise ValueError('Frame count must fit a positive unsigned 32-bit value')
    try:
        source = data.decode('ascii')
    except UnicodeDecodeError as error:
        raise ValueError('Input must contain ASCII decimal frames and hex masks') from error
    intervals = []
    for number, line in enumerate(source.splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split()
        if (len(fields) != 3 or
                not all(re.fullmatch(r'[0-9]+', word) for word in fields[:2]) or
                not re.fullmatch(r'(?:0[xX])?[0-9a-fA-F]+', fields[2])):
            raise ValueError(f'Line {number}: expected decimal first/last frames and a hex mask; comments are unsupported')
        first, last = (int(word, 10) for word in fields[:2])
        mask = int(fields[2], 16)
        if not 0 <= first < last <= frames:
            raise ValueError(f'Line {number}: interval must satisfy 0 <= first < last <= frame count')
        if mask > 0xfff:
            raise ValueError(f'Line {number}: mask exceeds the oracle\'s 12 button bits')
        intervals.append(dict(first=first, last_exclusive=last, mask_hex=f'{mask:x}'))
    return dict(state='valid', input_sha256=hashlib.sha256(data).hexdigest(),
                frames=frames, interval_count=len(intervals), intervals=intervals,
                scope='Syntax and range preflight only; actual scene and movement still require visual and state review')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs', type=Path)
    parser.add_argument('--frames', type=int, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.inputs.read_bytes(), args.frames)
        result['inputs'] = str(args.inputs.resolve())
        encoded = json.dumps(result, indent=2) + '\n'
        if args.output:
            with args.output.open('x') as stream:
                stream.write(encoded)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps({key: result[key] for key in ('state', 'input_sha256', 'frames', 'interval_count')}))


if __name__ == '__main__':
    main()
