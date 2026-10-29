#!/usr/bin/env python3
"""Audit guarded buffer snapshots across declared upload/reset phases.

All sites, layouts and fields come from a fixture. Source recurrence alone does
not establish destination liveness, skipped-write safety or native performance.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from analyze_memory_recurrence import read_events, require


def audit(events, fixture):
    sites = {int(s['pc'], 0): s for s in fixture['sites']}
    require(len(sites) == len(fixture['sites']), 'Duplicate site')
    phases = fixture['phases']
    require(len(phases) >= 2 and len(phases) == len(set(phases)), 'Invalid phases')
    for site in sites.values():
        require(site['code_guards'], 'Missing code guard')
    for case in fixture['instances'].values():
        names = [f['name'] for f in case['fields']]
        require(names and len(names) == len(set(names)), 'Ambiguous fields')
    active, prior, results, annotations = {}, {}, {}, {}
    for event in events:
        site = sites.get(event['pc'])
        require(site is not None, 'Unknown site')
        require(event['cpu'] == site['cpu'] and event['mode'] == site['mode'] and
                event['opcode'] == int(site['opcode'], 0), 'Instruction identity mismatch')
        for guard in site['code_guards']:
            address, data = event['spans'][guard['span']]
            require(address == int(guard['address'], 0) and
                    hashlib.sha256(data).hexdigest() == guard['sha256'], 'Code context mismatch')
        if 'annotation_register' in site:
            annotations.setdefault(site['name'], Counter())[hex(event['regs'][site['annotation_register']])] += 1
            continue
        phase = site['phase']
        require(phase in phases, 'Unknown phase')
        header_address, header = event['spans'][site['header_span']]
        payload_address, payload = event['spans'][site['payload_span']]
        key = hex(header_address)
        require(key in fixture['instances'], 'Unknown instance')
        group = active.setdefault(key, [])
        require(len(group) < len(phases) and phase == phases[len(group)], 'Phase order differs')
        if group:
            require(event['frame'] == group[0]['frame'], 'Group crosses frame')
        group.append(dict(frame=event['frame'], header=header, address=payload_address, data=payload))
        if len(group) != len(phases):
            continue
        case = fixture['instances'][key]
        summary = results.setdefault(key, dict(label=case['label'], groups=0,
                    headers={p: Counter() for p in phases}, fields={}, changes={}, addresses=set()))
        summary['groups'] += 1
        for p, sample in zip(phases, group):
            summary['headers'][p][sample['header'].hex()] += 1
        # Every configured field is an explicit complete strided block. No padding
        # is silently ignored, and all compared spans must cover the entire field.
        for field in case['fields']:
            require(field['count'] > 0 and field['width'] > 0 and field['stride'] >= field['width'], 'Invalid field layout')
            values = []
            for sample in group:
                blocks = []
                for n in range(field['count']):
                    address = int(field['address'], 0) + n * field['stride']
                    offset = address - sample['address']
                    require(0 <= offset and offset + field['width'] <= len(sample['data']), 'Field outside snapshot')
                    blocks.append(sample['data'][offset:offset + field['width']])
                values.append(tuple(blocks))
            stats = summary['fields'].setdefault(field['name'], dict(blocks_per_group=field['count'],
                    bytes_per_block=field['width'], upload_blocks=0, previous_upload_comparisons=0,
                    unchanged_since_previous_upload=0, unique_upload_blocks=set()))
            stats['upload_blocks'] += field['count']
            stats['unique_upload_blocks'].update(values[0])
            previous_key = key, field['name']
            if previous_key in prior:
                stats['previous_upload_comparisons'] += field['count']
                stats['unchanged_since_previous_upload'] += sum(a == b for a,b in zip(prior[previous_key], values[0]))
            prior[previous_key] = values[0]
            for i in range(len(phases)-1):
                name = phases[i] + '_to_' + phases[i+1]
                change = summary['changes'].setdefault(name, {}).setdefault(field['name'],
                            dict(changed_blocks=0, compared_blocks=0))
                change['compared_blocks'] += field['count']
                change['changed_blocks'] += sum(a != b for a,b in zip(values[i], values[i+1]))
        summary['addresses'].update(hex(sample['address']) for sample in group)
        del active[key]
    require(not active and results, 'Incomplete or empty groups')
    require(set(results) == set(fixture['instances']), 'Missing expected instance')
    for summary in results.values():
        summary['addresses'] = sorted(summary['addresses'])
        summary['headers'] = {p: dict(v) for p,v in summary['headers'].items()}
        for stats in summary['fields'].values():
            stats['unique_upload_blocks'] = len(stats['unique_upload_blocks'])
    return dict(state='completed_guarded_staged_buffer_census', instances=results,
                annotations={k:dict(v) for k,v in annotations.items()},
                scope='Declared source fields only. No destination readback, intervening writer, reader lifetime, write-skip safety or native speed claim.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--neutrality', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    qualified = json.loads(args.neutrality.read_text())
    require(qualified['state'] == 'passed_observer_neutrality' and
            qualified['raw_file_equalities'] and all(qualified['raw_file_equalities'].values()) and
            qualified['trace_sha256'] == sha(args.trace), 'Unqualified observer trace')
    result = audit(read_events(args.trace), json.loads(args.fixture.read_text()))
    result['pins'] = {str(p): sha(p) for p in [args.trace, args.fixture, args.neutrality, Path(__file__)]}
    require(not args.output.exists(), 'Refusing to overwrite evidence')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
