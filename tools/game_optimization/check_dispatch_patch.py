#!/usr/bin/env python3
"""Exercise a manifest-supplied ARM table dispatcher with observable handlers.

Reuse the generic Unicorn runner. Check all registers, CPSR, data/stack bytes
and ordered accesses, including a handler that saves its full entry state.
This does not model interrupt/DMA interleaving or native instruction timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import struct

from check_halfword_copy_patch import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--patch', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    manifest = json.loads(args.manifest.read_text())
    patch, = [p for p in manifest['patches'] if p['id'] == args.patch]
    assert patch['cpu'] == 'arm9' and patch['mode'] == 'arm'
    assert patch['pattern'] == 'linear-key-handler-dispatch'
    before, after = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
    assert len(before) == len(after)
    entry = int(patch['addr'], 0)
    rng = random.Random(20261027)
    cases = []
    for count in [0, -1, -2, -2147483648, 1, 2, 5, 28, 44, 115, 138, 255, 256]:
        positions = [-1] if count <= 0 else sorted({-1, 0, count // 2, count - 1})
        for position in positions:
            for flags in range(16):
                for thumb in [False, True]:
                    cases.append((count, position, flags, thumb, False))
    for count in [2, 5, 28, 138, 256]:
        for flags in range(16):
            cases.append((count, 0, flags, False, True))
    for _ in range(256):
        count = rng.randrange(1, 257)
        cases.append((count, rng.randrange(-1, count), rng.randrange(16),
                      bool(rng.randrange(2)), bool(rng.randrange(2))))

    # ARM handler saves/restores all entry registers, changes flags/registers
    # and performs a data store. Its saved LR catches a moved dispatch call.
    arm_handler = struct.pack('<9I', 0xe92d5fff, 0xe8bd5fff, 0xe0900001,
                              0xe023300c, 0xe59fc008, 0xe58c0000,
                              0xe2900001, 0xe12fff1e, 0x03000d00)
    thumb_handler = struct.pack('<6H', 0xb500, 0x1840, 0x2207,
                                0x4050, 0xb001, 0x4770)
    counts = {}
    for index, (count, position, flags, thumb, duplicates) in enumerate(cases):
        memory = bytearray(rng.getrandbits(8) for _ in range(4096))
        keys = rng.sample(range(0x10000), max(count, 1))
        key = 0xffffffff if position < 0 else keys[position]
        if duplicates and position >= 0:
            keys[-1] = key  # First-match order must be preserved.
        handler = 0x03000b00 | int(thumb)
        for n, value in enumerate(keys):
            struct.pack_into('<II', memory, 0x100 + n * 8, value, handler)
        body = thumb_handler if thumb else arm_handler
        memory[0xb00:0xb00 + len(body)] = body
        regs = [rng.getrandbits(32) for _ in range(15)]
        regs[1:4] = [key, 0x03000100, count & 0xffffffff]
        regs[13] = 0x03000f80
        regs[14] = (entry & ~4095) + 0xff0 + (index & 1)
        cpsr = (flags << 28) | 0x1f
        a, ac = run(before, entry, bytes(memory), regs, cpsr)
        b, bc = run(after, entry, bytes(memory), regs, cpsr)
        assert a == b, (index, count, position, flags, thumb,
                        [k for k in a if a[k] != b[k]])
        group = f'{count}:hit={position}:thumb={int(thumb)}'
        counts.setdefault(group, set()).add((ac, bc, len(a['accesses'])))
    result = dict(state='passed_synthetic_function_equivalence', cases=len(cases),
                  seed=20261027, patch_id=patch['id'],
                  manifest_sha256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  runner_sha256=hashlib.sha256(Path(__file__).with_name('check_halfword_copy_patch.py').read_bytes()).hexdigest(),
                  exact_checks=['R0-R12, SP/LR/PC, CPSR', 'all mapped data and stack bytes',
                                'ordered read/write address, width and value',
                                'ARM handler entry state and saved return address'],
                  coverage=['zero/negative signed counts', 'first/middle/last hit and miss',
                            'unsorted keys and duplicate-key precedence', 'all initial NZCV combinations',
                            'ARM/Thumb handlers and ARM/Thumb caller returns',
                            'handler side effects and flags'],
                  counts={k: [dict(before_instructions=a, after_instructions=b, accesses=n)
                              for a, b, n in sorted(v)] for k, v in counts.items()},
                  limitations='Synthetic ordinary memory only; aligned table and valid handler pointers. '
                              'No interrupt/DMA/cache, whole-game or native speed qualification.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['state', 'cases', 'coverage']}))


if __name__ == '__main__':
    main()
