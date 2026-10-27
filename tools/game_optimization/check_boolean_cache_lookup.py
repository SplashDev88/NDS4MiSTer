#!/usr/bin/env python3
"""Check an isolated ARM boolean-cache lookup using the existing Unicorn runner.

This is a component contract/cost check, not full-register patch equivalence.
All addresses are synthetic. It proves no unused storage in any game.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import random
import struct

from check_halfword_copy_patch import run

ENTRY, DATA, TABLE = 0x02001000, 0x03000000, 0x03010000
SLOTS, STRIDE = 512, 32


def slot_for_key(key):
    a, b, c, d = struct.unpack('<4I', key)
    def ror(word, shift):
        return ((word >> shift) | (word << (32-shift))) & 0xffffffff
    return (a ^ ror(b, 7) ^ ror(c, 13) ^ ror(d, 19)) & (SLOTS-1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('code', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    code = args.code.read_bytes()
    rng = random.Random(20261027)
    cases = []
    for flags in range(16):
        for thumb in [False, True]:
            for value in [0, 1]:
                for kind in ['hit', 'cold', 'invalid'] + ['collision'+str(n) for n in range(4)]:
                    cases.append((bytes(16) if flags == 0 else rng.randbytes(16), flags, thumb, value, kind, 0, 0))
            for a, b in [(0, 1), (0, 2), (0, 3), (2, 0), (2, 2)]:
                cases.append((rng.randbytes(16), flags, thumb, 0, 'unaligned', a, b))
    groups = defaultdict(set)
    for key, flags, thumb, value, kind, align_a, align_b in cases:
        memory = bytearray(rng.randbytes(4096))
        source_a, source_b = 0x100+align_a, 0x200+align_b
        memory[source_a:source_a+8] = key[:8]
        memory[source_b:source_b+8] = key[8:]
        table = bytearray(SLOTS*STRIDE)
        at = slot_for_key(key)*STRIDE
        stored = bytearray(key)
        if kind.startswith('collision'):
            word = int(kind[-1]); bit = [9, 16, 22, 28][word]
            original = struct.unpack_from('<I', stored, word*4)[0]
            struct.pack_into('<I', stored, word*4, original ^ (1 << bit))
            assert stored != key and slot_for_key(stored) == slot_for_key(key)
        table[at:at+16] = stored
        valid = 0 if kind == 'cold' else 2 if kind == 'invalid' else 1
        struct.pack_into('<II', table, at+16, value, valid)
        extra = [(TABLE+n, bytes(table[n:n+4096])) for n in range(0, len(table), 4096)]
        regs = [rng.getrandbits(32) for _ in range(15)]
        regs[0:2] = [DATA+source_a, DATA+source_b]
        regs[13], regs[14] = DATA+0xf80, ENTRY+0xff0+int(thumb)
        result, count = run(code, ENTRY, bytes(memory), regs, (flags << 28) | 0x1f, extra_memory=extra)
        expected = value if kind == 'hit' else 0xfffffffe if kind == 'unaligned' else 0xffffffff
        assert result['registers'][0] == expected, (kind, flags)
        for n in list(range(3, 12))+[13]:
            assert result['registers'][n] == regs[n], (kind, n)
        assert result['pc'] == regs[14] & ~1
        assert bool(result['cpsr'] & 0x20) == thumb
        expected_memory = memory.copy()
        struct.pack_into('<II', expected_memory, 0xf78, regs[3], regs[14])
        assert result['memory'] == expected_memory
        assert result['extra_memory'] == extra
        from unicorn import UC_MEM_READ, UC_MEM_WRITE
        writes = [a for a in result['accesses'] if a[0] == UC_MEM_WRITE]
        assert writes == [(UC_MEM_WRITE, DATA+0xf78, 4, regs[3]), (UC_MEM_WRITE, DATA+0xf7c, 4, regs[14])]
        if kind == 'unaligned':
            assert all(DATA+0xf78 <= a[1] < DATA+0xf80 for a in result['accesses'])
        reads = [a for a in result['accesses'] if a[0] == UC_MEM_READ]
        groups[kind].add((count, len(reads), len(writes), sum(a[2] for a in result['accesses'])))
    output = dict(state='passed_isolated_lookup_contract_not_patch_equivalence', cases=len(cases),
                  code_sha256=hashlib.sha256(code).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  runner_sha256=hashlib.sha256(Path(__file__).with_name('check_halfword_copy_patch.py').read_bytes()).hexdigest(),
                  table_slots=SLOTS, table_stride=STRIDE, synthetic_table_bytes=SLOTS*STRIDE,
                  groups={k:[dict(instruction_entries=n, read_accesses=r, write_accesses=w, access_bytes=b)
                             for n,r,w,b in sorted(values)] for k,values in groups.items()},
                  checks=['complete-key collisions at each of four words', 'zero/random keys',
                          'valid/cold/invalid marker', 'both boolean payloads', 'all NZCV states',
                          'ARM/Thumb return', 'alignment rejection without input/table reads',
                          'R3-R11/SP preserved', 'only original-shaped eight-byte stack stores',
                          'input and cache bytes unchanged'],
                  limitations='No miss insertion or original-function integration. Other volatile registers and flags are clobbered; no full patch equivalence. Synthetic ordinary memory only; no interrupt, DMA, cache, allocation, lifecycle or native timing proof.')
    args.output.write_text(json.dumps(output, indent=2)+'\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
