#!/usr/bin/env python3
"""Compare complete outputs from two deterministic software-reference replays."""
import argparse
import hashlib
import json
from pathlib import Path

FILES = ('frames.csv', 'state.csv', 'audio.s16le', 'save.bin', 'mainram.bin', 'itcm.bin')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    results = {}
    for name in FILES:
        paths = [directory / name for directory in (args.baseline, args.candidate)]
        if not all(path.is_file() for path in paths):
            results[name] = {'equal': False, 'error': 'Required evidence is missing'}
            continue
        values = [path.read_bytes() for path in paths]
        results[name] = {
            'equal': values[0] == values[1],
            'bytes': [len(value) for value in values],
            'sha256': [hashlib.sha256(value).hexdigest() for value in values],
        }
    output = json.dumps(results, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    print(output, end='')
    return 0 if all(result['equal'] for result in results.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
