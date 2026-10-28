#!/usr/bin/env python3
"""Verify guarded transfer snapshots against an immutable source image."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

from analyze_memory_recurrence import pair_events, read_events, recurrence, require, sha


def audit(events, fixture, source, regions):
    """Addresses, ABI constraints and source-region names are supplied by fixtures."""
    first, last = fixture['capture_frames']
    require(0 <= first < last and 0 < fixture['transfer_bytes'] <= 4096 and
            fixture['source_alignment'] > 0 and fixture['minimum_source_offset'] >= 0,
            'Invalid capture or transfer bounds')
    require(all(first <= event['frame'] < last for event in events),
            'Event outside capture window')
    require(all(a['frame'] <= b['frame'] for a, b in zip(events, events[1:])),
            'Frame order moved backward')
    paired = pair_events(events, fixture)
    require(len(events) == 2 * len(paired), 'Transfer audit requires two events per transfer')
    groups = defaultdict(list)
    for region in regions:
        require(0 <= region['start'] < region['end'] <= len(source), 'Invalid source region')
        require(region['group'] and region['id'] and region['id'] != '__uncovered_bytes__',
                'Missing or reserved region identity')
        groups[region['group']].append(region)
    for group in groups.values():
        group.sort(key=lambda region: region['start'])
        require(len({region['id'] for region in group}) == len(group), 'Duplicate region identity')
        require(all(a['end'] <= b['start'] for a, b in zip(group, group[1:])),
                'Regions overlap within one classification group')
    counts = defaultdict(Counter)
    classification = defaultdict(dict)
    calls, details, contexts = [], [], Counter()
    for begin, end in zip(events[::2], events[1::2]):
        for name, event in [('entry', begin), ('exit', end)]:
            require(event['mode'] == fixture['mode'] and
                    event['opcode'] == int(fixture[name + '_opcode'], 0),
                    'Transfer mode or opcode differs')
        for relation in fixture.get('stable_spans', []):
            require(begin['spans'][relation['entry']] == end['spans'][relation['exit']],
                    'Transfer context changed')
        for guard in fixture.get('span_word_checks', []):
            require(guard['event'] in ['entry', 'exit'] and guard['offset'] >= 0,
                    'Invalid snapshot word guard')
            event = begin if guard['event'] == 'entry' else end
            data = event['spans'][guard['span']][1]
            word = data[guard['offset']:guard['offset'] + 4]
            require(len(word) == 4, 'Word guard outside snapshot')
            actual = int.from_bytes(word, 'little') & int(guard['mask'], 0)
            expected = (event['regs'][guard['register']] if 'register' in guard
                        else int(guard['value'], 0))
            require(actual == expected, 'Snapshot word guard differs')
        for guard in fixture.get('masked_register_checks', []):
            require(guard['event'] in ['entry', 'exit'], 'Invalid register guard event')
            event = begin if guard['event'] == 'entry' else end
            require(event['regs'][guard['register']] & int(guard['mask'], 0) ==
                    int(guard['value'], 0), 'Masked register guard differs')
        offset = begin['regs'][fixture['source_register']]
        destination, payload = end['spans'][fixture['payload_span']]
        length = fixture['transfer_bytes']
        require(offset >= fixture['minimum_source_offset'] and
                offset % fixture['source_alignment'] == 0 and
                offset + length <= len(source), 'Source span outside declared range or alignment')
        require(len(payload) == length and payload == source[offset:offset + length],
                'Transferred bytes differ from immutable source image')
        context = begin['regs'][fixture['context_register']]
        contexts[hex(context)] += 1
        calls.append(dict(first_frame=begin['frame'], last_frame=end['frame'],
                          key=((), (offset,)), output=(payload,), source=payload,
                          source_address=offset))
        labels = {}
        for name, group in groups.items():
            covered = 0
            labels[name] = []
            for region in group:
                overlap = max(0, min(offset + length, region['end']) - max(offset, region['start']))
                if not overlap:
                    continue
                counts[name][region['id']] += overlap
                item = classification[name].setdefault(region['id'],
                    dict(transfer_participations=0, source_offsets=set()))
                item['transfer_participations'] += 1
                item['source_offsets'].add(offset)
                labels[name].append(region['id'])
                covered += overlap
            counts[name]['__uncovered_bytes__'] += length - covered
        details.append(dict(first_frame=begin['frame'], last_frame=end['frame'],
                            source_offset=offset, destination=hex(destination),
                            context=hex(context), source_regions=labels))
    for name, group in classification.items():
        for identity, item in group.items():
            item['overlap_bytes'] = counts[name][identity]
            item['unique_source_offsets'] = len(item.pop('source_offsets'))
    return dict(state='passed_transfer_source_comparison', capture_frames=[first, last],
                transfers=len(calls), matched_bytes=len(calls) * fixture['transfer_bytes'],
                recurrence_by_source_offset=recurrence(calls),
                repeated_content_calls=len(calls) - len({call['source'] for call in calls}),
                frame_spanning_transfers=sum(c['first_frame'] != c['last_frame'] for c in calls),
                contexts=dict(contexts), region_classification=dict(classification),
                uncovered_bytes_by_group={name: count['__uncovered_bytes__']
                                          for name, count in counts.items()},
                transfers_detail=details,
                scope='Only the declared completed transfers and capture window. Source identity, '
                      'returned bytes and recurrence do not establish safe skipping, earlier completion, '
                      'IRQ/DMA equivalence, scratch availability or native performance.')


def validate_evidence(status, trace_digest, source_digest):
    require(status['state'] == 'passed_replay_equivalence' and status['mode'] == 'off' and
            status['admission']['state'] == 'unchanged' and
            status['output_file_equality'] and all(status['output_file_equality'].values()) and
            status['differing_state_frames'] and not any(status['differing_state_frames'].values()) and
            status['checkpoint_RAM_equal_after_exact_code_normalization'],
            'Passed unpatched golden replay required')
    require(status['outputs']['memory_watch.csv'] == trace_digest, 'Trace digest differs')
    require(status['virtual_image_sha256'] == source_digest, 'Immutable source digest differs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--status', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--regions', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    status = json.loads(args.status.read_text())
    validate_evidence(status, sha(args.trace), sha(args.source))
    result = audit(read_events(args.trace), json.loads(args.fixture.read_text()),
                   args.source.read_bytes(), json.loads(args.regions.read_text()))
    result.update(unpatched_golden_exact=True, accepted=False, native_measured=False,
                  pins={str(path): sha(path) for path in
                        [args.trace, args.fixture, args.status, args.source, args.regions,
                         Path(__file__), Path(__file__).with_name('analyze_memory_recurrence.py')]})
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({key: result[key] for key in
                      ['state', 'transfers', 'matched_bytes', 'repeated_content_calls']}))


if __name__ == '__main__':
    main()
