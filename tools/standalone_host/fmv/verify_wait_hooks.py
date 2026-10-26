#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise generated movie-buffer wait hooks on an ARM interpreter."""
from pathlib import Path
import json
import struct
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_R5, UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC

root = Path(__file__).parent
results = []
for name, resume, japanese in [
        ('ff12_wait_before_header', 0x02086140, False),
        ('ff12_eu_wait_before_header', 0x02086640, False),
        ('ff12_jp_wait_before_header', 0x02086738, True),
        ('portrait_us_wait_before_header', 0x02089914, True),
        ('portrait_eu_wait_before_header', 0x0208a68c, True),
        ('portrait_jp_wait_before_header', 0x0208999c, True),
        ('portrait_jp1_wait_before_header', 0x02082a38, False)]:
    calls = []
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    uc.mem_map(0x01ff0000, 0x10000)
    uc.mem_map(0x02000000, 0x400000)
    uc.mem_write(0x01fffcc0, (root/'guest'/(name+'.bin')).read_bytes())
    obj, reader, vtable, callback = 0x02200000, 0x02210000, 0x02220000, 0x02300000
    for at, value in [(obj, reader), (obj+0xf0, 1), (reader, vtable), (vtable+0x14, callback)]:
        uc.mem_write(at, struct.pack('<I', value))
    def wait(uc, address, size, _):
        if address == callback:
            calls.append(uc.reg_read(UC_ARM_REG_R0))
            # A completed read publishes new state. The JP displaced load
            # must observe it after this callback, rather than before it.
            uc.mem_write(obj+0xf0, struct.pack('<I', 0))
            for reg in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_R12):
                uc.reg_write(reg, 0xdeadbeef)
            uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
    uc.hook_add(UC_HOOK_CODE, wait)
    registers = {UC_ARM_REG_R0:1, UC_ARM_REG_R1:2, UC_ARM_REG_R2:3, UC_ARM_REG_R3:4,
                 UC_ARM_REG_R12:12, UC_ARM_REG_R5:obj, UC_ARM_REG_SP:0x023fe000, UC_ARM_REG_LR:0x023ff000}
    for reg, value in registers.items():
        uc.reg_write(reg, value)
    uc.emu_start(0x01fffcc0, resume, count=1000)
    assert calls == [reader] and uc.reg_read(UC_ARM_REG_PC) == resume
    expected = dict(registers)
    if japanese:
        expected[UC_ARM_REG_R0] = 0
    else:
        expected[UC_ARM_REG_R2] = obj+4
    for reg, value in expected.items():
        assert uc.reg_read(reg) == value, (name, reg, hex(uc.reg_read(reg)), hex(value))
    results.append(dict(hook=name, callback_once=True, registers_and_stack_preserved=True,
                        displaced_instruction_after_wait=True))
print(json.dumps(results, indent=2))
