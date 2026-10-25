#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline ARM instruction checks using supplied, owned NSMB cartridges.

Requires Unicorn on the development computer. No cartridge data is written.
Tests the packet replacement against the original and the bone caller guards;
it does not establish visual equivalence of the existing bone-read tradeoff.
"""
import argparse
import json
from pathlib import Path
import struct
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_R4, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC
from ndspy import code
from prepare import Source
from nsmb_runtime import assemble


def run(path):
    with open(path, 'rb') as f:
        source = Source(f.fileno())
        header = source.read(0, 512)
        a, _, base, size = struct.unpack_from('<4I', header, 32)
        original = code.MainCodeFile(source.read(a, size), base)
        image = assemble(source, 'lookup+bones')
        h = b''.join(image.blocks(0, 512))
        a, _, base, size = struct.unpack_from('<4I', h, 32)
        patched = code.MainCodeFile(b''.join(image.blocks(a, a+size)), base)
    registry = json.loads((Path(__file__).parent/'nsmb_hooks.json').read_text())
    p = next(p for p in registry['profiles'] if p['game_code'].encode() == header[12:16])
    rel = {int(k, 16): int(v, 16) for k, v in p['relocations'].items()}
    entry = next(h['address'] for h in p['hooks'] if h['flag'] == 'packet_lookup')
    stop = 0x023ff000
    calls = []
    remote_result = 0

    def hook(uc, address, size, _):
        if address == rel[0x02046e98]:
            calls.append(uc.reg_read(UC_ARM_REG_R0))
            uc.reg_write(UC_ARM_REG_R0, remote_result)
            uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))

    machines = []
    for arm in (original, patched):
        uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        uc.mem_map(0x02000000, 0x400000)
        uc.mem_write(base, bytes(arm.sections[0].data))
        uc.hook_add(UC_HOOK_CODE, hook)
        machines.append(uc)
    cases = 0
    for mode in range(10):
        for local in (0, 1, 7):
            for arg in (0, 1, 7, 8, 0x10001, 0xffff):
                for remote_result in (0, 0x02210000):
                    results = []
                    for uc in machines:
                        calls.clear()
                        uc.mem_write(rel[0x020887fc], bytes([mode]))
                        uc.mem_write(rel[0x020887f0], bytes([local]))
                        uc.reg_write(UC_ARM_REG_R0, arg)
                        uc.reg_write(UC_ARM_REG_R4, 0x12345678)
                        uc.reg_write(UC_ARM_REG_SP, 0x023fe000)
                        uc.reg_write(UC_ARM_REG_LR, stop)
                        uc.emu_start(entry, stop, count=1000)
                        assert uc.reg_read(UC_ARM_REG_PC) == stop
                        assert uc.reg_read(UC_ARM_REG_SP) == 0x023fe000
                        assert uc.reg_read(UC_ARM_REG_R4) == 0x12345678
                        results.append((uc.reg_read(UC_ARM_REG_R0), tuple(calls)))
                    assert results[0] == results[1], (mode, local, arg, results)
                    cases += 1

    uc = machines[1]
    guard = rel[0x0212c98c]
    valid = bytes.fromhex('30402de904d04de20050a0e1030c85e2')
    skip = [rel[x] for x in (0x212c9e4, 0x212c9f8, 0x212ca0c, 0x212ca34, 0x212ca48, 0x212ca5c)]
    resumed = []
    def resume(uc, address, size, _):
        if address == rel[0x2019740]:
            resumed.append(uc.reg_read(UC_ARM_REG_R0))
            uc.emu_stop()
    uc.hook_add(UC_HOOK_CODE, resume)
    bone_cases = 0
    for corrupt in range(-1, 4):
        guard_bytes = bytearray(valid)
        if corrupt >= 0:
            guard_bytes[corrupt*4] ^= 1
        uc.mem_write(guard, bytes(guard_bytes))
        for ret in skip + [rel[0x212ca70], guard, skip[0]+4]:
            resumed.clear()
            uc.mem_write(0x02200058, struct.pack('<I', 0x02210000))
            uc.reg_write(UC_ARM_REG_R0, 0x02200000)
            uc.reg_write(UC_ARM_REG_SP, 0x023fe000)
            uc.reg_write(UC_ARM_REG_LR, ret)
            uc.emu_start(0x02000d00, ret, count=1000)
            assert uc.reg_read(UC_ARM_REG_SP) == 0x023fe000
            if corrupt == -1 and ret in skip:
                assert not resumed and uc.reg_read(UC_ARM_REG_R0) == 1
            else:
                assert resumed == [0x02210040]
            bone_cases += 1
    return dict(code=p['game_code'], packet_equivalence_cases=cases,
                bone_guard_cases=bone_cases, source_unchanged=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom', nargs='+')
    args = parser.parse_args()
    print(json.dumps([run(path) for path in args.rom], indent=2))
