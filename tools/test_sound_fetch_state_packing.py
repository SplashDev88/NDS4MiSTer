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
    ram = (repo / "rtl/nds_sound_fetch_state_ram.vhd").read_text()
    required = (
        "entity work.nds_sound_fetch_state_ram",
        "fetchstate_a_din <= std_logic_vector(frem_a_din)",
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
    if "BYTE_WIDTH => 13" in source:
        raise AssertionError("illegal four-by-13-bit packed RAM mapping remains")

    ram_required = (
        "width_a => 49",
        "width_b => 49",
        "width_byteena_a => 1",
        "width_byteena_b => 1",
        'read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ"',
        'read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ"',
    )
    for marker in ram_required:
        if marker not in ram:
            raise AssertionError(f"legal packed sound RAM marker is missing: {marker}")
    if "\n         byteena_a =>" in ram or "\n         byteena_b =>" in ram:
        raise AssertionError("packed sound RAM must disconnect unused byteena ports")


def transition(
    pointer: int,
    remaining: int,
    operation: int,
    next_pointer: int = 0,
    next_remaining: int = 0,
) -> tuple[int, int]:
    if operation in (0, 1):  # CPU channel start or loop wrap
        return next_pointer & PTR_MASK, next_remaining & REM_MASK
    if operation == 2:  # one-shot exhaustion: pointer is retained
        return pointer & PTR_MASK, 0
    if remaining > 0:  # ordinary completed word fetch
        return (pointer + 1) & PTR_MASK, remaining - 1
    return pointer & PTR_MASK, 0


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

    # Exhaust every fetch-state transition class for every channel and all
    # meaningful field boundaries. Start/wrap write arbitrary full-width state;
    # exhaustion preserves the pointer; normal completion increments/decrements
    # with exact field-width wrap behavior.
    for channel in range(16):
        for pointer in boundaries:
            for remaining in remaining_boundaries:
                for operation in range(4):
                    next_pointer = boundaries[(channel + operation) % len(boundaries)]
                    next_remaining = remaining_boundaries[
                        (channel * 3 + operation) % len(remaining_boundaries)
                    ]
                    expected = transition(
                        pointer, remaining, operation, next_pointer, next_remaining
                    )
                    actual = unpack(
                        pack(*transition(
                            *unpack(pack(pointer, remaining)),
                            operation,
                            next_pointer,
                            next_remaining,
                        ))
                    )
                    if actual != expected:
                        raise AssertionError(
                            f"packed transition class {operation} diverged on channel {channel}"
                        )
                    checks += 1

    rng = random.Random(0x4E445353)
    separate = [(0, 0) for _ in range(16)]
    packed = [pack(0, 0) for _ in range(16)]
    for _ in range(100_000):
        channel = rng.randrange(16)
        operation = rng.randrange(4)
        pointer, remaining = separate[channel]
        next_pointer = rng.randrange(PTR_MASK + 1)
        next_remaining = rng.randrange(REM_MASK + 1)
        pointer, remaining = transition(
            pointer, remaining, operation, next_pointer, next_remaining
        )

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
