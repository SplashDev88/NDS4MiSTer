#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute the FFIII audio-ring wait under asynchronous consumer progress.

The movie converter can fill the audio ring before its interrupt consumer
advances. The original branch retries cached register values forever. The
replacement must reload the counters without dropping audio or adding delay.
"""
import json
from pathlib import Path
import struct
import unittest

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_MEM_READ
from unicorn.arm_const import UC_ARM_REG_R10, UC_ARM_REG_PC


ADDRESSES = {'AFFE': 0x0206E828, 'AFFP': 0x0206F2EC, 'AFFJ': 0x0206E5F8}
CATALOG = json.loads((Path(__file__).parent / 'guest_catalog.json').read_text())
# ARM fixture: load produced/consumed/capacity from the player object,
# compute free space with the game's 64-bit comparison, then retry if zero.
PREFIX = [0xE59A20C4, 0xE59A10C8, 0xE59A00CC, 0xE0422001,
          0xE3A01000, 0xE0502002, 0xE0C11001, 0xE3A00000,
          0xE1510000, 0x01520000]


def execute(branch, address, produced, consumed, drain_after=None):
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    uc.mem_map(0x02000000, 0x100000)
    obj = 0x020F0000
    start, end = address - 40, address + 4
    uc.mem_write(start, struct.pack('<10I', *PREFIX) + branch)
    uc.mem_write(obj + 0xC4, struct.pack('<III', produced, consumed, 8))
    uc.reg_write(UC_ARM_REG_R10, obj)
    counts = {'instructions': 0, 'consumer_reads': 0}

    def step(cpu, pc, size, unused):
        counts['instructions'] += 1
        if counts['instructions'] == drain_after:
            cpu.mem_write(obj + 0xC8, struct.pack('<I', (consumed + 1) & 0xFFFFFFFF))

    def read(cpu, access, at, size, value, unused):
        if at == obj + 0xC8:
            counts['consumer_reads'] += 1

    uc.hook_add(UC_HOOK_CODE, step)
    uc.hook_add(UC_HOOK_MEM_READ, read)
    uc.emu_start(start, end, count=1000)
    return uc.reg_read(UC_ARM_REG_PC) == end, counts


class AudioWaitTests(unittest.TestCase):
    def test_original_loop_cannot_observe_consumer_progress(self):
        exited, counts = execute(bytes.fromhex('fbffff0a'), ADDRESSES['AFFE'], 8, 0, 50)
        self.assertFalse(exited)
        self.assertEqual(counts['consumer_reads'], 1)

    def test_all_regional_patches_wait_for_space_and_handle_counter_wrap(self):
        for code, address in ADDRESSES.items():
            entry, = [e for e in CATALOG['entries'] if e['manifest']['game_code'] == code]
            patch, = [p for p in entry['manifest']['patches'] if p['id'] == 'movie-audio-buffer-wait']
            self.assertIn(patch['id'], entry['patch_ids'])
            self.assertEqual(int(patch['addr'], 16), address)
            self.assertEqual(patch['expect'], 'fbffff0a')
            branch = bytes.fromhex(patch['replace'])
            for produced, consumed in [(8, 0), (2, 0xFFFFFFFA)]:
                with self.subTest(region=code, produced=produced, consumed=consumed):
                    exited, counts = execute(branch, address, produced, consumed, 50)
                    self.assertTrue(exited)
                    self.assertGreaterEqual(counts['instructions'], 50)
                    self.assertGreater(counts['consumer_reads'], 1)
                    exited, counts = execute(branch, address, produced, consumed)
                    self.assertFalse(exited)
                    self.assertGreater(counts['consumer_reads'], 1)
            for occupancy in (0, 1, 7):
                with self.subTest(region=code, occupancy=occupancy):
                    exited, counts = execute(branch, address, occupancy, 0)
                    self.assertTrue(exited)
                    self.assertEqual(counts['consumer_reads'], 1)


if __name__ == '__main__':
    unittest.main()
