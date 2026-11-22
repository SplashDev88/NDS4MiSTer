#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reassemble the regional Pinball routines and compare their bytes with the runtime catalog."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parents[1] / 'standalone_host/fmv/guest_catalog.json'


CODE_OFFSETS = {'AP2E': 0, 'AP2P': 0x1DF0, 'AP2J': 0x1934}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', default='arm-linux-gnueabihf-')
    parser.add_argument('--catalog', type=Path, default=DEFAULT_CATALOG)
    args = parser.parse_args()
    entries = json.loads(args.catalog.read_text())['entries']
    sections = {'integer-division': '.divide', 'sound-decoder': '.sound'}

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        def tool(name, *arguments):
            return subprocess.check_output([args.prefix + name, *map(str, arguments)], cwd=work)

        tool('as', '-march=armv5te', HERE / 'pinball.S', '-o', 'pinball.o')
        for code, offset in CODE_OFFSETS.items():
            entry, = [e for e in entries if e['manifest']['game_code'] == code and
                      e['manifest']['revision'] == 0]
            assert set(entry['patch_ids']) == set(sections) and entry['manifest']['atomic_selection']
            tool('ld', '--defsym', f'code_delta={offset}', '-T', HERE / 'pinball.ld', 'pinball.o', '-o', 'pinball.elf')
            headers = tool('objdump', '-h', 'pinball.elf').decode()
            for patch in entry['manifest']['patches']:
                section = sections[patch['id']]
                match = re.search(r'^\s*\d+\s+' + re.escape(section) + r'\s+\w+\s+(\w+)', headers, re.M)
                assert match and int(match[1], 16) == int(patch['addr'], 16)
                tool('objcopy', '-O', 'binary', '-j', section, 'pinball.elf', 'section.bin')
                image = (work / 'section.bin').read_bytes()
                assert image == bytes.fromhex(patch['replace']) and len(image) == len(bytes.fromhex(patch['expect']))
    print('Pinball ARM9 routines match the runtime catalog.')


if __name__ == '__main__':
    main()
