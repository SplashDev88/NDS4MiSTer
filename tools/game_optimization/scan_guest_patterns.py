#!/usr/bin/env python3
"""Read-only structural screening of ARM code sections; never authorizes a patch.

The first detector recognizes branch-heavy halfword-copy control flow while
allowing register renaming. Linear scans can encounter data or Thumb code;
execution traces and revision/original-byte guards are still required.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct

from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM
from capstone.arm import (ARM_CC_AL, ARM_CC_LT, ARM_INS_MOV, ARM_INS_CMP,
                          ARM_INS_B, ARM_INS_LDRH, ARM_INS_STRH, ARM_INS_ADD,
                          ARM_INS_BX, ARM_OP_REG, ARM_OP_IMM, ARM_OP_MEM,
                          ARM_REG_LR, ARM_REG_PC, ARM_REG_SP)
from ndspy.code import MainCodeFile


def halfword_copy(instructions):
    if len(instructions) != 13:
        return None
    ids = [ARM_INS_MOV, ARM_INS_CMP, ARM_INS_B, ARM_INS_B, ARM_INS_LDRH,
           ARM_INS_B, ARM_INS_B, ARM_INS_STRH, ARM_INS_B, ARM_INS_B,
           ARM_INS_ADD, ARM_INS_B, ARM_INS_BX]
    if [i.id for i in instructions] != ids:
        return None
    if any(i.cc != (ARM_CC_LT if n in (2, 5, 8, 11) else ARM_CC_AL)
           for n, i in enumerate(instructions)):
        return None
    if any(i.writeback or (i.update_flags and i.id != ARM_INS_CMP) for i in instructions):
        return None

    def reg(n, k):
        o = instructions[n].operands[k]
        assert o.type == ARM_OP_REG and not o.shift.type
        return o.reg

    def immediate(n, k):
        o = instructions[n].operands[k]
        assert o.type == ARM_OP_IMM
        return o.imm

    try:
        counter = reg(0, 0)
        assert immediate(0, 1) == 0 and reg(1, 0) == counter
        length = reg(1, 1)
        data = reg(4, 0)
        assert reg(7, 0) == data
        bases = []
        for n in (4, 7):
            o = instructions[n].operands[1]
            assert o.type == ARM_OP_MEM and not o.shift.type
            assert o.mem.index == counter and o.mem.disp == 0 and o.mem.scale == 1
            bases.append(o.mem.base)
        assert reg(10, 0) == reg(10, 1) == counter and immediate(10, 2) == 2
        assert reg(12, 0) == ARM_REG_LR
        roles = [counter, length, data] + bases
        assert len(set(roles)) == 5 and not set(roles) & {ARM_REG_PC, ARM_REG_SP, ARM_REG_LR}
        for branch, target in [(2, 4), (3, 5), (5, 7), (6, 8), (8, 10), (9, 11), (11, 1)]:
            assert immediate(branch, 0) == instructions[target].address
    except (AssertionError, IndexError):
        return None
    return dict(zip(['counter', 'length', 'data', 'source', 'destination'],
                    [instructions[0].reg_name(r) for r in roles]))


def scan(data, base):
    decoder = Cs(CS_ARCH_ARM, CS_MODE_ARM)
    decoder.detail = True
    findings = []
    for at in range((-base) % 4, len(data) - 51, 4):
        if struct.unpack_from('<I', data, at)[0] & 0xffff0fff != 0xe3a00000:
            continue
        raw = data[at:at+52]
        instructions = list(decoder.disasm(raw, base+at))
        roles = halfword_copy(instructions)
        if roles:
            findings.append(dict(pattern='branch-heavy-halfword-copy', address=hex(base+at),
                                 bytes=52, expect=raw.hex(), roles=roles,
                                 status='static_candidate_requires_execution_and_semantic_proof'))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom', type=Path)
    parser.add_argument('--arm9-profile', type=Path)
    parser.add_argument('--arm7-profile', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists')
    raw = args.rom.read_bytes()
    findings, sections = [], []
    for cpu, header_at, profile in [('arm9', 0x20, args.arm9_profile), ('arm7', 0x30, args.arm7_profile)]:
        offset, entry, base, size = struct.unpack_from('<4I', raw, header_at)
        if not size or offset + size > len(raw):
            raise ValueError('Invalid CPU image extent')
        samples = {}
        if profile:
            with profile.open() as stream:
                samples = {int(r['pc'], 16): int(r['count']) for r in csv.DictReader(stream)}
        code = MainCodeFile(raw[offset:offset+size], base)
        for index, section in enumerate(code.sections):
            data = bytes(section.data)
            target = cpu + '.bin/' + ('main_loaded' if section.implicit else 'autoload:' + str(index))
            sections.append(dict(cpu=cpu, target=target, address=hex(section.ramAddress),
                                 bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            for candidate in scan(data, section.ramAddress):
                start = int(candidate['address'], 16)
                candidate.update(cpu=cpu, mode='arm', target=target,
                                 sampled_instructions_in_extent=sum(v for pc, v in samples.items() if start <= pc < start+candidate['bytes']))
                findings.append(candidate)
    result = dict(rom_sha256=hashlib.sha256(raw).hexdigest(), sections=sections, findings=findings,
                  coverage='ARM main/autoload sections only; no overlay or Thumb detector. Samples are instruction entries, not cycles. No SDK identity inferred.',
                  original_rom_preserved=hashlib.sha256(args.rom.read_bytes()).hexdigest() == hashlib.sha256(raw).hexdigest())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(findings=findings, original_rom_preserved=result['original_rom_preserved'])))


if __name__ == '__main__':
    main()
