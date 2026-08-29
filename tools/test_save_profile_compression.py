#!/usr/bin/env python3
"""Prove the generated two-level save-profile tables preserve the oracle."""

from __future__ import annotations

from pathlib import Path

from generate_nds_save_profiles import (
    ENTRY_DEPTH,
    PREFIX_DEPTH,
    build_tables,
    load_profiles,
)


def read_hex(path: Path, expected_rows: int) -> list[int]:
    rows = [int(line, 16) for line in path.read_text(encoding="ascii").splitlines()]
    if len(rows) != expected_rows:
        raise AssertionError(f"{path.name}: expected {expected_rows} rows, got {len(rows)}")
    return rows


def decode_tables(prefix_rows: list[int], entry_rows: list[int], prefix_count: int) -> dict[int, int]:
    decoded: dict[int, int] = {}
    expected_start = 0
    previous_prefix = -1
    for row in prefix_rows[:prefix_count]:
        prefix = row >> 19
        start = (row >> 7) & 0xFFF
        count = row & 0x7F
        if prefix <= previous_prefix:
            raise AssertionError("prefix rows are not strictly ordered")
        if start != expected_start:
            raise AssertionError(
                f"prefix 0x{prefix:04X}: expected contiguous start {expected_start}, got {start}"
            )
        if count == 0:
            raise AssertionError(f"prefix 0x{prefix:04X}: empty bucket")
        for entry in entry_rows[start : start + count]:
            code = (prefix << 16) | (entry >> 4)
            save_type = entry & 0xF
            if code in decoded:
                raise AssertionError(f"duplicate generated code 0x{code:08X}")
            if save_type > 7:
                raise AssertionError(f"invalid generated save type {save_type}")
            decoded[code] = save_type
        expected_start += count
        previous_prefix = prefix
    return decoded


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    fpga = repo / "fpga/mister_nitro_console_island"
    oracle = load_profiles(repo / "third_party/melonDS/src/ROMList.cpp")
    expected_prefixes, expected_entries = build_tables(oracle)

    prefix_rows = read_hex(fpga / "nds_save_profile_prefix.hex", PREFIX_DEPTH)
    entry_rows = read_hex(fpga / "nds_save_profile_entries.hex", ENTRY_DEPTH)
    if prefix_rows[: len(expected_prefixes)] != expected_prefixes:
        raise AssertionError("generated prefix ROM differs from the oracle construction")
    if entry_rows[: len(expected_entries)] != expected_entries:
        raise AssertionError("generated entry ROM differs from the oracle construction")
    if any(prefix_rows[len(expected_prefixes) :]):
        raise AssertionError("nonzero data follows the generated prefix table")
    if any(entry_rows[len(expected_entries) :]):
        raise AssertionError("nonzero data follows the generated entry table")

    decoded = decode_tables(prefix_rows, entry_rows, len(expected_prefixes))
    if decoded != oracle:
        missing = set(oracle) - set(decoded)
        extra = set(decoded) - set(oracle)
        changed = {code for code in oracle.keys() & decoded.keys() if oracle[code] != decoded[code]}
        raise AssertionError(
            f"save-profile mismatch: missing={len(missing)} extra={len(extra)} changed={len(changed)}"
        )

    # Because every generated key is proven identical to the oracle and no
    # extra key exists, all other 32-bit codes take the unchanged default path.
    assert decoded.get(0x4553424B, 0) == 0
    assert decoded.get(0x23232323, 0) == 0
    largest_bucket = max(row & 0x7F for row in expected_prefixes)
    print(
        "PASS: two-level save-profile ROM exactly represents "
        f"{len(decoded)} oracle entries in {len(expected_prefixes)} prefixes "
        f"(largest bucket {largest_bucket})"
    )


if __name__ == "__main__":
    main()
