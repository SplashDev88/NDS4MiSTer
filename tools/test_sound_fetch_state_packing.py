#!/usr/bin/env python3
"""Equivalence test for packed NDS sound fetch pointer/remaining state."""

from __future__ import annotations

import random
from pathlib import Path


PTR_MASK = (1 << 25) - 1
REM_MASK = (1 << 24) - 1


def pack(pointer: int, remaining: int) -> int:
    return ((remaining & REM_MASK) << 25) | (pointer & PTR_MASK)


def unpack(word: int) -> tuple[int, int]:
    return word & PTR_MASK, (word >> 25) & REM_MASK


def production_structure_check(repo: Path) -> None:
    source = (repo / "third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd").read_text()
    required = (
        "BYTE_WIDTH => 13, BYTES => 4, ADDR_WIDTH => 4",
        'fetchstate_a_din <= "000" & std_logic_vector(frem_a_din)',
        'fptr_b_dout <= "0000000" & fetchstate_b_dout(24 downto 0);',
        'frem_b_dout <= x"00" & fetchstate_b_dout(48 downto 25);',
        "assert fptr_a_we = frem_a_we",
        "assert fptr_b_we = frem_b_we",
        "fptr_b_din <= unsigned(fptr_b_dout(24 downto 0));",
    )
    for marker in required:
        if marker not in source:
            raise AssertionError(f"packed sound fetch-state marker is missing: {marker}")
    for retired in ("iram_fptr :", "iram_frem :"):
        if retired in source:
            raise AssertionError(f"retired sound fetch-state RAM remains: {retired}")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    production_structure_check(repo)

    boundaries = (0, 1, 2, 0xFF, 0xFFFF, 0x10000, PTR_MASK)
    remaining_boundaries = (0, 1, 2, 0xFF, 0xFFFF, 0x10000, REM_MASK)
    checks = 0
    for pointer in boundaries:
        for remaining in remaining_boundaries:
            if unpack(pack(pointer, remaining)) != (pointer & PTR_MASK, remaining & REM_MASK):
                raise AssertionError("packed fetch-state boundary round trip failed")
            checks += 1

    rng = random.Random(0x4E445353)
    separate = [(0, 0) for _ in range(16)]
    packed = [pack(0, 0) for _ in range(16)]
    for _ in range(100_000):
        channel = rng.randrange(16)
        operation = rng.randrange(4)
        pointer, remaining = separate[channel]
        if operation == 0:  # CPU channel start
            pointer = rng.randrange(PTR_MASK + 1)
            remaining = rng.randrange(REM_MASK + 1)
        elif operation == 1:  # loop wrap
            pointer = rng.randrange(PTR_MASK + 1)
            remaining = rng.randrange(REM_MASK + 1)
        elif operation == 2:  # one-shot exhaustion: only frem changes logically
            remaining = 0
        elif remaining > 0:  # ordinary fetch completion
            pointer = (pointer + 1) & PTR_MASK
            remaining -= 1

        separate[channel] = (pointer, remaining)
        packed[channel] = pack(pointer, remaining)
        if unpack(packed[channel]) != separate[channel]:
            raise AssertionError(f"packed fetch-state update diverged on channel {channel}")
        checks += 1

    if [unpack(word) for word in packed] != separate:
        raise AssertionError("final packed fetch-state array differs from separate arrays")
    print(f"PASS: packed sound fetch state preserves pointer/count behavior ({checks} cases)")


if __name__ == "__main__":
    main()
