#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate/check the small checkpoint muxes; never rewrite execution logic."""
import argparse
from pathlib import Path
import re
from pipeline_layout import COMMON_FIELDS, ARM9_FIELDS, layout

ROOT = Path(__file__).resolve().parents[2]


def selection(base, bit, size):
    return f'{base}({bit})' if size == 1 else f'{base}({bit+size-1} downto {bit})'


def encode(name, kind, size):
    if kind.startswith(('std_logic',)):
        return name
    if kind.startswith(('unsigned', 'signed')):
        return f'std_logic_vector({name})'
    if kind.startswith('integer'):
        conversion = 'to_signed' if '-64' in kind else 'to_unsigned'
        return f'std_logic_vector({conversion}({name}, {size}))'
    return f'std_logic_vector(to_unsigned({kind}\'pos({name}), {size}))'


def decode(kind, bit, size):
    value = selection('savestate_bus.Din', bit, size)
    if kind.startswith('std_logic'):
        return value
    if kind.startswith('unsigned'):
        return f'unsigned({value})'
    if kind.startswith('signed'):
        return f'signed({value})'
    if kind.startswith('integer'):
        conversion = 'signed' if '-64' in kind else 'unsigned'
        return f'to_integer({conversion}({value}))'
    return f"{kind}'val(to_integer(unsigned({value})))"


def blocks(arm9):
    fields = layout(arm9)
    read = ['   gcheckpoint_pipeline : if EXPERIMENTAL_HALT_CHECKPOINT generate',
            '      process(all) begin',
            "         checkpoint_pipeline <= (others => (others => '0'));" ]
    for name, kind, word, bit, size in fields:
        target = selection(f'checkpoint_pipeline({word-160})', bit, size)
        read.append(f'         {target} <= {encode(name, kind, size)};')
    read += ['      end process;', '   end generate;',
             '   gno_checkpoint_pipeline : if not EXPERIMENTAL_HALT_CHECKPOINT generate',
             "      checkpoint_pipeline <= (others => (others => '0'));", '   end generate;']
    load = ['               if savestate_bus.ena = \'1\' and savestate_bus.rnw = \'0\' and',
            '                  savestate_bus.bEna = "1111" then',
            '                  case to_integer(unsigned(savestate_bus.Adr)) is']
    for address in range(160, 170):
        load.append(f'                     when {address} =>')
        for name, kind, word, bit, size in fields:
            if word == address:
                load.append(f'                        {name} <= {decode(kind, bit, size)};')
    load += ['                     when others => null;', '                  end case;', '               end if;']
    clear = []
    for name, kind in COMMON_FIELDS + (ARM9_FIELDS if arm9 else []):
        if kind == 'std_logic':
            value = "'0'"
        elif kind.startswith(('std_logic_vector', 'unsigned', 'signed')):
            value = "(others => '0')"
        elif kind.startswith('integer'):
            value = '0'
        else:
            value = f"{kind}'left"
        clear.append(f'               {name} <= {value};')
    return {'READBACK': '\n'.join(read), 'DECODE_LOAD': '\n'.join(load),
            'DECODE_RESET': '\n'.join(clear)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    for filename, arm9 in [('nds_cpu9.vhd', True), ('gba_cpu.vhd', False)]:
        path = ROOT / 'third_party/Nitro_DarkSide/d2dabe/rtl' / filename
        source = path.read_text()
        body = source[source.index('signal decode_data '):source.index('-- ############# Execute')]
        actual = [(name, kind.split(':=')[0].strip()) for name, kind in
                  re.findall(r'signal\s+(\w+)\s*:\s*([^;]+);', body)
                  if name not in ('decode_data', 'decode_halt', 'decode_unhalt')]
        assert actual == COMMON_FIELDS + (ARM9_FIELDS if arm9 else []), \
            f'{filename}: decoder fields changed; review checkpoint coverage/ABI'
        for tag, content in blocks(arm9).items():
            start = f'-- BEGIN CHECKPOINT PIPELINE {tag}\n'
            end = f'-- END CHECKPOINT PIPELINE {tag}'
            first = source.index(start) + len(start)
            last = source.index(end, first)
            if args.write:
                source = source[:first] + content + '\n' + source[last:]
            else:
                assert source[first:last] == content + '\n', f'{filename}: stale generated {tag}'
        if args.write:
            path.write_text(source)
    print('PASS: pipeline layout covers all decoder registers and generated muxes match')


if __name__ == '__main__':
    main()
