#!/usr/bin/env python3
"""Replay complete keys through the measured isolated boolean-cache lookup.

Compute a deliberately optimistic integration bound, not native performance.
The fixture supplies original return-path entry counts and captured input spans.
"""
import argparse
from collections import Counter
import json
from pathlib import Path

from analyze_memory_recurrence import read_events, pair_events, require, sha
from check_boolean_cache_lookup import slot_for_key, SLOTS, STRIDE


def estimate(events, fixture, synthetic):
    first, last = fixture['capture_frames']
    require(all(first <= e['frame'] < last for e in events), 'Event outside capture window')
    calls = pair_events(events, fixture)
    entries = [e for e in events if e['pc'] == int(fixture['entry_pc'], 0)]
    require(len(entries) == len(calls), 'Entry count differs')
    costs = {int(pc, 0):value for pc,value in fixture['baseline_return_entries'].items()}
    measured = {}
    for kind, rows in synthetic['groups'].items():
        require(len(rows) == 1, 'Nonconstant component cost requires a finer model')
        measured[kind] = rows[0]['instruction_entries']
    # A non-hit tail (MVN + POP) would be replaced by the original body.
    # Credit the already executed original-shaped PUSH too. Everything else
    # needed to restore inputs, insert/evict, preserve state or branch is free
    # in this bound; real integration can only add to the stated work.
    credit = fixture['nonhit_tail_entries'] + fixture['reused_prologue_entries']
    table = [None]*SLOTS
    groups = Counter()
    original_total = optimistic_total = hit_original = perfect_total = 0
    per_call_nonbeneficial = 0
    for entry, call in zip(entries, calls):
        pieces = call['key'][0]
        require(len(pieces) == 2 and all(len(x) == 8 for x in pieces) and not call['key'][1],
                'Lookup requires two eight-byte keys and no additional key registers')
        require(len(call['output']) == 1 and len(call['output'][0]) == 4, 'Expected one word result')
        value = int.from_bytes(call['output'][0], 'little')
        require(value in [0, 1], 'Expected a boolean result')
        baseline = costs[call['exit_pc']]
        addresses = [entry['spans'][n][0] for n in fixture['input_spans']]
        key = b''.join(pieces)
        if any(address & 3 for address in addresses):
            kind = 'unaligned'
        else:
            slot = slot_for_key(key)
            old = table[slot]
            if old is None:
                kind = 'cold'
            elif old[0] == key:
                require(old[1] == value, 'Identical key produced a different boolean')
                kind = 'hit'
            else:
                word = next(n for n in range(4) if old[0][4*n:4*n+4] != key[4*n:4*n+4])
                kind = 'collision'+str(word)
            # Miss insertion/eviction is modelled exactly for future hits but
            # deliberately charged zero instruction entries in this bound.
            table[slot] = (key, value)
        groups[kind] += 1
        perfect_total += baseline + measured['unaligned'] - credit if kind == 'unaligned' else measured['hit']
        if kind == 'hit':
            candidate = measured[kind]
            hit_original += baseline
        else:
            require(measured[kind] >= credit, 'Invalid integration credit')
            candidate = baseline + measured[kind] - credit
        original_total += baseline
        optimistic_total += candidate
        per_call_nonbeneficial += candidate >= baseline
    return dict(calls=len(calls), groups=dict(groups), actual_direct_mapped_hit_percent=100*groups['hit']/len(calls),
                table_slots=SLOTS, table_stride=STRIDE, synthetic_table_bytes=SLOTS*STRIDE,
                original_instruction_entries=original_total,
                optimistic_candidate_instruction_entries=optimistic_total,
                optimistic_increase_percent=100*(optimistic_total/original_total-1),
                perfect_aligned_hit_instruction_entries=perfect_total,
                perfect_aligned_hit_increase_percent=100*(perfect_total/original_total-1),
                original_entries_on_hits=hit_original,
                lookup_entries_on_hits=groups['hit']*measured['hit'],
                calls_without_instruction_entry_improvement=per_call_nonbeneficial,
                capture_frames=fixture['capture_frames'],
                omitted_costs=['input/volatile/flag restoration', 'miss insertion and eviction',
                               'table initialization/invalidation', 'integration branches',
                               'allocation/lifecycle management', 'memory and native CPU cycles'],
                native_gain=None, accepted=False,
                scope='Optimistic derived bound using real ARM component counts and exact direct-mapped collisions. No integrated guest patch or game storage allocation.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--status', type=Path, required=True)
    parser.add_argument('--synthetic', type=Path, required=True)
    parser.add_argument('--code', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    status = json.loads(args.status.read_text())
    require(status['state'] == 'passed_replay_equivalence' and status['mode'] == 'off' and
            status['admission']['state'] == 'unchanged', 'Passed unpatched replay required')
    require(all(status['output_file_equality'].values()) and not any(status['differing_state_frames'].values()) and
            status['checkpoint_RAM_equal_after_exact_code_normalization'], 'Golden comparison incomplete')
    require(status['outputs']['memory_watch.csv'] == sha(args.trace), 'Trace digest differs')
    synthetic = json.loads(args.synthetic.read_text())
    require(synthetic['state'] == 'passed_isolated_lookup_contract_not_patch_equivalence', 'Component checks required')
    require(synthetic['code_sha256'] == sha(args.code), 'Component code differs')
    require(synthetic['checker_sha256'] == sha(Path(__file__).with_name('check_boolean_cache_lookup.py')),
            'Hash/contract checker differs')
    fixture = json.loads(args.fixture.read_text())
    result = estimate(read_events(args.trace), fixture, synthetic)
    result.update(state='completed_lookup_cost_bound',
                  pins={str(p.resolve()):sha(p) for p in [args.trace,args.fixture,args.status,args.synthetic,args.code,Path(__file__)]})
    require(not args.output.exists(), 'Refusing to overwrite result')
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}, indent=2))


if __name__ == '__main__':
    main()
