#!/usr/bin/env python3
"""Emit an authored ARM test ROM package; no game or firmware assets.

Both CPUs verify counter, private/shared or video memory traffic, then exercise
keys, timers and IPC before a taken branch. An error loops at a distinct PC.
This deliberately small encoder uses only fixed ARMv4 instructions common to
both cores. It is a test fixture, not a general assembler.
"""
from pathlib import Path
import argparse


def program(cpu, active_devices=False):
    words, comments, labels, branches, literals = [], [], {}, [], []

    def emit(word, comment):
        words.append(word)
        comments.append(comment)

    def literal(reg, value):
        literals.append((len(words), reg, value))
        emit(0, f"LDR r{reg}, =0x{value:08X}")

    def branch(label, condition=0xE):
        branches.append((len(words), label, condition))
        emit(0, f"B{'NE' if condition == 1 else ''} {label}")

    def load(dst, base, offset=0):
        assert 0 <= offset < 4096
        emit(0xE5900000 | base << 16 | dst << 12 | offset, f"LDR r{dst}, [r{base}]")

    def store(src, base, byte=False, offset=0):
        assert 0 <= offset < 4096
        emit((0xE5C00000 if byte else 0xE5800000) | base << 16 | src << 12 | offset,
             f"STR{'B' if byte else ''} r{src}, [r{base}]")

    emit(0xE321F0DF, "MSR CPSR_c, #0xDF: masked IRQ/FIQ, system mode")
    literal(0, 0x02002000 if cpu == 9 else 0x02002004)
    emit(0xE3A01000, "MOV r1, #0")
    literal(3, 0x06800000 if cpu == 9 else 0x03800000)
    literal(4, 0x05000000 if cpu == 9 else 0x03000000)
    literal(5, 0x07000000 if cpu == 9 else 0x04000138)
    literal(6, 0x04000130)
    literal(7, 0x04000100)
    literal(8, 0x04000180)
    if cpu == 9:
        literal(10, 0x04000240)
        emit(0xE3A02080, "MOV r2, #0x80: bank A LCDC")
        store(2, 10, byte=True)
    literal(9, 0x0080FFF0)
    store(9, 7)  # Start timer0; no IRQ, repeats while the guest executes.
    if active_devices:
        if cpu == 7:
            def sound_write(address, value):
                literal(10, address)
                literal(9, value)
                store(9, 10)

            sound_write(0x04000500, 0x0000807F)
            for channel, control in enumerate((0x8810001F, 0xA840001F, 0xC870001F)):
                sound_write(0x04000404 + channel * 16, 0x02001400 + channel * 256)
                sound_write(0x04000408 + channel * 16, 0x0000FE00)
                sound_write(0x0400040C + channel * 16, 64)
                sound_write(0x04000400 + channel * 16, control)
        literal(10, 0x040000B0)
        literal(11, 0x02000300 if cpu == 9 else 0x02001700)
        store(11, 10)
        literal(11, 0x02003000 if cpu == 9 else 0x02003400)
        store(11, 10, offset=4)
        literal(12, 0x84000040)  # immediate, 32-bit, 64 words
    labels["loop"] = len(words)
    emit(0xE2811001, "ADD r1, r1, #1")
    for base in ([0, 3, 4, 5] if cpu == 9 else [0, 3, 4]):
        store(1, base)
        load(2, base)
        emit(0xE1520001, "CMP r2, r1")
        branch("error", condition=1)
    if active_devices:
        store(12, 10, offset=8)
        labels["dma_wait"] = len(words)
        load(2, 10, offset=8)
        emit(0xE3120102, "TST r2, #0x80000000")
        branch("dma_wait", condition=1)
        for index in (0, 63):
            load(2, 11, offset=index * 4)
            literal(9, (0x69000000 if cpu == 9 else 0x67000000) + index)
            emit(0xE1520009, "CMP r2, r9: DMA destination")
            branch("error", condition=1)
    load(2, 6)
    load(2, 7)
    if cpu == 7:
        load(2, 5)  # RTC serial-port input, no time write.
    emit(0xE1A09401, "MOV r9, r1, LSL #8: IPCSYNC output nibble")
    store(9, 8)
    load(2, 8)
    branch("loop")
    labels["error"] = len(words)
    branch("error")
    for at, reg, value in literals:
        offset = 4 * (len(words) - at - 2)
        assert 0 <= offset < 4096
        words[at] = 0xE59F0000 | reg << 12 | offset
        emit(value, "literal")
    for at, label, condition in branches:
        offset = labels[label] - at - 2
        assert -(1 << 23) <= offset < (1 << 23)
        words[at] = condition << 28 | 0xA000000 | offset & 0xFFFFFF
    if active_devices:
        data_offset = 0x300 if cpu == 9 else 0x400
        assert len(words) * 4 <= data_offset
        while len(words) * 4 < data_offset:
            emit(0, "padding before immutable source data")
        if cpu == 7:
            for channel in range(3):
                for index in range(64):
                    if channel == 2 and index == 0:
                        value = 0x001403E8  # ADPCM predictor 1000, index 20
                    else:
                        value = sum(((index * 4 + b) * 13 + channel * 17) % 256 << (b * 8) for b in range(4))
                    emit(value, f"authored channel {channel} sample data")
        for index in range(64):
            emit((0x69000000 if cpu == 9 else 0x67000000) + index, "authored DMA source")
    return words, comments, labels


def generate(active_devices=False):
    programs = {cpu: program(cpu, active_devices) for cpu in (9, 7)}
    out = ["-- Generated by console_fixture.py from authored programs.",
           "library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;",
           "package checkpoint_fixture_rom is",
           f" constant ACTIVE_DEVICES : boolean := {str(active_devices).lower()};"]
    for cpu, base in ((9, 0x02000000), (7, 0x02001000)):
        out.append(f' constant LOOP_PC_{cpu} : std_logic_vector(31 downto 0) := x"{base + programs[cpu][2]["loop"] * 4:08X}";')
        dma_pc = base + programs[cpu][2].get("dma_wait", programs[cpu][2]["loop"]) * 4
        out.append(f' constant DMA_WAIT_PC_{cpu} : std_logic_vector(31 downto 0) := x"{dma_pc:08X}";')
    out += [" function rom_word(a : natural) return std_logic_vector;", "end package;",
            "package body checkpoint_fixture_rom is", " function rom_word(a : natural) return std_logic_vector is", " begin case a is"]
    image = {0x0C: 0x54534554, 0x20: 0x200, 0x24: 0x02000000, 0x28: 0x02000000,
             0x2C: len(programs[9][0]) * 4, 0x30: 0x1000, 0x34: 0x02001000,
             0x38: 0x02001000, 0x3C: len(programs[7][0]) * 4, 0x80: 0x2000}
    for address, value in sorted(image.items()):
        out.append(f'  when {address // 4} => return x"{value:08X}"; -- header +{address:02X}')
    for cpu, base in ((9, 0x200), (7, 0x1000)):
        words, comments, _ = programs[cpu]
        assert len(words) * 4 <= (0x400 if cpu == 9 else 0x800)
        for i, (word, comment) in enumerate(zip(words, comments)):
            out.append(f'  when {base // 4 + i} => return x"{word:08X}"; -- ARM{cpu} {comment}')
    out += ['  when others => return x"00000000";', ' end case; end;', 'end package body;']
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--active-devices", action="store_true")
    args = parser.parse_args()
    args.output.write_text(generate(args.active_devices))
