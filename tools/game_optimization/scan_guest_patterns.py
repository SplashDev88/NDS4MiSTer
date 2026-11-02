#!/usr/bin/env python3
"""Read-only structural screening of ARM code sections; never authorizes a patch.

Detectors recognize copy control flow, redundant shifts, weighted nibble sums,
linear key/handler dispatch, fixed-width mask walks and carry-derived zero
multiplies, allowing register renaming. Opt-in Thumb detectors screen a
stack-local header read and an exact empty-tail compaction variant. Explicit
ARM9 overlay IDs reuse the existing guarded file reader. Linear scans can encounter data;
execution traces and revision/original-byte guards are still required.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct
import sys

from capstone import (Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB, CS_GRP_JUMP, CS_GRP_CALL,
                      CS_GRP_RET, CS_GRP_INT, CS_GRP_IRET)
from capstone.arm import (ARM_CC_AL, ARM_CC_LT, ARM_CC_NE, ARM_CC_EQ, ARM_INS_MOV, ARM_INS_CMP, ARM_INS_TST,
                          ARM_INS_B, ARM_INS_LDR, ARM_INS_LDRH, ARM_INS_STRH, ARM_INS_ADD,
                          ARM_INS_BL, ARM_INS_BLX, ARM_INS_ADC, ARM_INS_MLA, ARM_INS_SUB,
                          ARM_INS_BX, ARM_OP_REG, ARM_OP_IMM, ARM_OP_MEM,
                          ARM_REG_R0, ARM_REG_R1, ARM_REG_R2,
                          ARM_REG_LR, ARM_REG_PC, ARM_REG_SP, ARM_INS_LSL,
                          ARM_INS_LSR, ARM_INS_ASR, ARM_SFT_LSL, ARM_SFT_LSR,
                          ARM_SFT_ASR)
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


def fixed_destination_word_stream(instructions):
    """Screen the existing branch-heavy stream pattern, not ordinary memcpy."""
    if len(instructions) != 10 or any(i.size != 4 for i in instructions):
        return None
    words = [int.from_bytes(i.bytes, 'little') for i in instructions]
    first = words[0]
    if first & 0xfff00ff0 != 0xe0800000:
        return None  # Unshifted ADD end, source, length; no flag update.
    source, end, length = (first >> 16) & 15, (first >> 12) & 15, first & 15
    store = words[7]
    destination, data = (store >> 16) & 15, (store >> 12) & 15
    if len({source, end, destination}) != 3:
        return None
    if {source, end, destination} & {length, data} or max(source, end, length, destination, data) >= 13:
        return None
    expected = [first, 0xe1500000 | source << 16 | end,
                0xba000000, 0xea000000, 0xe8b00000 | source << 16 | 1 << data,
                0xba000000, 0xea000000, 0xe5800000 | destination << 16 | data << 12,
                0xbafffff7, 0xe12fff1e]
    if words != expected:
        return None
    return dict(source=f'r{source}', end=f'r{end}', length=f'r{length}',
                destination=f'r{destination}', data=f'r{data}',
                required_proof='Authenticate loaded code and all entry paths; capture actual arguments and ordered accesses. Fixed destination may be MMIO. Preserve zero-length behavior, flags, IRQ/DMA effects and output timing; measure native benefit.')


def shift_chain(instructions):
    if len(instructions) != 5:
        return None
    expected = [(ARM_INS_LSL, ARM_SFT_LSL, 8), (ARM_INS_ASR, ARM_SFT_ASR, 16),
                (ARM_INS_LSL, ARM_SFT_LSL, 16), (ARM_INS_LSR, ARM_SFT_LSR, 16),
                (ARM_INS_LSL, ARM_SFT_LSL, 16)]
    destination, source = None, None
    for n, (i, (opcode, shift, amount)) in enumerate(zip(instructions, expected)):
        if i.id != opcode or i.cc != ARM_CC_AL or i.update_flags or i.writeback or len(i.operands) != 2:
            return None
        dst, src = i.operands
        if dst.type != ARM_OP_REG or src.type != ARM_OP_REG or dst.shift.type:
            return None
        if src.shift.type != shift or src.shift.value != amount:
            return None
        if n == 0:
            destination, source = dst.reg, src.reg
            if {destination, source} & {ARM_REG_PC, ARM_REG_SP}:
                return None
        elif dst.reg != destination or src.reg != destination:
            return None
    return dict(destination=instructions[0].reg_name(destination), source=instructions[0].reg_name(source))


def nibble_step(instructions):
    """Screen weighted step sums; scaling/overflow invariants need separate proof."""
    if len(instructions) != 7 or instructions[0].id != ARM_INS_ASR:
        return None
    first = instructions[0]
    if first.cc != ARM_CC_AL or first.update_flags or first.writeback or len(first.operands) != 2:
        return None
    dst, src = first.operands
    if dst.type != ARM_OP_REG or src.type != ARM_OP_REG or dst.shift.type or src.shift.type != ARM_SFT_ASR or src.shift.value != 3:
        return None
    accumulator, step, nibble = dst.reg, src.reg, None
    for n, bit in enumerate([4, 2, 1]):
        test, add = instructions[1+2*n:3+2*n]
        if test.id != ARM_INS_TST or test.cc != ARM_CC_AL or not test.update_flags or test.writeback or len(test.operands) != 2:
            return None
        if int.from_bytes(test.bytes, 'little') & 0xf00:
            return None  # Rotated immediates can change carry even with the same printed value.
        reg, immediate = test.operands
        if reg.type != ARM_OP_REG or reg.shift.type or immediate.type != ARM_OP_IMM or immediate.imm != bit:
            return None
        if nibble is None:
            nibble = reg.reg
        elif nibble != reg.reg:
            return None
        if add.id != ARM_INS_ADD or add.cc != ARM_CC_NE or add.update_flags or add.writeback or len(add.operands) != 3:
            return None
        d, a, s = add.operands
        if any(o.type != ARM_OP_REG for o in [d, a, s]) or d.shift.type or a.shift.type or d.reg != accumulator or a.reg != accumulator or s.reg != step:
            return None
        if (n == 0 and s.shift.type) or (n > 0 and (s.shift.type != ARM_SFT_ASR or s.shift.value != n)):
            return None
    if len({accumulator, step, nibble}) != 3 or {accumulator, step, nibble} & {ARM_REG_SP, ARM_REG_PC}:
        return None
    return dict(accumulator=first.reg_name(accumulator), step=first.reg_name(step), nibble=first.reg_name(nibble),
                required_proof='Positive step divisible by8;15*step fits signed32; entry index valid; exact tables/runtime writes guarded; changed N/Z flags overwritten before use. No middleware identity or safe replacement inferred.')


def key_handler_dispatch(instructions):
    """Find an ordered key/function search, without assuming immutable tables."""
    ids = [ARM_INS_LDR, ARM_INS_CMP, ARM_INS_B, ARM_INS_LDR, ARM_INS_BLX,
           ARM_INS_MOV, ARM_INS_B, ARM_INS_ADD, ARM_INS_ADD, ARM_INS_CMP, ARM_INS_B]
    if len(instructions) != len(ids) or [i.id for i in instructions] != ids:
        return None
    if any(i.cc != (ARM_CC_NE if n == 2 else ARM_CC_LT if n == 10 else ARM_CC_AL)
           or i.writeback or i.update_flags != (n in [1, 9])
           for n, i in enumerate(instructions)):
        return None

    def reg(n, k):
        o = instructions[n].operands[k]
        assert o.type == ARM_OP_REG and not o.shift.type
        assert o.reg not in [ARM_REG_SP, ARM_REG_PC]
        return o.reg

    def imm(n, k):
        o = instructions[n].operands[k]
        assert o.type == ARM_OP_IMM
        return o.imm

    try:
        key = reg(0, 0)
        memory = instructions[0].operands[1]
        assert memory.type == ARM_OP_MEM and not memory.shift.type
        base = memory.mem.base
        assert base not in [ARM_REG_SP, ARM_REG_PC]
        assert not memory.mem.index and memory.mem.disp == 0
        assert reg(1, 0) == key
        sought = reg(1, 1)
        assert imm(2, 0) == instructions[7].address
        assert reg(3, 0) == base and reg(4, 0) == base
        handler = instructions[3].operands[1]
        assert handler.type == ARM_OP_MEM and not handler.shift.type
        assert handler.mem.base == base and not handler.mem.index and handler.mem.disp == 4
        reg(5, 0); reg(5, 1)
        assert imm(6, 0) == instructions[-1].address + 4
        counter = reg(7, 0)
        assert reg(7, 1) == counter and imm(7, 2) == 1
        assert reg(8, 0) == reg(8, 1) == base and imm(8, 2) == 8
        assert reg(9, 0) == counter
        length = reg(9, 1)
        assert imm(10, 0) == instructions[0].address
        assert len({key, sought, base, counter, length}) == 5
    except (AssertionError, IndexError):
        return None
    return dict(table=instructions[0].reg_name(base), key=instructions[0].reg_name(sought),
                counter=instructions[0].reg_name(counter), count=instructions[0].reg_name(length),
                entry_bytes=8, key_offset=0, handler_offset=4,
                required_proof='Observe callers, lookup keys, table identity and every table write. Preserve first-match order, misses, handler calls, registers/flags and timing. No sortedness, immutability, redundancy or SDK identity inferred.')


def fixed_width_mask_walk(instructions):
    """Screen a low-bit test with an invariant mask/index body and bounded tail.

    This finds work to profile, not a safe replacement or a known SDK routine.
    The body can have forward conditional branches but cannot escape, call,
    change either loop operand or transfer control indirectly.
    """
    if not 7 <= len(instructions) <= 64:
        return None
    test, skip = instructions[:2]
    add, compare, shift, back = instructions[-4:]
    if [i.id for i in [test, skip, add, compare, shift, back]] != [
            ARM_INS_TST, ARM_INS_B, ARM_INS_ADD, ARM_INS_CMP, ARM_INS_LSR, ARM_INS_B]:
        return None
    if any(i.address != test.address + 4*n or i.size != 4 for n, i in enumerate(instructions)):
        return None
    selected = [test, skip, add, compare, shift, back]
    if any(i.cc != cc or i.writeback or i.update_flags != flags
           for i, cc, flags in zip(selected,
               [ARM_CC_AL, ARM_CC_EQ, ARM_CC_AL, ARM_CC_AL, ARM_CC_AL, ARM_CC_LT],
               [True, False, False, True, False, False])):
        return None

    def reg(i, k):
        operand = i.operands[k]
        assert operand.type == ARM_OP_REG and not operand.shift.type
        assert operand.reg not in [ARM_REG_SP, ARM_REG_PC]
        return operand.reg

    def imm(i, k):
        operand = i.operands[k]
        assert operand.type == ARM_OP_IMM
        return operand.imm

    try:
        mask = reg(test, 0)
        assert imm(test, 1) == 1 and not (int.from_bytes(test.bytes, 'little') & 0xf00)
        assert imm(skip, 0) == add.address
        index = reg(add, 0)
        assert index != mask and reg(add, 1) == index and imm(add, 2) == 1
        assert reg(compare, 0) == index and 1 <= imm(compare, 1) <= 32
        assert reg(shift, 0) == mask
        source = shift.operands[1]
        assert source.type == ARM_OP_REG and source.reg == mask
        assert source.shift.type == ARM_SFT_LSR and source.shift.value == 1
        assert imm(back, 0) == test.address
        addresses = {i.address for i in instructions[2:-3]}
        for instruction in instructions[2:-4]:
            if instruction.id == ARM_INS_B:
                target = imm(instruction, 0)
                assert target in addresses and target > instruction.address
            else:
                assert not set(instruction.groups) & {
                    CS_GRP_JUMP, CS_GRP_CALL, CS_GRP_RET, CS_GRP_INT, CS_GRP_IRET}
                _, written = instruction.regs_access()
                assert not set(written) & {mask, index, ARM_REG_PC}
    except (AssertionError, IndexError):
        return None
    return dict(mask=test.reg_name(mask), index=test.reg_name(index), width=imm(compare, 1),
                required_proof='Observe mask histogram and caller contract before choosing an empty-tail or set-bit walk. Preserve high-bit return, zero mask, selected writes and order, stack/registers/flags, literal identity and CPU instruction support. No sparsity, SDK identity, dead work or safe patch inferred.')


def zero_multiplicand(instructions):
    """Find an accumulate that is an identity when an unchanged carry is clear.

    This narrow shape materializes C as 0/1 with ADC from a known zero.
    Predicating the final MLA on CS then preserves its synchronous state.
    Entry paths, exact bytes, CPU legality and asynchronous behavior still
    require separate proof; this detector never applies a replacement.
    """
    ids = [ARM_INS_MOV, ARM_INS_MLA, ARM_INS_ADC, ARM_INS_SUB, ARM_INS_MLA]
    if len(instructions) != len(ids) or [i.id for i in instructions] != ids:
        return None
    # Read S from the encoding: Capstone can mark ADC's carry read as a
    # flag update even for ADC (S=0). All five selected opcodes use bit 20.
    if any(i.cc != ARM_CC_AL or int.from_bytes(i.bytes, 'little') & 0x100000
           or i.writeback or i.size != 4
           or i.address != instructions[0].address + 4*n
           for n, i in enumerate(instructions)):
        return None
    if [len(i.operands) for i in instructions] != [2, 4, 3, 3, 4]:
        return None

    def reg(n, k):
        operand = instructions[n].operands[k]
        assert operand.type == ARM_OP_REG and not operand.shift.type
        assert operand.reg not in [ARM_REG_SP, ARM_REG_PC]
        return operand.reg

    def imm(n, k):
        operand = instructions[n].operands[k]
        assert operand.type == ARM_OP_IMM
        return operand.imm

    try:
        zero = reg(0, 0)
        assert imm(0, 1) == 0
        first = [reg(1, k) for k in range(4)]
        assert first[0] != zero and first[0] != first[1]
        carry = reg(2, 0)
        assert reg(2, 1) == zero and imm(2, 2) == 0
        assert reg(3, 0) != carry
        reg(3, 1); imm(3, 2)
        last = [reg(4, k) for k in range(4)]
        assert last[0] == last[3] and last[0] != last[1]
        assert carry in last[1:3]
    except (AssertionError, IndexError):
        return None
    return dict(zero=instructions[0].reg_name(zero),
                carry=instructions[0].reg_name(carry),
                accumulator=instructions[0].reg_name(last[0]),
                candidate_address=hex(instructions[-1].address), condition='cs',
                required_proof='Authenticate the full sequence and entry paths; C and the carry-derived multiplicand must remain paired. Preserve registers/flags, interrupt behavior and full-game outputs. Failed predicates still fetch instructions; measure multiply latency rather than claiming fewer instruction entries. No SDK identity or native gain inferred.')


def scan(data, base):
    decoder = Cs(CS_ARCH_ARM, CS_MODE_ARM)
    decoder.detail = True
    findings = []
    detectors = [('branch-heavy-halfword-copy', 52, 0xffff0fff, 0xe3a00000, halfword_copy),
                 ('branch-heavy-fixed-destination-word-stream', 40, 0xfff00ff0, 0xe0800000, fixed_destination_word_stream),
                 ('redundant-bitfield-shift-chain', 20, 0xffff0ff0, 0xe1a00400, shift_chain),
                 ('scaled-nibble-decoder-arithmetic', 28, 0xffff0ff0, 0xe1a001c0, nibble_step),
                 ('linear-key-handler-dispatch', 44, 0xfff00fff, 0xe5900000, key_handler_dispatch),
                 ('zero-multiplicand-predication', 20, 0xffff0fff, 0xe3a00000, zero_multiplicand)]
    for at in range((-base) % 4, len(data) - 19, 4):
        word = struct.unpack_from('<I', data, at)[0]
        for pattern, size, mask, value, detect in detectors:
            if at+size > len(data) or word & mask != value:
                continue
            raw = data[at:at+size]
            roles = detect(list(decoder.disasm(raw, base+at)))
            if roles:
                findings.append(dict(pattern=pattern, address=hex(base+at),
                                     bytes=size, expect=raw.hex(), roles=roles,
                                     status='static_candidate_requires_execution_and_semantic_proof'))
        # A forward BEQ following TST mask,#1 identifies the start of the tail.
        # Bound its extent before decoding; never scan arbitrary branch targets.
        if word & 0xfff0ffff == 0xe3100001 and at+8 <= len(data):
            branch = struct.unpack_from('<I', data, at+4)[0]
            displacement = branch & 0xffffff
            if displacement & 0x800000:
                displacement -= 0x1000000
            size = 12 + displacement*4 + 16
            if branch >> 24 == 0x0a and 28 <= size <= 256 and at+size <= len(data):
                raw = data[at:at+size]
                roles = fixed_width_mask_walk(list(decoder.disasm(raw, base+at)))
                if roles:
                    findings.append(dict(pattern='fixed-width-sparse-bitmask-traversal',
                        address=hex(base+at), bytes=size, expect=raw.hex(), roles=roles,
                        status='static_candidate_requires_execution_and_semantic_proof'))
    return findings


def thumb_file_header_read(instructions):
    """Screen seek(file,12,SET); read(file,&local,2), without naming callees.

    This is a narrow ABI shape, not proof of a filesystem or archive format.
    The two call targets are recovered for independent authentication.
    """
    if len(instructions) != 8:
        return None
    expected = [ARM_INS_ADD, ARM_INS_MOV, ARM_INS_MOV, None,
                ARM_INS_ADD, ARM_INS_ADD, ARM_INS_MOV, None]
    at = instructions[0].address
    for n, instruction in enumerate(instructions):
        size = 4 if n in (3, 7) else 2
        if instruction.address != at or instruction.size != size or instruction.cc != ARM_CC_AL or instruction.writeback:
            return None
        if expected[n] is None:
            if instruction.id not in (ARM_INS_BL, ARM_INS_BLX):
                return None
        elif instruction.id != expected[n]:
            return None
        at += size

    def reg(n, k, expected):
        operand = instructions[n].operands[k]
        assert operand.type == ARM_OP_REG and not operand.shift.type and operand.reg == expected

    def imm(n, k):
        operand = instructions[n].operands[k]
        assert operand.type == ARM_OP_IMM and not operand.shift.type
        return operand.imm

    try:
        for n in (0, 4, 5):
            assert len(instructions[n].operands) == 3
            reg(n, 0, ARM_REG_R1 if n == 5 else ARM_REG_R0)
            reg(n, 1, ARM_REG_SP)
        file_offset = imm(0, 2)
        value_offset = imm(5, 2)
        assert imm(4, 2) == file_offset and file_offset != value_offset
        for n, register, value in [(1, ARM_REG_R1, 12), (2, ARM_REG_R2, 0), (6, ARM_REG_R2, 2)]:
            assert len(instructions[n].operands) == 2
            reg(n, 0, register)
            assert imm(n, 1) == value
        assert all(len(instructions[n].operands) == 1 for n in (3, 7))
        seek, read = imm(3, 0), imm(7, 0)
        assert seek != read
    except (AssertionError, IndexError):
        return None
    return dict(file_stack_offset=file_offset, value_stack_offset=value_offset,
                seek_position=12, read_bytes=2, seek_target=hex(seek), read_target=hex(read),
                required_proof='Authenticate both callees, callers and stack arguments; prove immutable header values across the guarded full ROM, payload/position behavior and completion effects. No NARC/SDK identity, constant value or safe replacement inferred.')


def scan_thumb_file_metadata(data, base):
    decoder = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    decoder.detail = True
    findings = []
    for at in range(0, len(data)-19, 2):
        # Sixteen-bit SP-relative ADD and immediate ABI arguments; calls may
        # be BL or BLX. Decode the complete window before accepting a shape.
        words = struct.unpack_from('<10H', data, at)
        if words[0] & 0xff00 != 0xa800 or words[1:3] != (0x210c, 0x2200) or words[7] != 0x2202:
            continue
        raw = data[at:at+20]
        roles = thumb_file_header_read(list(decoder.disasm(raw, base+at)))
        if roles:
            findings.append(dict(pattern='stack-file-header-halfword-read', address=hex(base+at),
                                 bytes=20, expect=raw.hex(), roles=roles,
                                 status='static_candidate_requires_execution_and_semantic_proof'))
    return findings


THUMB_EMPTY_TAIL_SIGNATURE = bytes.fromhex(
    '0026a05fe768411e002922dd3d1ce968002917d1721c824214da11017b18'
    'd96800290bd010013b189c462a1c03cb03c203cb03c200216046c16003e0'
    '521c10338242ecdb0020205e761c1035411e8e42dddb0020a080f8bd0000')


def scan_thumb_empty_tail(data, base):
    """An exact shared-code variant, not a general safe-patching signature.

    Branch displacements, signed capacity reload, record-copy order and return
    are all part of the match. Relocation is allowed; register renaming or any
    opcode change requires another independently qualified variant.
    """
    findings = []
    at = data.find(THUMB_EMPTY_TAIL_SIGNATURE)
    while at >= 0:
        if (base+at) % 2 == 0:
            findings.append(dict(pattern='repeated-empty-tail-compaction', address=hex(base+at),
                bytes=len(THUMB_EMPTY_TAIL_SIGNATURE), expect=THUMB_EMPTY_TAIL_SIGNATURE.hex(),
                roles=dict(header='r4', records='r7', record_bytes=16, active_flag_offset=12,
                           capacity_signed_bits=16,
                           required_proof='Authenticate executed overlay/code, complete record bytes and capacity; prove writer/IRQ/DMA contract, preserve stale payloads, signed count, registers/flags and final reset. Measure native benefit.'),
                status='static_candidate_requires_execution_and_semantic_proof'))
        at = data.find(THUMB_EMPTY_TAIL_SIGNATURE, at+1)
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom', type=Path)
    parser.add_argument('--arm9-profile', type=Path)
    parser.add_argument('--arm7-profile', type=Path)
    parser.add_argument('--include-thumb', action='store_true',
                        help='Also screen Thumb header-read shapes and the exact empty-tail compaction variant')
    parser.add_argument('--arm9-overlay', type=lambda value: int(value, 0), action='append', default=[],
                        help='Also scan this ARM9 overlay ID through the existing guarded file reader; repeatable')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists')
    raw = args.rom.read_bytes()
    findings, sections = [], []
    samples_by_cpu = {}

    def inspect(data, base, cpu, target, samples, **identity):
        sections.append(dict(cpu=cpu, target=target, address=hex(base), bytes=len(data),
                             sha256=hashlib.sha256(data).hexdigest(), **identity))
        candidates = [('arm', c) for c in scan(data, base)]
        if args.include_thumb:
            candidates += [('thumb', c) for c in
                           scan_thumb_file_metadata(data, base) + scan_thumb_empty_tail(data, base)]
        for mode, candidate in candidates:
            start = int(candidate['address'], 16)
            candidate.update(cpu=cpu, mode=mode, target=target, **identity,
                             sampled_instructions_in_extent=sum(v for pc, v in samples.items()
                                 if start <= pc < start+candidate['bytes']))
            if 'overlay' in identity:
                candidate['sample_attribution_requires_runtime_overlay_identity'] = True
            findings.append(candidate)

    for cpu, header_at, profile in [('arm9', 0x20, args.arm9_profile), ('arm7', 0x30, args.arm7_profile)]:
        offset, entry, base, size = struct.unpack_from('<4I', raw, header_at)
        if not size or offset + size > len(raw):
            raise ValueError('Invalid CPU image extent')
        samples = {}
        if profile:
            with profile.open() as stream:
                samples = {int(r['pc'], 16): int(r['count']) for r in csv.DictReader(stream)}
        samples_by_cpu[cpu] = samples
        code = MainCodeFile(raw[offset:offset+size], base)
        for index, section in enumerate(code.sections):
            data = bytes(section.data)
            target = cpu + '.bin/' + ('main_loaded' if section.implicit else 'autoload:' + str(index))
            inspect(data, section.ramAddress, cpu, target, samples)
    if args.arm9_overlay:
        assert len(args.arm9_overlay) == len(set(args.arm9_overlay)) and min(args.arm9_overlay) >= 0
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'standalone_host/fmv'))
        from prepare import Source, read_overlay
        with args.rom.open('rb') as stream:
            source = Source(stream.fileno())
            assert source.sha256() == hashlib.sha256(raw).hexdigest()
            table, size = struct.unpack_from('<II', raw, 0x50)
            for overlay in args.arm9_overlay:
                assert size % 32 == 0 and 512 <= table <= table+size <= source.size
                assert (overlay+1)*32 <= size
                base, = struct.unpack('<I', source.read(table+overlay*32+4, 4))
                loaded = read_overlay(source, raw[:512], overlay, base)
                inspect(bytes(loaded['decoded']), base, 'arm9', 'arm9.overlay', samples_by_cpu['arm9'],
                        overlay=overlay, overlay_file_id=loaded['info'][6],
                        overlay_ram=hex(base), overlay_sha256=hashlib.sha256(loaded['decoded']).hexdigest(),
                        overlay_stored_sha256=hashlib.sha256(loaded['stored']).hexdigest())
            source.unchanged()
    result = dict(rom_sha256=hashlib.sha256(raw).hexdigest(), sections=sections, findings=findings,
                  coverage=('ARM main/autoload sections; ' +
                            ('narrow Thumb header-read and exact compaction detectors enabled. ' if args.include_thumb else 'no Thumb detector. ') +
                            ('Explicit ARM9 overlay IDs scanned; flat PC samples require runtime overlay identity. ' if args.arm9_overlay else 'No overlays. ') +
                            'PC sample counts are not cycles. No SDK identity inferred.'),
                  original_rom_preserved=hashlib.sha256(args.rom.read_bytes()).hexdigest() == hashlib.sha256(raw).hexdigest())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(findings=findings, original_rom_preserved=result['original_rom_preserved'])))


if __name__ == '__main__':
    main()
