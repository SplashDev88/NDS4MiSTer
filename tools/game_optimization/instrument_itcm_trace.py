#!/usr/bin/env python3
"""Add the existing RAM observer to interpreter ITCM writes in a private copy.

Canonicalize aliases into 01ff8000..01ffffff. This observes ARM9 CPU stores,
including sequential word stores, after the actual store. It adds no emulated
read and changes no timing counters. JIT, debug/state loading, DSi direct host
writes and the reset-time memset are outside this observer's scope.
"""


def instrument(source):
    if 'replay_ram_write(' in source:
        raise ValueError('ITCM source is already instrumented')
    declaration = 'extern void replay_ram_write(const NDS&,unsigned,unsigned,u32,u32);\n'
    for suffix, width in [('8', 8), ('16', 16), ('32', 32), ('32S', 32)]:
        entry = f'void ARMv5::DataWrite{suffix}(u32 addr, u{width} val)\n{{'
        if source.count(entry) != 1:
            raise ValueError('Expected exactly one ITCM writer: ' + entry)
        first = source.index(entry)
        end = source.index('\n}', first) + 2
        body = source[first:end]
        store = f'        *(u{width}*)&ITCM[addr & (ITCMPhysicalSize - 1)] = val;'
        if body.count(store) != 1:
            raise ValueError('Expected exactly one ITCM store in ' + entry)
        replacement = body.replace(store, store +
            f'\n        replay_ram_write(NDS,0,{width},0x01ff8000u | (addr & (ITCMPhysicalSize - 1)),val);')
        if suffix == '8':
            replacement = declaration + replacement
        source = source[:first] + replacement + source[end:]
    return source
