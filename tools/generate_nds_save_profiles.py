#!/usr/bin/env python3
"""Generate the two-level NDS cartridge save-profile ROMs."""

from __future__ import annotations

import argparse
import os
import re
from collections import defaultdict
from pathlib import Path


ROM_ENTRY = re.compile(
    r"^\s*\{0x([0-9A-Fa-f]{8}),\s*0x([0-9A-Fa-f]{8}),\s*0x([0-9A-Fa-f]{8})\},"
)
PREFIX_DEPTH = 512
ENTRY_DEPTH = 4096
MAX_BUCKET = 127


def load_profiles(source: Path) -> dict[int, int]:
    profiles: dict[int, int] = {}
    for line in source.read_text(encoding="utf-8").splitlines():
        match = ROM_ENTRY.match(line)
        if match is None:
            continue
        code, _rom_size, save_type = (int(field, 16) for field in match.groups())
        # Type 1 is the lookup default.  Keep explicit no-save entries and the
        # larger EEPROM/FRAM/Flash types that differ from that default.
        if save_type == 0 or 2 <= save_type <= 7:
            if code in profiles:
                raise ValueError(f"duplicate game code 0x{code:08X}")
            profiles[code] = save_type
    return profiles


def build_tables(profiles: dict[int, int]) -> tuple[list[int], list[int]]:
    buckets: dict[int, list[tuple[int, int]]] = defaultdict(list)
    for code, save_type in sorted(profiles.items()):
        buckets[code >> 16].append((code & 0xFFFF, save_type))

    if len(buckets) > PREFIX_DEPTH:
        raise ValueError(f"save-profile prefix count {len(buckets)} exceeds {PREFIX_DEPTH}")

    prefixes: list[int] = []
    entries: list[int] = []
    for prefix, bucket in sorted(buckets.items()):
        if len(bucket) > MAX_BUCKET:
            raise ValueError(
                f"save-profile prefix 0x{prefix:04X} has {len(bucket)} entries; max is {MAX_BUCKET}"
            )
        start = len(entries)
        if start >= ENTRY_DEPTH or start + len(bucket) > ENTRY_DEPTH:
            raise ValueError(f"save-profile entry count exceeds {ENTRY_DEPTH}")
        # 35-bit prefix row: prefix[34:19], start[18:7], count[6:0].
        prefixes.append((prefix << 19) | (start << 7) | len(bucket))
        # 20-bit entry row: low game-code half[19:4], save type[3:0].
        entries.extend((low << 4) | save_type for low, save_type in bucket)

    if len(entries) != len(profiles):
        raise AssertionError("save-profile table construction lost an entry")
    return prefixes, entries


def write_hex(path: Path, rows: list[int], depth: int, digits: int) -> None:
    if len(rows) > depth:
        raise ValueError(f"{path.name} has {len(rows)} rows; depth is {depth}")
    padded = rows + [0] * (depth - len(rows))
    text = "".join(f"{row:0{digits}X}\n" for row in padded)

    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="ascii")
    os.replace(temporary, path)


def generate(source: Path, prefix_output: Path, entry_output: Path) -> tuple[int, int, int]:
    profiles = load_profiles(source)
    prefixes, entries = build_tables(profiles)
    write_hex(prefix_output, prefixes, PREFIX_DEPTH, 9)
    write_hex(entry_output, entries, ENTRY_DEPTH, 5)
    largest_bucket = max((row & 0x7F) for row in prefixes)
    return len(prefixes), len(entries), largest_bucket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("prefix_output", type=Path)
    parser.add_argument("entry_output", type=Path)
    args = parser.parse_args()
    prefix_count, entry_count, largest_bucket = generate(
        args.source, args.prefix_output, args.entry_output
    )
    print(
        f"generated {prefix_count} prefixes, {entry_count} entries "
        f"(largest bucket {largest_bucket})"
    )


if __name__ == "__main__":
    main()
