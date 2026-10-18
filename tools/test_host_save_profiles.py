#!/usr/bin/env python3
"""Compare compiled host lookup to the shipped FPGA ROM contents."""
import os
from pathlib import Path
import random
import subprocess
import tempfile
from generate_nds_save_profiles import host_header, ROM_ENTRY, NAND_PROFILES
from test_save_profile_compression import read_hex, decode_tables

root = Path(__file__).resolve().parents[1]
source = root / 'third_party/melonDS/src/ROMList.cpp'
header = root / 'tools/standalone_host/save_profiles.h'
assert header.read_text() == host_header(source), 'stale generated host table'
fpga = root / 'fpga/mister_nitro_console_island'
prefix = read_hex(fpga / 'nds_save_profile_prefix.hex', 512)
entries = read_hex(fpga / 'nds_save_profile_entries.hex', 4096)
oracle = decode_tables(prefix, entries, 368)
oracle.update(NAND_PROFILES)
codes = set(oracle)
# Include every source entry, including type 1 and unsupported entries omitted
# from the FPGA ROM, plus missing codes in present and absent prefix buckets.
for line in source.read_text().splitlines():
    match = ROM_ENTRY.match(line)
    if match:
        codes.add(int(match[1], 16))
rng = random.Random(20261013)
codes.update(rng.getrandbits(32) for _ in range(100000))
codes.update((0, 0xffffffff, 0x4553424b, 0x23232323))
for code in oracle:
    codes.update((code ^ 1, code ^ 0xffff, code ^ 0xffff0000))
with tempfile.TemporaryDirectory(prefix='nds-save-host-') as directory:
    cpp = Path(directory) / 'compare.cpp'
    cpp.write_text('''#include "save_profiles.h"
#include <iostream>
int main() {
    uint32_t code; unsigned expected;
    while (std::cin >> code >> expected) {
        if (nds_save_profile::lookup(code) != expected) {
            std::cerr << "lookup mismatch " << code << "\\n"; return 1;
        }
    }
}
''')
    exe = Path(directory) / 'compare'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-iquote', str(header.parent), str(cpp), '-o', str(exe)], check=True)
    cases = ''.join(f'{code} {oracle.get(code, 0 if code in (0x4553424b, 0x23232323) else 1)}\n'
                    for code in sorted(codes))
    subprocess.run([str(exe)], input=cases, text=True, check=True)
print(f'PASS: compiled host lookup equals ordinary FPGA ROM plus explicit NAND profiles for {len(codes)} codes, all database entries and fallbacks')
