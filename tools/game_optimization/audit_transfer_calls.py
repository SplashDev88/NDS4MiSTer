#!/usr/bin/env python3
"""Audit guarded leaf-transfer calls without reading guest memory again.

The fixture supplies code identities, ABI and address regions. This supports
the observed nonnegative, unit-aligned lengths only, not arbitrary function
equivalence. One stack span per event is required. No payload recurrence,
MMIO behavior, unused-memory claim or native speed is inferred.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path

from compare_replays import FILES


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def audit(trace, fixture):
    trace = Path(trace)
    require(sha(trace) == fixture['trace_sha256'], 'Trace identity differs')
    comparison = Path(fixture['comparison'])
    require(sha(comparison) == fixture['comparison_sha256'], 'Comparison identity differs')
    equality = json.loads(comparison.read_text())
    for name in FILES:
        result = equality.get(name, {})
        require(result.get('equal') is True and len(result.get('sha256', [])) == 2,
                'Missing or failed golden comparison')
        require(result['sha256'][0] == result['sha256'][1] == sha(trace.parent / name),
                'Golden comparison belongs to different outputs')
    regions = [(r['name'], int(r['first'], 0), int(r['last_exclusive'], 0))
               for r in fixture['regions']]
    require(all(0 <= first < last <= 2**32 for _, first, last in regions), 'Invalid regions')
    for n, (_, first, last) in enumerate(regions):
        require(all(last <= a or first >= b for _, a, b in regions[:n]), 'Overlapping regions')

    def region(address, length):
        if not length:
            return 'no_access_zero_length'
        return next((name for name, first, last in regions
                     if first <= address and address + length <= last), 'unclassified')

    sites, results = {}, {}
    for function in fixture['functions']:
        ident = function['id']
        require(ident not in results and function['unit_bytes'] in (2, 4), 'Invalid function')
        require(function['counter_rule'] in ('length', 'source_plus_length'), 'Invalid counter rule')
        results[ident] = dict(calls=0, requested_bytes=0, data_units=0, zero_length_calls=0,
                             cross_frame_calls=0, overlapping_ranges=0,
                             source_regions=Counter(), destination_regions=Counter(),
                             destination_bytes=Counter(), lengths=Counter(), callers=Counter(),
                             destination_addresses=Counter(),
                             source_alignment_mod4=Counter(), destination_alignment_mod4=Counter())
        for kind in ('entry', 'exit'):
            pc = int(function[kind], 0)
            require(pc not in sites, 'Duplicate site')
            sites[pc] = (function, kind, int(function[kind + '_opcode'], 0))
    require(sites and fixture['mode'] == 'arm', 'This audit requires declared ARM leaf routines')
    first, last = fixture['window']
    stack, count, previous_frame, max_depth = [], 0, first, 0
    with trace.open() as stream:
        for row in csv.DictReader(stream):
            require(int(row['event']) == count and int(row['span']) == 0, 'Event/span order differs')
            frame, pc = int(row['frame']), int(row['pc'], 16)
            require(first <= frame < last and frame >= previous_frame, 'Frame outside ordered window')
            previous_frame = frame
            require(pc in sites and int(row['cpu']) == fixture['cpu'], 'Unexpected CPU/site')
            function, kind, opcode = sites[pc]
            cpsr = int(row['cpsr'], 16)
            require(row['mode'] == fixture['mode'] and not (cpsr & 0x20) and
                    int(row['opcode'], 16) == opcode, 'Instruction/mode guard differs')
            regs = [int(row['r' + str(n)], 16) for n in range(16)]
            payload = bytes.fromhex(row['bytes'])
            require(regs[15] == pc + 8, 'Pipeline PC differs')
            require(row['space'] == fixture['stack_space'] and
                    int(row['address'], 16) == regs[13] and
                    len(payload) == int(row['length']) == fixture['stack_bytes'], 'Stack span differs')
            count += 1
            if kind == 'entry':
                stack.append((function['id'], frame, regs, cpsr, payload))
                max_depth = max(max_depth, len(stack))
                continue
            require(stack and stack[-1][0] == function['id'], 'Unpaired or out-of-order return')
            _, start, old, old_cpsr, old_payload = stack.pop()
            source, destination, length = old[:3]
            unit = function['unit_bytes']
            require(length <= 1024 * 1024 and length % unit == 0 and source + length < 2**32,
                    'Length outside this census ABI')
            require(all(regs[n] == old[n] for n in function['preserved_registers']),
                    'Preserved register differs')
            require(regs[0] == source + (length if function['source_advance'] else 0),
                    'Source advance differs')
            end_counter = length if function['counter_rule'] == 'length' else source + length
            require(regs[12] == end_counter and regs[1] == destination, 'Counter/destination differs')
            require(length != 0 or regs[2] == old[2], 'Zero-length call changed length register')
            require(cpsr == ((old_cpsr & 0x0fffffff) | 0x60000000), 'Final equal-compare flags differ')
            require(payload == old_payload, 'Leaf stack bytes changed')
            result = results[function['id']]
            result['calls'] += 1
            result['requested_bytes'] += length
            result['data_units'] += length // unit
            result['zero_length_calls'] += length == 0
            result['cross_frame_calls'] += frame != start
            result['overlapping_ranges'] += bool(length and source < destination + length and destination < source + length)
            result['source_regions'][region(source, length)] += 1
            extent = unit if function['destination_fixed'] else length
            target = region(destination, extent if length else 0)
            result['destination_regions'][target] += 1
            result['destination_bytes'][target] += length
            result['lengths'][str(length)] += 1
            result['callers'][f'{old[14]:08x}'] += 1
            result['destination_addresses'][f'{destination:08x}'] += 1
            result['source_alignment_mod4'][str(source % 4)] += 1
            result['destination_alignment_mod4'][str(destination % 4)] += 1
    require(count and not stack and all(r['calls'] for r in results.values()), 'Incomplete or empty calls')
    return dict(state='passed_guarded_transfer_call_census', events=count, maximum_nested_depth=max_depth,
                functions=results, window=fixture['window'], trace_sha256=fixture['trace_sha256'],
                comparison_sha256=fixture['comparison_sha256'],
                limitations='Arguments and leaf state only; no transferred payload equality/recurrence, MMIO timing, native cycles or patch acceptance.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), 'Output already exists')
    result = audit(args.trace, json.loads(args.fixture.read_text()))
    result['fixture_sha256'] = sha(args.fixture)
    result['tool_sha256'] = sha(__file__)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ('state', 'events', 'maximum_nested_depth')}))


if __name__ == '__main__':
    main()
