#!/usr/bin/env python3
"""Generate compact Cyclone-V FreeBIOS ROMs from audited melonDS data."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import pathlib
import re


HEADER_SHA256 = "898554cf7dc726c808b3ef48a88040899e1bf7573c6005f0184acb71f90567f0"


@dataclass(frozen=True)
class Image:
    array_name: str
    stem: str
    entity: str
    address_name: str
    data_name: str
    address_width: int
    window_size: int
    expected_sha256: str
    # Inclusive source-word ranges, followed by their compact first row.
    regions: tuple[tuple[int, int, int], ...]
    zero_row: int
    compact_address_width: int

    @property
    def depth(self) -> int:
        return self.zero_row + 1


IMAGES = (
    Image(
        "bios_ntr_arm7",
        "nds_nitro_freebios7",
        "nds_nitro_freebios7",
        "bios_addr",
        "bios_data",
        12,
        16384,
        "a067b0e483fc16fbcb9294d6b7a1ac86f7dc41a4407654ec3bc554d0809ae76a",
        ((0, 7, 0), (1054, 2059, 8)),
        1014,
        10,
    ),
    Image(
        "bios_ntr_arm9",
        "nds_nitro_freebios9",
        "nds_nitro_freebios9",
        "brom_addr",
        "brom_data",
        13,
        4096,
        "e10e164e7d82c83cbf763388d0c3c8fb33e48451c39cbe3a052e589aa645de74",
        ((0, 468, 0),),
        469,
        9,
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


def padded_words(data: bytes, image: Image) -> list[int]:
    if len(data) > image.window_size:
        raise SystemExit(f"{image.array_name} is larger than its NTR BIOS window")
    padded = data + bytes(image.window_size - len(data))
    if sha256(padded) != image.expected_sha256:
        raise SystemExit(f"{image.array_name} padded hash mismatch")
    # FreeBIOS_Data.h is a byte image in NDS little-endian word order.
    return [int.from_bytes(padded[i : i + 4], "little") for i in range(0, len(padded), 4)]


def compact_words(words: list[int], image: Image) -> list[int]:
    compact = [0] * image.depth
    for first, last, compact_first in image.regions:
        count = last - first + 1
        compact[compact_first : compact_first + count] = words[first : last + 1]
    if compact[image.zero_row] != 0:
        raise SystemExit(f"{image.array_name} zero sentinel is not zero")
    return compact


def render_mif(words: list[int], image: Image) -> str:
    address_digits = (image.compact_address_width + 3) // 4
    lines = [
        "-- SPDX-License-Identifier: BSD-2-Clause",
        "-- Generated from melonDS FreeBIOS_Data.h by tools/generate_nitro_freebios_vhdl.py.",
        "-- The full FreeBIOS copyright/license notice is in",
        "-- third_party/melonDS/freebios/drastic_bios_readme.txt.",
        f"DEPTH = {image.depth};",
        "WIDTH = 32;",
        "ADDRESS_RADIX = HEX;",
        "DATA_RADIX = HEX;",
        "CONTENT BEGIN",
    ]
    for address, word in enumerate(words):
        lines.append(f"   {address:0{address_digits}X} : {word:08X};")
    lines.extend(["END;", ""])
    return "\n".join(lines)


def render_mapping(image: Image) -> list[str]:
    address = image.address_name
    valid_terms = [
        f"({address} >= to_unsigned({first}, {address}'length) and "
        f"{address} <= to_unsigned({last}, {address}'length))"
        for first, last, _ in image.regions
    ]
    valid = " or\n      ".join(valid_terms)
    lines = [f"   rom_valid <= '1' when {valid} else '0';", "", f"   process ({address})", "   begin"]
    lines.append(f"      rom_addr <= std_logic_vector(to_unsigned(ZERO_ROW, rom_addr'length));")
    for index, (first, last, compact_first) in enumerate(image.regions):
        keyword = "if" if index == 0 else "elsif"
        lines.append(
            f"      {keyword} {address} >= to_unsigned({first}, {address}'length) and "
            f"{address} <= to_unsigned({last}, {address}'length) then"
        )
        if first == compact_first:
            expression = f"resize({address}, rom_addr'length)"
        else:
            expression = (
                f"resize({address} - to_unsigned({first}, {address}'length), rom_addr'length) + "
                f"to_unsigned({compact_first}, rom_addr'length)"
            )
        lines.append(f"         rom_addr <= std_logic_vector({expression});")
    lines.extend(["      end if;", "   end process;"])
    return lines


def render_vhdl(words: list[int], image: Image) -> str:
    nonzero = [(i, word) for i, word in enumerate(words) if word]
    lines = [
        "-- SPDX-License-Identifier: BSD-2-Clause",
        "-- Generated from melonDS FreeBIOS_Data.h by tools/generate_nitro_freebios_vhdl.py.",
        "-- The full FreeBIOS copyright/license notice is in",
        "-- third_party/melonDS/freebios/drastic_bios_readme.txt.",
        "-- The synthesis path is an explicit Cyclone-V M10K ROM.  Its input",
        "-- address register plus unregistered output preserves the one-cycle contract.",
        "library IEEE;",
        "use IEEE.std_logic_1164.all;",
        "use IEEE.numeric_std.all;",
        "",
        "library altera_mf;",
        "use altera_mf.altera_mf_components.all;",
        "",
        f"entity {image.entity} is",
        "   generic",
        "   (",
        "      is_simu : std_logic := '0'",
        "   );",
        "   port",
        "   (",
        "      clk : in std_logic;",
        f"      {image.address_name} : in unsigned({image.address_width + 1} downto 2);",
        f"      {image.data_name} : out std_logic_vector(31 downto 0)",
        "   );",
        "end entity;",
        "",
        f"architecture rtl of {image.entity} is",
        f"   constant ZERO_ROW : natural := {image.zero_row};",
        f"   type t_sim_rom is array (0 to {image.zero_row}) of std_logic_vector(31 downto 0);",
        "   constant SIM_ROM : t_sim_rom := (",
    ]
    for address, word in nonzero:
        lines.append(f'      {address} => x"{word:08X}",')
    lines.extend(
        [
            "      others => (others => '0')",
            "   );",
            f"   signal rom_addr : std_logic_vector({image.compact_address_width - 1} downto 0);",
            "   signal rom_valid : std_logic;",
            "   signal rom_valid_q : std_logic;",
            "   signal rom_data : std_logic_vector(31 downto 0);",
            "begin",
        ]
    )
    lines.extend(render_mapping(image))
    lines.extend(
        [
            "",
            "   -- Validity follows the same input register edge as the M10K address.",
            "   process (clk)",
            "   begin",
            "      if rising_edge(clk) then",
            "         rom_valid_q <= rom_valid;",
            "      end if;",
            "   end process;",
            "",
            "   g_sim : if is_simu = '1' generate",
            f"      signal sim_addr_q : std_logic_vector({image.compact_address_width - 1} downto 0) := (others => '0');",
            "   begin",
            "      process (clk)",
            "      begin",
            "         if rising_edge(clk) then",
            "            sim_addr_q <= rom_addr;",
            "         end if;",
            "      end process;",
            "      rom_data <= SIM_ROM(to_integer(unsigned(sim_addr_q)));",
            "   end generate;",
            "",
            "   g_m10k : if is_simu = '0' generate",
            "   begin",
            "      irom : altsyncram",
            "      generic map",
            "      (",
            '         address_reg_a => "CLOCK0",',
            '         clock_enable_input_a => "BYPASS",',
            '         clock_enable_output_a => "BYPASS",',
            f'         init_file => "../../rtl/{image.stem}.mif",',
            '         intended_device_family => "Cyclone V",',
            '         lpm_hint => "ENABLE_RUNTIME_MOD=NO",',
            '         lpm_type => "altsyncram",',
            f"         numwords_a => {image.depth},",
            '         operation_mode => "ROM",',
            '         outdata_aclr_a => "NONE",',
            '         outdata_reg_a => "UNREGISTERED",',
            '         power_up_uninitialized => "FALSE",',
            '         ram_block_type => "M10K",',
            f"         widthad_a => {image.compact_address_width},",
            "         width_a => 32,",
            "         width_byteena_a => 1",
            "      )",
            "      port map",
            "      (",
            "         address_a => rom_addr,",
            "         clock0 => clk,",
            "         q_a => rom_data",
            "      );",
            "   end generate;",
            "",
            f"   {image.data_name} <= rom_data when rom_valid_q = '1' else (others => '0');",
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

    for image in IMAGES:
        raw = array_bytes(text, image.array_name)
        compact = compact_words(padded_words(raw, image), image)
        vhdl_output = repo / "rtl" / f"{image.stem}.vhd"
        mif_output = repo / "rtl" / f"{image.stem}.mif"
        vhdl_output.write_text(render_vhdl(compact, image), encoding="ascii")
        mif_output.write_text(render_mif(compact, image), encoding="ascii")
        print(vhdl_output)
        print(mif_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
