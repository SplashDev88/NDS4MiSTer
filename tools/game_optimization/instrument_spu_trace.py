#!/usr/bin/env python3
"""Instrument a private SPU source copy for the existing replay oracle.

This observes writes and mix boundaries, without changing emulated registers,
time or audio. The source must contain each exact entry point once.
"""


def instrument(source):
    declaration = """extern void replay_spu_write(unsigned,u32,u32,u64);
extern void replay_spu_mix();
"""
    for width, value_type in [(8, "u8"), (16, "u16"), (32, "u32")]:
        entry = f"void SPU::Write{width}(u32 addr, {value_type} val)\n{{"
        if source.count(entry) != 1:
            raise ValueError(f"Expected exactly one SPU::Write{width} entry")
        replacement = entry + f"\n    replay_spu_write({width},addr,val,NDS.ARM7Timestamp);"
        source = source.replace(entry, (declaration if width == 8 else "") + replacement)
    entry = "void SPU::Mix(u32 spucycles)\n{"
    if source.count(entry) != 1:
        raise ValueError("Expected exactly one SPU::Mix entry")
    source = source.replace(entry, "extern void replay_spu_mix();\n" + entry + "\n    replay_spu_mix();")
    return source
