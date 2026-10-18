#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Authored ARM7 register/bank traffic; no commercial software or BIOS required."""
import argparse
from pathlib import Path
from arm7_monitor_rom import CP15_FIELDS, cp15_instruction


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mode', type=lambda x: int(x, 0), default=0x1F)
    p.add_argument('--arm9', action='store_true')
    p.add_argument('--thumb', action='store_true')
    p.add_argument('--no-branch', action='store_true')
    args = p.parse_args()
    words, literals = [], []
    base = 0x02000000

    def emit(word):
        words.append(word)

    def literal(reg, value):
        literals.append((len(words), reg, value))
        emit(0)

    for mode in [0x1F, 0x11, 0x12, 0x13, 0x17, 0x1B]:
        emit(0xE321F0C0 | mode)
        for reg in range(8 if mode in [0x1F, 0x11] else 13, 15):
            literal(reg, 0x51000000 + mode * 0x10000 + reg * 257)
        if mode != 0x1F:
            literal(2, 0xA000009F + ((mode & 3) << 28))
            emit(0xE16FF002)  # msr spsr_fsxc, r2
    if args.arm9:
        # Deliberately non-default, guest-written values. Control retains its
        # mandatory fixed bits; extended permissions exercise every nibble.
        values = [0x000FF0FD, 0x0F00000A, 0x00000020] + \
                 [0x02000017 + n * 0x01000002 for n in range(8)] + \
                 [0x0055AA5A, 0x0033CC69, 0x00F00F96, 0x76543210,
                  0xFEDCBA98, 0x00112233, 0x00445566, 0x00778899]
        for field, value in zip(CP15_FIELDS, values):
            literal(2, value)
            emit(cp15_instruction(False, 2, field))
    emit(0xE321F0C0 | args.mode)
    literal(0, 0x04000000)
    emit(0xE3A01000)
    for reg in range(2, 15):
        literal(reg, 0x67000000 + reg * 0x10001)
    literal(2, 0xA8000000 if args.arm9 else 0xA0000000)
    emit(0xE128F002)  # msr cpsr_f, r2
    if args.no_branch:
        for _ in range(320 if args.arm9 else 160):
            emit(0xE2811001)
            emit(0xE8807FFE)
        emit(0xEAFFFFFE)  # Beyond the observed straight-line interval.
    elif args.thumb:
        # Only low registers are modified in the Thumb loop. The first BX and
        # subsequent Thumb branches exercise both kinds of redirect entry.
        literal(4, base + (len(words) + 2) * 4 + 1)
        emit(0xE12FFF14)
        emit(0x60013101)  # adds r1,#1; str r1,[r0]
        emit(0x60836042)  # str r2,[r0,#4]; str r3,[r0,#8]
        emit(0x46C0E7FA)  # b start; nop
    else:
        loop = len(words)
        emit(0xE2811001)  # add (not adds) r1,r1,#1
        emit(0xE8807FFE)  # stmia r0,{r1-r14}
        emit(0xE10F2000)  # mrs r2,cpsr
        emit(0xE5802038)
        if args.mode != 0x10:
            for mode in [0x1F, 0x11, 0x12, 0x13, 0x17, 0x1B]:
                emit(0xE321F0C0 | mode)
                emit(0xE8807F00 if mode in [0x1F, 0x11] else 0xE8806000)
                if mode != 0x1F:
                    emit(0xE14F2000)  # mrs r2,spsr
                    emit(0xE580203C)
            if args.arm9:
                for field in CP15_FIELDS:
                    emit(cp15_instruction(True, 2, field))
                    emit(0xE5802038)  # Observable ordinary guest store.
            emit(0xE321F0C0 | args.mode)
        offset = loop - len(words) - 2
        emit(0xEB000000 | (offset & 0xFFFFFF))  # BL also tests retiring LR
    for index, reg, value in literals:
        offset = (len(words) - index - 2) * 4
        assert 0 <= offset < 4096
        words[index] = 0xE59F0000 | reg << 12 | offset
        emit(value)
    Path('guest.hex').write_text(''.join(f'{word:08X}\n' for word in words))


if __name__ == '__main__':
    main()
