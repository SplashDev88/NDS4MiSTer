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


def rtl_lookup(prefix_rows: list[int], entry_rows: list[int], prefix_count: int, code: int) -> int:
    """Cycle-independent result of the production PREFIX/ENTRY state walk."""
    default = 0 if code in (0x4553424B, 0x23232323) else 1
    for prefix_row in prefix_rows[:prefix_count]:
        if ((prefix_row >> 19) & 0xFFFF) != (code >> 16):
            continue
        start = (prefix_row >> 7) & 0xFFF
        count = prefix_row & 0x7F
        for entry in entry_rows[start : start + count]:
            if (entry >> 4) == (code & 0xFFFF) and (entry & 0xF) <= 7:
                return entry & 0xF
        return default
    return default


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
    if any(row >= 1 << 35 for row in prefix_rows):
        raise AssertionError("prefix ROM uses the reserved 36th hex-token bit")

    # Keep the mixed-language production contract aligned. Quartus 17 reports
    # an unknown generic instead of binding by position when these names drift.
    save_rtl = (repo / "rtl/nds_nitro_save_profile.sv").read_text(encoding="utf-8")
    console_top = (repo / "rtl/nds_nitro_console_top.vhd").read_text(encoding="utf-8")
    required_rtl = (
        "parameter integer PREFIX_COUNT = 368",
        "logic [35:0] prefix_rom [0:511]",
        "logic [35:0] prefix_entry",
        "prefix_entry[34:19] == target[31:16]",
    )
    for marker in required_rtl:
        if marker not in save_rtl:
            raise AssertionError(f"save-profile product contract missing: {marker}")
    if console_top.count("PREFIX_COUNT") != 2:
        raise AssertionError("VHDL save-profile component and instance must both use PREFIX_COUNT")
    if "PREFIX_COUNT: integer := 368" not in console_top:
        raise AssertionError("VHDL save-profile component has the wrong prefix count")
    if "PREFIX_COUNT => 368" not in console_top:
        raise AssertionError("VHDL save-profile instance has the wrong prefix count")
    component_start = console_top.index("component nds_nitro_save_profile")
    component_end = console_top.index("end component;", component_start)
    instance_start = console_top.index("isaveprofile : nds_nitro_save_profile")
    instance_end = console_top.index("port map", instance_start)
    binding_text = console_top[component_start:component_end] + console_top[instance_start:instance_end]
    if "ENTRY_COUNT" in binding_text:
        raise AssertionError("stale ENTRY_COUNT remains in the save-profile VHDL binding")

    decoded = decode_tables(prefix_rows, entry_rows, len(expected_prefixes))
    if decoded != oracle:
        missing = set(oracle) - set(decoded)
        extra = set(decoded) - set(oracle)
        changed = {code for code in oracle.keys() & decoded.keys() if oracle[code] != decoded[code]}
        raise AssertionError(
            f"save-profile mismatch: missing={len(missing)} extra={len(extra)} changed={len(changed)}"
        )

    # Exercise the exact prefix/bucket walk for every generated oracle entry,
    # then one absent low half in every populated prefix. This covers all bucket
    # lengths and both the found and exhausted-bucket RTL exits.
    for code, expected_type in oracle.items():
        actual_type = rtl_lookup(prefix_rows, entry_rows, len(expected_prefixes), code)
        if actual_type != expected_type:
            raise AssertionError(
                f"RTL walk 0x{code:08X}: expected {expected_type}, got {actual_type}"
            )
    absent_checks = 0
    for prefix_row in expected_prefixes:
        prefix = prefix_row >> 19
        start = (prefix_row >> 7) & 0xFFF
        count = prefix_row & 0x7F
        occupied = {entry >> 4 for entry in entry_rows[start : start + count]}
        missing_low = next(low for low in range(0x10000) if low not in occupied)
        code = (prefix << 16) | missing_low
        expected_default = 0 if code in (0x4553424B, 0x23232323) else 1
        if rtl_lookup(prefix_rows, entry_rows, len(expected_prefixes), code) != expected_default:
            raise AssertionError(f"RTL exhausted-bucket default failed for 0x{code:08X}")
        absent_checks += 1
    for code, expected_type in ((0x00000000, 1), (0xFFFFFFFF, 1),
                                (0x4553424B, 0), (0x23232323, 0)):
        if rtl_lookup(prefix_rows, entry_rows, len(expected_prefixes), code) != expected_type:
            raise AssertionError(f"RTL missing-prefix/default failed for 0x{code:08X}")

    # Because every generated key is proven identical to the oracle and no
    # extra key exists, all other 32-bit codes take the unchanged default path.
    assert decoded.get(0x4553424B, 0) == 0
    assert decoded.get(0x23232323, 0) == 0
    largest_bucket = max(row & 0x7F for row in expected_prefixes)
    print(
        "PASS: two-level save-profile ROM exactly represents "
        f"{len(decoded)} oracle entries in {len(expected_prefixes)} prefixes "
        f"({absent_checks} exhausted-bucket defaults; largest bucket {largest_bucket}; "
        "35-bit payload in zero-padded 36-bit hex storage)"
    )


if __name__ == "__main__":
    main()
