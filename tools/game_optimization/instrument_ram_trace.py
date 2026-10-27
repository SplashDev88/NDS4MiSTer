#!/usr/bin/env python3
"""Observe the six NDS main-RAM bus stores in a private source copy.

The existing interpreter and DMA use these bus writers. DSi, JIT fast memory,
state loading and direct host memory changes are outside this observer's scope.
The callback receives the already-written value; it performs no emulated read.
"""


def instrument(source):
    if 'replay_ram_write(' in source:
        raise ValueError('RAM source is already instrumented')
    declaration = 'extern void replay_ram_write(const NDS&,unsigned,unsigned,u32,u32);\n'
    for cpu, number in [('ARM9', 0), ('ARM7', 1)]:
        for width in [8, 16, 32]:
            entry = f'void NDS::{cpu}Write{width}(u32 addr, u{width} val)\n{{'
            if source.count(entry) != 1:
                raise ValueError('Expected exactly one RAM writer: ' + entry)
            first = source.index(entry)
            end = source.index('\n}', first) + 2
            body = source[first:end]
            store = f'        *(u{width}*)&MainRAM[addr & MainRAMMask] = val;'
            if body.count(store) != 1:
                raise ValueError('Expected exactly one main-RAM store in ' + entry)
            replacement = body.replace(store, store +
                f'\n        replay_ram_write(*this,{number},{width},0x02000000u | (addr & MainRAMMask),val);')
            if number == 0 and width == 8:
                replacement = declaration + replacement
            source = source[:first] + replacement + source[end:]
    return source
