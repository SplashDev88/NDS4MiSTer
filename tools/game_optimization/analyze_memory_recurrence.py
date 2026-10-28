#!/usr/bin/env python3
"""Exact byte/register recurrence in guarded snapshots of an unpatched replay."""
import argparse
from collections import Counter, OrderedDict
import csv
import hashlib
import json
from pathlib import Path
import statistics


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_events(path):
    events = []
    with Path(path).open() as stream:
        for row in csv.DictReader(stream):
            number = int(row['event'])
            if number == len(events):
                events.append(dict(frame=int(row['frame']), cpu=int(row['cpu']),
                                   pc=int(row['pc'], 16), mode=row['mode'],
                                   opcode=int(row['opcode'], 16), cpsr=int(row['cpsr'], 16),
                                   regs=tuple(int(row['r'+str(n)], 16) for n in range(16)), spans=[]))
            require(number == len(events)-1, 'Noncontiguous event order')
            event = events[-1]
            require(int(row['span']) == len(event['spans']), 'Noncontiguous span order')
            require((int(row['frame']), int(row['cpu']), int(row['pc'], 16), row['mode'],
                     int(row['opcode'], 16), int(row['cpsr'], 16),
                     tuple(int(row['r'+str(n)], 16) for n in range(16))) ==
                    (event['frame'], event['cpu'], event['pc'], event['mode'],
                     event['opcode'], event['cpsr'], event['regs']), 'Span event metadata differs')
            data = bytes.fromhex(row['bytes'])
            address, length = int(row['address'], 16), int(row['length'])
            if row.get('space') == 'regs':
                require(address == length == 0 and not data, 'Register-only snapshot carries memory')
            else:
                require(len(data) == length > 0, 'Snapshot length differs')
            event['spans'].append((address, data))
    require(events, 'Empty snapshots')
    return events


def pair_events(events, fixture):
    stack, calls = [], []
    entry = int(fixture['entry_pc'], 0)
    exits = {int(x, 0) for x in fixture.get('exit_pcs', [fixture.get('exit_pc')])}
    for event in events:
        require(event['cpu'] == fixture['cpu'], 'Unexpected CPU')
        if event['pc'] == entry:
            require(not stack, 'Nested invocations require separate recurrence analysis')
            stack.append(event)
            continue
        require(event['pc'] in exits and stack, 'Unpaired exit or unexpected PC')
        if fixture.get('conditional_arm_exits'):
            require(event['mode'] == 'arm', 'Conditional exits require ARM mode')
            if not arm_condition(event['opcode'] >> 28, event['cpsr']):
                continue
        begin = stack.pop()
        for relation in fixture['register_deltas']:
            reg, delta = relation['register'], relation['delta']
            require(event['regs'][reg] == (begin['regs'][reg]+delta) & 0xffffffff,
                    'Entry/exit register relation differs')
        for guard in fixture.get('exit_register_values', []):
            require(event['regs'][guard['register']] == int(guard['value'], 0),
                    'Exit register value differs')
        for relation in fixture['output_addresses']:
            require(event['spans'][relation['span']][0] ==
                    (begin['regs'][relation['entry_register']]+relation.get('offset', 0)) & 0xffffffff,
                    'Output span does not match entry pointer')
        for relation in fixture.get('saved_entry_registers', []):
            data = event['spans'][relation['span']][1]
            offset = relation['offset']
            require(len(data[offset:offset+4]) == 4 and
                    int.from_bytes(data[offset:offset+4], 'little') == begin['regs'][relation['register']],
                    'Saved entry register differs')
        inputs = tuple(begin['spans'][n][1] for n in fixture['input_spans'])
        outputs = tuple(event['spans'][n][1] for n in fixture['output_spans'])
        outputs += tuple(event['regs'][n].to_bytes(4, 'little') for n in fixture.get('output_registers', []))
        key_regs = tuple(begin['regs'][n] for n in fixture['key_registers'])
        source = begin['spans'][fixture['source_span']] if fixture['source_span'] is not None else (None, None)
        calls.append(dict(first_frame=begin['frame'], last_frame=event['frame'],
                          key=(inputs, key_regs), output=outputs,
                          source=source[1], source_address=source[0], exit_pc=event['pc']))
    require(not stack and calls, 'Unfinished or empty invocation trace')
    return calls


def arm_condition(condition, cpsr):
    n, z, c, v = (bool(cpsr & (1 << bit)) for bit in [31, 30, 29, 28])
    require(0 <= condition < 15, 'Unsupported ARM condition')
    return [z, not z, c, not c, n, not n, v, not v, c and not z,
            not c or z, n == v, n != v, not z and n == v, z or n != v, True][condition]


def recurrence(calls):
    seen, last, distances, frame_distances = {}, {}, [], []
    output_conflicts, adjacent = 0, 0
    for n, call in enumerate(calls):
        key = call['key']  # bytes themselves are the identity; no digest-only match.
        if key in seen:
            output_conflicts += call['output'] != seen[key]['output']
            distances.append(n-last[key][0])
            frame_distances.append(call['first_frame']-last[key][1])
            adjacent += n-last[key][0] == 1
        else:
            seen[key] = call
        last[key] = (n, call['first_frame'])
    def distribution(values):
        return dict(min=min(values), median=statistics.median(values), max=max(values)) if values else None
    lru = {}
    for capacity in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]:
        cache, hits = OrderedDict(), 0
        for call in calls:
            key = call['key']
            if key in cache:
                hits += 1
                cache.move_to_end(key)
            else:
                cache[key] = None
                if len(cache) > capacity:
                    cache.popitem(last=False)
        lru[str(capacity)] = hits
    return dict(calls=len(calls), unique_complete_inputs=len(seen), exact_reuse_calls=len(distances),
                exact_reuse_percent=100*len(distances)/len(calls) if calls else 0,
                repeated_inputs_with_different_outputs=output_conflicts,
                adjacent_reuse_calls=adjacent, reuse_distance_calls=distribution(distances),
                reuse_distance_frames=distribution(frame_distances),
                source_snapshot_calls=sum(c['source'] is not None for c in calls),
                unique_source_contents=len({c['source'] for c in calls if c['source'] is not None}),
                unique_source_addresses=len({c['source_address'] for c in calls if c['source_address'] is not None}),
                lru_hits_by_entry_capacity=lru,
                unique_input_payload_bytes=sum(sum(map(len, key[0]))+4*len(key[1]) for key in seen),
                unique_output_payload_bytes=sum(sum(map(len, c['output'])) for c in seen.values()),
                input_payload_sizes=dict(Counter(sum(map(len, c['key'][0]))+4*len(c['key'][1]) for c in calls)),
                output_payload_sizes=dict(Counter(sum(map(len, c['output'])) for c in calls)))


def analyze(events, fixture):
    if 'capture_frames' in fixture:
        first, last = fixture['capture_frames']
        require(all(first <= e['frame'] < last for e in events), 'Event outside capture window')
    calls = pair_events(events, fixture)
    start, end = fixture['selected_frames']
    selected = [c for c in calls if start <= c['first_frame'] < end]
    prior, warm_hits = set(), 0
    for call in calls:
        if start <= call['first_frame'] < end and call['key'] in prior:
            warm_hits += 1
        prior.add(call['key'])
    result = dict(selected_window=recurrence(selected),
                selected_window_hits_with_prior_route_history=warm_hits,
                selected_frames=[start, end], first_call_frame=calls[0]['first_frame'],
                last_call_frame=calls[-1]['last_frame'], paired_calls=len(calls),
                return_sites=dict(Counter(hex(c['exit_pc']) for c in calls)),
                scope='Exact captured inputs only. Declared key completeness and external constant tables need independent proof. LRU counts omit lookup, copy, metadata, invalidation and timing costs; not a cache implementation or native speed result.')
    result['captured_window' if 'capture_frames' in fixture else 'full_route'] = recurrence(calls)
    if 'capture_frames' in fixture:
        result['capture_frames'] = fixture['capture_frames']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--status', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    status = json.loads(args.status.read_text())
    require(status['state'] == 'passed_replay_equivalence' and status['mode'] == 'off',
            'A passed unpatched golden replay is required')
    require(status['admission']['state'] == 'unchanged' and
            all(status['output_file_equality'].values()) and
            not any(status['differing_state_frames'].values()) and
            status['checkpoint_RAM_equal_after_exact_code_normalization'], 'Incomplete golden agreement')
    require(status['outputs']['memory_watch.csv'] == sha(args.trace), 'Trace digest differs')
    fixture = json.loads(args.fixture.read_text())
    result = analyze(read_events(args.trace), fixture)
    result.update(state='completed_exact_input_recurrence', unpatched_golden_exact=True,
                  pins={str(p.resolve()):sha(p) for p in [args.trace, args.fixture, args.status, Path(__file__)]},
                  accepted=False, native_measured=False)
    require(not args.output.exists(), 'Refusing to overwrite recurrence receipt')
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['paired_calls', 'full_route', 'captured_window', 'selected_window'] if k in result}, indent=2))


if __name__ == '__main__':
    main()
