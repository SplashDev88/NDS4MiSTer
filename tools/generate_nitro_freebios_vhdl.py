#!/usr/bin/env python3
"""Generate compact registered FreeBIOS VHDL ROMs from audited melonDS data."""

from __future__ import annotations

import hashlib
import pathlib
import re


HEADER_SHA256 = "898554cf7dc726c808b3ef48a88040899e1bf7573c6005f0184acb71f90567f0"

IMAGES = (
    (
        "bios_ntr_arm7",
        "nds_nitro_freebios7.vhd",
        "nds_nitro_freebios7",
        "bios_addr",
        "bios_data",
        12,
        16384,
        "a067b0e483fc16fbcb9294d6b7a1ac86f7dc41a4407654ec3bc554d0809ae76a",
    ),
    (
        "bios_ntr_arm9",
        "nds_nitro_freebios9.vhd",
        "nds_nitro_freebios9",
        "brom_addr",
        "brom_data",
        13,
        4096,
        "e10e164e7d82c83cbf763388d0c3c8fb33e48451c39cbe3a052e589aa645de74",
    ),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def array_bytes(text: str, name: str) -> bytes:
    match = re.search(
        rf"unsigned char\s+{re.escape(name)}\[\]\s*=\s*\{{(.*?)\}};",
        text,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit(f"missing FreeBIOS array: {name}")
    return bytes(int(token, 16) for token in re.findall(r"0x([0-9A-Fa-f]{2})", match.group(1)))


def render(
    data: bytes,
    entity: str,
    address_name: str,
    data_name: str,
    address_width: int,
) -> str:
    words = [int.from_bytes(data[i : i + 4], "little") for i in range(0, len(data), 4)]
    last = max(i for i, word in enumerate(words) if word)
    nonzero = [(i, word) for i, word in enumerate(words[: last + 1]) if word]
    lines = [
        "-- SPDX-License-Identifier: BSD-2-Clause",
        "-- Generated from melonDS FreeBIOS_Data.h by tools/generate_nitro_freebios_vhdl.py.",
        "-- The full FreeBIOS copyright/license notice is in",
        "-- third_party/melonDS/freebios/drastic_bios_readme.txt.",
        "library IEEE;",
        "use IEEE.std_logic_1164.all;",
        "use IEEE.numeric_std.all;",
        "",
        f"entity {entity} is",
        "   port",
        "   (",
        "      clk : in std_logic;",
        f"      {address_name} : in unsigned({address_width + 1} downto 2);",
        f"      {data_name} : out std_logic_vector(31 downto 0)",
        "   );",
        "end entity;",
        "",
        f"architecture rtl of {entity} is",
        f"   type t_rom is array (0 to {last}) of std_logic_vector(31 downto 0);",
        "   constant ROM : t_rom := (",
    ]
    for address, word in nonzero:
        lines.append(f'      {address} => x"{word:08X}",')
    lines.extend(
        [
            "      others => (others => '0')",
            "   );",
            "begin",
            "   process (clk)",
            "   begin",
            "      if rising_edge(clk) then",
            f"         if to_integer({address_name}) <= t_rom'high then",
            f"            {data_name} <= ROM(to_integer({address_name}));",
            "         else",
            f"            {data_name} <= (others => '0');",
            "         end if;",
            "      end if;",
            "   end process;",
            "end architecture;",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parents[1]
    header = repo / "third_party/melonDS/src/FreeBIOS_Data.h"
    header_data = header.read_bytes()
    if sha256(header_data) != HEADER_SHA256:
        raise SystemExit("FreeBIOS_Data.h does not match the audited source")
    text = header_data.decode("ascii")

    for array_name, filename, entity, address_name, data_name, width, size, expected_sha in IMAGES:
        raw = array_bytes(text, array_name)
        if len(raw) > size:
            raise SystemExit(f"{array_name} is larger than its NTR BIOS window")
        padded = raw + bytes(size - len(raw))
        if sha256(padded) != expected_sha:
            raise SystemExit(f"{array_name} padded hash mismatch")
        output = repo / "rtl" / filename
        output.write_text(render(padded, entity, address_name, data_name, width), encoding="ascii")
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
