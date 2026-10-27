#!/usr/bin/env python3
"""Compare a bounded ARM block using the existing Unicorn equivalence runner.

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
    assert patch['mode'] == 'arm'
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
        a, ac = run(before, entry, bytes(memory), values, cpsr, stop=stop, extra_memory=extra)
        b, bc = run(bytes(after), entry, bytes(memory), values, cpsr, stop=stop, extra_memory=extra)
        assert a == b, (index, [k for k in a if a[k] != b[k]])
        counts.add((ac, bc, len(a['accesses'])))
    assert fixture['cases']
    result = dict(state='passed_synthetic_block_equivalence', cases=len(fixture['cases']),
                  patch_id=patch['id'], manifest_sha256=fixture['manifest_sha256'],
                  fixture_sha256=hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                  counts=[dict(before_instructions=a, after_instructions=b, data_accesses=n)
                          for a, b, n in sorted(counts)],
                  exact_checks=['R0-R12', 'SP/LR/PC', 'CPSR', 'all mapped data memory', 'ordered read/write address/size/value'],
                  limits='Synthetic block only; mapped MMIO pages are ordinary memory. No native timing, interrupt/DMA/cache, full-game or native qualification.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
