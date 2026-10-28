#!/usr/bin/env python3
"""Compare an ARM halfword-copy byte patch on synthetic machine states.

This diagnostic uses Unicorn like the existing NSMB hook tests. It checks
registers, flags, memory and ordered data accesses, not native CPU timing,
interrupt/DMA interleavings, cache behavior or full-game equivalence.
Game addresses and bytes are supplied only by the per-game manifest.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_MODE_THUMB, UC_HOOK_CODE, UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
from unicorn.arm_const import (
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
    UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
    UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC,
    UC_ARM_REG_CPSR,
)

REGS = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
        UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
        UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
        UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR]


def run(code, entry, memory, values, cpsr, *, stop=None, extra_memory=(),
        mode='arm', instruction_limit=20000, code_address=None):
    assert mode in ('arm', 'thumb') and bool(cpsr & 0x20) == (mode == 'thumb')
    assert entry % (2 if mode == 'thumb' else 4) == 0
    assert 0 < instruction_limit <= 1000000
    vm = Uc(UC_ARCH_ARM, UC_MODE_THUMB if mode == 'thumb' else UC_MODE_ARM)
    code_address = entry if code_address is None else code_address
    page = code_address & ~4095
    assert code_address <= entry < code_address + len(code) <= page + 4096
    vm.mem_map(page, 4096)
    vm.mem_write(code_address, code)
    vm.mem_map(0x03000000, 4096)
    vm.mem_write(0x03000000, memory)
    for address, data in extra_memory:
        assert address % 4096 == 0 and len(data) == 4096
        vm.mem_map(address, 4096)
        vm.mem_write(address, data)
    vm.reg_write(UC_ARM_REG_CPSR, cpsr)
    for reg, value in zip(REGS, values):
        vm.reg_write(reg, value)
    accesses = []
    count = 0
    stopped = False

    def instruction(uc, address, size, user):
        nonlocal count, stopped
        if address == (stop if stop is not None else values[-1] & ~1):
            stopped = True
            uc.emu_stop()
        else:
            count += 1

    def access(uc, kind, address, size, value, user):
        # Unicorn supplies a value for writes; collect the actual data on reads.
        from unicorn import UC_MEM_READ
        if kind == UC_MEM_READ:
            value = int.from_bytes(uc.mem_read(address, size), 'little')
        accesses.append((kind, address, size, value))

    vm.hook_add(UC_HOOK_CODE, instruction)
    vm.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, access)
    vm.emu_start(entry | (mode == 'thumb'), page + 4096, count=instruction_limit)
    assert stopped, 'code did not reach its stop within bounded case'
    result = dict(registers=[vm.reg_read(r) for r in REGS],
                  pc=vm.reg_read(UC_ARM_REG_PC), cpsr=vm.reg_read(UC_ARM_REG_CPSR),
                  memory=bytes(vm.mem_read(0x03000000, 4096)), accesses=accesses)
    if extra_memory:
        result['extra_memory'] = [(address, bytes(vm.mem_read(address, len(data))))
                                  for address, data in extra_memory]
    return result, count


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
    assert patch['pattern'] == 'branch-heavy-halfword-copy'
    before, after = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
    assert len(before) == len(after) and len(before) % 4 == 0
    entry = int(patch['addr'], 0)
    rng = random.Random(20261027)
    cases = []
    for size in [0, 1, 2, 3, 4, 15, 16, 17, 63, 64, 65, 127, 128, 129, 255, -1, -2, -2147483648]:
        for delta in [-256, -2, -1, 0, 1, 2, 256]:
            for alignment in [0, 1]:
                cases.append((size, delta, alignment))
    cases += [(rng.randrange(0, 257), rng.randrange(-256, 257), rng.randrange(2)) for _ in range(1024)]
    measurements = []
    for index, (size, delta, alignment) in enumerate(cases):
        memory = bytes(rng.getrandbits(8) for _ in range(4096))
        values = [rng.getrandbits(32) for _ in REGS]
        values[:3] = [0x03000400 + alignment, 0x03000400 + alignment + delta, size & 0xFFFFFFFF]
        values[-1] = (entry & ~4095) + 0xFF0 + (index % 2)
        cpsr = (rng.randrange(16) << 28) | 0x1F
        a, ac = run(before, entry, memory, values, cpsr)
        b, bc = run(after, entry, memory, values, cpsr)
        assert a == b, (index, size, delta, alignment, [k for k in a if a[k] != b[k]])
        measurements.append(dict(bytes=size, before_instructions=ac, after_instructions=bc))
    representative = {}
    for row in measurements:
        if row['bytes'] in [0, 1, 2, 16, 64, 128, 255, -1]:
            representative.setdefault(str(row['bytes']), row)
    result = dict(state='passed_synthetic_instruction_equivalence', cases=len(cases),
                  manifest_sha256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                  patch_id=patch['id'], exact_checks=['R0-R12', 'SP/LR/PC', 'CPSR', 'data memory', 'ordered read/write address/size/value'],
                  coverage=['zero/negative/odd/even lengths', 'overlap both directions', 'identical source/destination', 'unaligned addresses in Unicorn', 'initial NZCV combinations', 'ARM/Thumb return'],
                  representative_instruction_counts=representative,
                  limitations='Synthetic instruction equivalence only. Instruction counts are not native cycles or speed. No interrupt/DMA/cache, MMIO, code-overlap, full-game or native qualification. No ROM or runtime installation modified.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['state', 'cases', 'representative_instruction_counts']}))


if __name__ == '__main__':
    main()
