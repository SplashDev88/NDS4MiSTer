#!/usr/bin/env python3
"""Compare a bounded ARM/Thumb block using the existing equivalence runner.

Game addresses, byte context, register assignments and memory overrides come
from a private JSON fixture. Seeded 4-KiB ordinary-memory pages model data;
they do not model MMIO side effects, interrupts, DMA or native cycle timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random

from check_halfword_copy_patch import run


def compare_accesses(original, replacement, elidable_read_ranges=()):
    """Allow only a subsequence that drops reads of declared ordinary RAM.

    Writes and all other reads retain their order, size and value. This models
    no concurrent writer or MMIO; that contract needs separate runtime evidence.
    """
    from unicorn import UC_MEM_READ
    for first, end in elidable_read_ranges:
        assert 0x03000000 <= first < end <= 0x03001000
    def removable(access):
        kind, address, size, _ = access
        return kind == UC_MEM_READ and any(a <= address and address+size <= b
                                          for a, b in elidable_read_ranges)
    cursor = skipped = 0
    for access in replacement:
        while cursor < len(original) and original[cursor] != access:
            assert removable(original[cursor]), 'Changed/reordered required access'
            cursor += 1
            skipped += 1
        assert cursor < len(original), 'New or changed access'
        cursor += 1
    for access in original[cursor:]:
        assert removable(access), 'Removed required access'
        skipped += 1
    return skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    manifest = json.loads(args.manifest.read_text())
    fixture = json.loads(args.fixture.read_text())
    assert hashlib.sha256(args.manifest.read_bytes()).hexdigest() == fixture['manifest_sha256']
    patch, = [p for p in manifest['patches'] if p['id'] == fixture['patch_id']]
    assert patch['mode'] in ('arm', 'thumb')
    entry, stop = int(fixture['entry'], 0), int(fixture['stop'], 0)
    before = bytes.fromhex(fixture['code'])
    after = bytearray(before)
    offset = int(patch['addr'], 0) - entry
    expected, replacement = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
    assert 0 <= offset and offset+len(expected) <= len(before)
    assert before[offset:offset+len(expected)] == expected and len(expected) == len(replacement)
    assert entry <= stop <= entry+len(before)
    after[offset:offset+len(expected)] = replacement
    counts = set()
    read_ranges = [(int(a, 0), int(b, 0)) for a, b in fixture.get('elidable_read_ranges', [])]
    for index, case in enumerate(fixture['cases']):
        rng = random.Random(case['memory_seed'])
        memory = bytearray(rng.getrandbits(8) for _ in range(4096))
        for change in case.get('memory_overrides', []):
            at = change['offset']
            data = bytes.fromhex(change['hex'])
            assert 0 <= at and at+len(data) <= len(memory)
            memory[at:at+len(data)] = data
        extra = [(int(address, 0), bytes(4096)) for address in fixture.get('extra_pages', [])]
        values = [int(value, 0) for value in case['registers']]
        assert len(values) == 15
        cpsr = int(case['cpsr'], 0)
        options = dict(stop=stop, extra_memory=extra, mode=patch['mode'],
                       instruction_limit=fixture.get('instruction_limit', 20000))
        a, ac = run(before, entry, bytes(memory), values, cpsr, **options)
        b, bc = run(bytes(after), entry, bytes(memory), values, cpsr, **options)
        old_accesses, new_accesses = a.pop('accesses'), b.pop('accesses')
        skipped = compare_accesses(old_accesses, new_accesses, read_ranges)
        assert a == b, (index, [k for k in a if a[k] != b[k]])
        counts.add((ac, bc, len(old_accesses), len(new_accesses), skipped))
    assert fixture['cases']
    result = dict(state='passed_synthetic_block_equivalence', cases=len(fixture['cases']),
                  patch_id=patch['id'], manifest_sha256=fixture['manifest_sha256'],
                  fixture_sha256=hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                  counts=[dict(before_instructions=a, after_instructions=b, data_accesses=n,
                               after_data_accesses=m, elided_ordinary_reads=k)
                          for a, b, n, m, k in sorted(counts)],
                  elidable_read_ranges=fixture.get('elidable_read_ranges', []),
                  exact_checks=['R0-R12', 'SP/LR/PC', 'CPSR', 'all mapped data memory',
                                'ordered writes and required reads; only declared ordinary reads may be dropped'],
                  limits='Synthetic block only; mapped MMIO pages are ordinary memory. No native timing, interrupt/DMA/cache, full-game or native qualification.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
