#!/usr/bin/env python3
"""Exhaustively compare the ARM7 shared rotator with the retired shifters.

The operand set contains zero, all ones, every one-hot and inverse-one-hot
word, and alternating patterns.  Those basis vectors exercise every data and
carry input independently.  Shift modes, carry values, register amounts
0..255, immediate amounts 0..31, and RRX are exhaustive.
"""

from __future__ import annotations

from pathlib import Path


MASK32 = (1 << 32) - 1
LSL, LSR, ASR, ROR = range(4)


def bit(value: int, index: int) -> int:
    return (value >> index) & 1


def ror32(value: int, amount: int) -> int:
    amount &= 31
    if amount == 0:
        return value & MASK32
    return ((value >> amount) | (value << (32 - amount))) & MASK32


def decode_amount(mode: int, raw_amount: int, register_based: bool) -> tuple[int, bool]:
    """Mirror gba_cpu's decode normalization before the shifter."""
    if register_based:
        raw_amount &= 0xFF
        if mode == ROR and raw_amount > 32:
            folded = raw_amount & 31
            return (32 if folded == 0 else folded), False
        return raw_amount, False

    raw_amount &= 31
    if raw_amount == 0 and mode in (LSR, ASR):
        return 32, False
    if raw_amount == 0 and mode == ROR:
        return 0, True
    return raw_amount, False


def retired_shifters(value: int, carry: int, mode: int, amount: int, rrx: bool) -> tuple[int, int]:
    """Bit-exact model of the parallel shifter block removed from gba_cpu."""
    value &= MASK32
    if rrx:
        return ((carry << 31) | (value >> 1)), bit(value, 0)

    if mode == LSL:
        if amount >= 32:
            return 0, bit(value, 0) if amount == 32 else 0
        if amount > 0:
            return (value << amount) & MASK32, bit(value, 32 - amount)
        return value, carry

    if mode == LSR:
        if amount >= 32:
            return 0, bit(value, 31) if amount == 32 else 0
        if amount > 0:
            return value >> amount, bit(value, amount - 1)
        return value, carry

    if mode == ASR:
        if amount >= 32:
            sign = bit(value, 31)
            return (MASK32 if sign else 0), sign
        if amount > 0:
            signed_value = value if value < (1 << 31) else value - (1 << 32)
            return (signed_value >> amount) & MASK32, bit(value, amount - 1)
        return value, carry

    if amount >= 32:
        return value, bit(value, 31)
    if amount > 0:
        return ror32(value, amount), bit(value, amount - 1)
    return value, carry


def shared_rotator(value: int, carry: int, mode: int, amount: int, rrx: bool) -> tuple[int, int]:
    """Model the shared rotate/keep/fill network now instantiated in gba_cpu."""
    value &= MASK32
    rotate = 0
    keep = MASK32
    fill = 0
    carry_result = carry

    if rrx:
        rotate = 1
        keep &= ~(1 << 31)
        fill = carry << 31
        carry_result = bit(value, 0)
    elif amount != 0:
        if mode == LSL:
            if amount < 32:
                rotate = 32 - amount
                keep &= ~((1 << amount) - 1)
                carry_result = bit(value, 32 - amount)
            else:
                keep = 0
                carry_result = bit(value, 0) if amount == 32 else 0
        elif mode == LSR:
            if amount < 32:
                rotate = amount
                keep = (1 << (32 - amount)) - 1
                carry_result = bit(value, amount - 1)
            else:
                keep = 0
                carry_result = bit(value, 31) if amount == 32 else 0
        elif mode == ASR:
            carry_result = bit(value, amount - 1) if amount < 32 else bit(value, 31)
            if amount < 32:
                rotate = amount
                keep = (1 << (32 - amount)) - 1
                if bit(value, 31):
                    fill = MASK32 ^ keep
            else:
                keep = 0
                fill = MASK32 if bit(value, 31) else 0
        else:
            if amount < 32:
                rotate = amount
                carry_result = bit(value, amount - 1)
            else:
                carry_result = bit(value, 31)

    result = (ror32(value, rotate) & keep) | (fill & (MASK32 ^ keep))
    return result & MASK32, carry_result


def production_structure_check(repo: Path) -> None:
    source = (repo / "third_party/Nitro_DarkSide/d2dabe/rtl/gba_cpu.vhd").read_text()
    required = (
        "type t_shfill is (FILL_ZERO, FILL_SIGN, FILL_CARRY);",
        "sh_rotv  <= shiftervalue ror sh_rot;",
        "gshiftbit : for i in 0 to 31 generate",
        "shiftervalue(sh_cidx) when sh_csel = CSEL_VALUE else '0';",
    )
    forbidden = (
        "shiftresult_LSL",
        "shiftresult_RSL",
        "shiftresult_ARS",
        "shiftresult_ROR",
        "shiftresult_RRX",
    )
    for marker in required:
        if marker not in source:
            raise AssertionError(f"production ARM7 shared-shifter marker is missing: {marker}")
    for marker in forbidden:
        if marker in source:
            raise AssertionError(f"retired parallel ARM7 shifter remains: {marker}")


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    production_structure_check(repo)

    values = {0, MASK32, 0xAAAAAAAA, 0x55555555, 0x80000001}
    for index in range(32):
        values.add(1 << index)
        values.add(MASK32 ^ (1 << index))

    checks = 0
    for register_based, maximum in ((False, 31), (True, 255)):
        for mode in (LSL, LSR, ASR, ROR):
            for raw_amount in range(maximum + 1):
                amount, rrx = decode_amount(mode, raw_amount, register_based)
                for carry in (0, 1):
                    for value in values:
                        expected = retired_shifters(value, carry, mode, amount, rrx)
                        actual = shared_rotator(value, carry, mode, amount, rrx)
                        if actual != expected:
                            raise AssertionError(
                                "ARM7 shifter mismatch: "
                                f"reg={register_based} mode={mode} raw={raw_amount} "
                                f"normalized={amount} rrx={rrx} carry={carry} "
                                f"value=0x{value:08X} expected={expected} actual={actual}"
                            )
                        checks += 1

    print(f"PASS: ARM7 shared rotator matches retired shifters ({checks} exhaustive basis cases)")


if __name__ == "__main__":
    main()
