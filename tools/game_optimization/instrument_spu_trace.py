#!/usr/bin/env python3
"""Instrument a private SPU source copy for the existing replay oracle.

This observes writes and mix boundaries, without changing emulated registers,
time or audio. The source must contain each exact entry point once.
"""


def instrument(source, *, samples=False):
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
    if not samples:
        return source

    def replace_once(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError('Expected exactly one audio sample observation site: ' + old[:70])
        source = source.replace(old, new)

    entry = 'void SPUChannel::FIFO_BufferData()\n{'
    replace_once(entry, '''extern void replay_spu_start(const SPUChannel&);
extern void replay_spu_fifo(unsigned,u32,u32);
extern void replay_spu_sample(unsigned,unsigned,s32,s16);
extern void replay_spu_channel_output(unsigned,s32,unsigned);
extern void replay_spu_mixed_output(s16,s16);
''' + entry)
    for assignment in ['NDS.ARM7Read32(SrcAddr + FIFOReadOffset)', '0']:
        line = f'            FIFO[FIFOWritePos] = {assignment};'
        replace_once(line, line + '\n            replay_spu_fifo(Num,SrcAddr + FIFOReadOffset,FIFO[FIFOWritePos]);')
    entry = 'void SPUChannel::Start()\n{'
    replace_once(entry, entry + '\n    replay_spu_start(*this);')
    line = '''        case 4: NextSample_Noise(); break;
        }
'''
    replace_once(line, line + '\n        replay_spu_sample(Num,type,Pos,CurSample);\n')
    line = '        s32 ch3 = Channels[3].DoRun(spucycles);'
    replace_once(line, line + ''.join(
        f'\n        replay_spu_channel_output({n},ch{n},Channels[{n}].Pan);'
        for n in range(4)))
    line = '            s32 channel = chan->DoRun(spucycles);'
    replace_once(line, line + '\n            replay_spu_channel_output(chan->Num,channel,chan->Pan);')
    line = '    BlipTimer += spucycles;'
    replace_once(line, '    replay_spu_mixed_output(output[0],output[1]);\n\n' + line)
    return source
