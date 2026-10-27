#!/usr/bin/env python3
"""Compare ordered diagnostic CSV events separately from their timing columns.

This does not align, drop, mask or approve differing events. Ordinals must be
continuous from zero. A matching prefix with an unmatched tail is incomplete.
"""
import argparse
import csv
import hashlib
import itertools
import json
from pathlib import Path


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def compare(control, candidate, payload, timing):
    required = ['ordinal'] + payload + timing
    if not payload or len(set(required)) != len(required):
        raise ValueError('Payload columns are required; selected columns must be unique and exclude ordinal')
    result = dict(control=str(control), candidate=str(candidate),
                  input_sha256=[digest(control), digest(candidate)],
                  payload_columns=payload, timing_columns=timing,
                  rows=[0, 0], paired=0, payload_mismatches=0,
                  first_payload_mismatches=[], timing={
                      name: dict(differing=0, min_delta=None, max_delta=None)
                      for name in timing})
    with control.open() as first, candidate.open() as second:
        readers = [csv.DictReader(first), csv.DictReader(second)]
        for reader in readers:
            if not reader.fieldnames or len(reader.fieldnames) != len(set(reader.fieldnames)):
                raise ValueError('Missing or duplicate CSV header')
            if not set(required).issubset(reader.fieldnames):
                raise ValueError('Missing required column')
        for ordinal, rows in enumerate(itertools.zip_longest(*readers)):
            for index, row in enumerate(rows):
                if row is not None:
                    if None in row or any(row[name] in (None, '') for name in required):
                        raise ValueError('Malformed CSV row')
                    if int(row['ordinal']) != ordinal:
                        raise ValueError('Discontinuous event ordinal')
                    result['rows'][index] += 1
            if any(row is None for row in rows):
                continue
            result['paired'] += 1
            changed = [name for name in payload if rows[0][name] != rows[1][name]]
            if changed:
                result['payload_mismatches'] += 1
                if len(result['first_payload_mismatches']) < 10:
                    result['first_payload_mismatches'].append(dict(
                        ordinal=ordinal, columns=changed, control=rows[0], candidate=rows[1]))
            for name in timing:
                delta = int(rows[1][name]) - int(rows[0][name])
                item = result['timing'][name]
                item['differing'] += int(delta != 0)
                item['min_delta'] = delta if item['min_delta'] is None else min(delta, item['min_delta'])
                item['max_delta'] = delta if item['max_delta'] is None else max(delta, item['max_delta'])
    result['unpaired'] = [count - result['paired'] for count in result['rows']]
    result['complete_payload_match'] = bool(result['paired']) and not (
        result['payload_mismatches'] or any(result['unpaired']))
    result['accepted'] = False
    result['scope'] = 'Literal event payload comparison by ordinal; timing statistics do not establish equivalent behavior or an approved tolerance.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('control', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--payload', required=True, nargs='+')
    parser.add_argument('--timing', nargs='*', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.control, args.candidate, args.payload, args.timing)
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps({name: result[name] for name in [
        'rows', 'paired', 'payload_mismatches', 'unpaired', 'complete_payload_match', 'timing']}))
