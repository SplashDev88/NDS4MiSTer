#!/usr/bin/env python3
"""Exhaustively verify the compact FreeBIOS M10K artifacts and test vectors."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import math
import pathlib
import re


HEADER_SHA256 = "898554cf7dc726c808b3ef48a88040899e1bf7573c6005f0184acb71f90567f0"


@dataclass(frozen=True)
class Spec:
    name: str
    stem: str
    address_name: str
    data_name: str
    image_bytes: int
    address_count: int
    image_sha256: str
    regions: tuple[tuple[int, int, int], ...]
    depth: int
    zero_row: int
    address_width: int


SPECS = (
    Spec(
        "bios_ntr_arm7",
        "nds_nitro_freebios7",
        "bios_addr",
        "bios_data",
        16384,
        4096,
        "a067b0e483fc16fbcb9294d6b7a1ac86f7dc41a4407654ec3bc554d0809ae76a",
        ((0, 7, 0), (1054, 2059, 8)),
        1015,
        1014,
        10,
    ),
    Spec(
        "bios_ntr_arm9",
        "nds_nitro_freebios9",
        "brom_addr",
        "brom_data",
        4096,
        8192,
        "e10e164e7d82c83cbf763388d0c3c8fb33e48451c39cbe3a052e589aa645de74",
        ((0, 468, 0),),
        470,
        469,
        9,
    ),
)


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def extract_array(text: str, name: str) -> bytes:
    match = re.search(
        rf"unsigned char\s+{re.escape(name)}\[\]\s*=\s*\{{(.*?)\}};",
        text,
        re.DOTALL,
    )
    if match is None:
        fail(f"missing audited array {name}")
    return bytes(int(token, 16) for token in re.findall(r"0x([0-9A-Fa-f]{2})", match.group(1)))


def source_words(header: str, spec: Spec) -> list[int]:
    raw = extract_array(header, spec.name)
    if len(raw) > spec.image_bytes:
        fail(f"{spec.name} exceeds its hashed image")
    image = raw + bytes(spec.image_bytes - len(raw))
    if hashlib.sha256(image).hexdigest() != spec.image_sha256:
        fail(f"{spec.name} padded image hash changed")
    words = [int.from_bytes(image[i : i + 4], "little") for i in range(0, len(image), 4)]
    return words + [0] * (spec.address_count - len(words))


def compact_address(address: int, spec: Spec) -> tuple[int, bool]:
    for first, last, compact_first in spec.regions:
        if first <= address <= last:
            return compact_first + address - first, True
    # Invalid addresses deliberately select a unique zero row, never truncated bits.
    return spec.zero_row, False


def expected_compact(words: list[int], spec: Spec) -> list[int]:
    compact = [0] * spec.depth
    for first, last, compact_first in spec.regions:
        compact[compact_first : compact_first + last - first + 1] = words[first : last + 1]
    return compact


def minimum_m10ks(depth: int, width: int = 32) -> int:
    # Cyclone-V M10K simple-port aspect ratios (depth, usable width).
    modes = ((8192, 1), (4096, 2), (2048, 5), (1024, 10), (512, 20), (256, 40))
    return min(math.ceil(depth / mode_depth) * math.ceil(width / mode_width) for mode_depth, mode_width in modes)


def parse_mif(path: pathlib.Path, spec: Spec) -> list[int]:
    text = path.read_text(encoding="ascii")
    depth_match = re.search(r"^DEPTH\s*=\s*(\d+);$", text, re.MULTILINE)
    if depth_match is None or int(depth_match.group(1)) != spec.depth:
        fail(f"{path.name} depth is not {spec.depth}")
    if not re.search(r"^WIDTH\s*=\s*32;$", text, re.MULTILINE):
        fail(f"{path.name} width is not 32")
    rows = [0] * spec.depth
    for address, data in re.findall(r"^\s*([0-9A-F]+)\s*:\s*([0-9A-F]{8});$", text, re.MULTILINE):
        index = int(address, 16)
        if index >= spec.depth:
            fail(f"{path.name} address {index} exceeds depth")
        rows[index] = int(data, 16)
    return rows


def parse_sim_rom(path: pathlib.Path, spec: Spec) -> list[int]:
    text = path.read_text(encoding="ascii")
    match = re.search(r"constant SIM_ROM\s*:.*?\:=\s*\((.*?)others =>", text, re.DOTALL)
    if match is None:
        fail(f"{path.name} lacks simulation ROM")
    rows = [0] * spec.depth
    for address, data in re.findall(r"(\d+)\s*=>\s*x\"([0-9A-F]{8})\"", match.group(1)):
        rows[int(address)] = int(data, 16)
    return rows


def check_vhdl(path: pathlib.Path, spec: Spec) -> None:
    text = path.read_text(encoding="ascii")
    required = (
        f"constant ZERO_ROW : natural := {spec.zero_row};",
        f"numwords_a => {spec.depth},",
        f"widthad_a => {spec.address_width},",
        'outdata_reg_a => "UNREGISTERED",',
        'operation_mode => "ROM",',
        'ram_block_type => "M10K",',
        f'init_file => "../../rtl/{spec.stem}.mif",',
        "rom_valid_q <= rom_valid;",
        f"{spec.data_name} <= rom_data when rom_valid_q = '1' else (others => '0');",
        "rom_addr <= std_logic_vector(to_unsigned(ZERO_ROW, rom_addr'length));",
        "clock0 => clk,",
    )
    for fragment in required:
        if fragment not in text:
            fail(f"{path.name} lacks contract fragment: {fragment}")
    if "address_reg_a" in text:
        fail(f"{path.name} uses the nonexistent Quartus-17 address_reg_a generic")
    if re.search(rf"{spec.data_name}\s*<=.*", text[text.find("process (clk)") : text.find("end process;")]):
        fail(f"{path.name} added an output register")


def check_assignments(repo: pathlib.Path, spec: Spec) -> None:
    assignment = f"set_global_assignment -name MIF_FILE ../../rtl/{spec.stem}.mif"
    for relative in (
        "fpga/mister_nitro_console_island/files.qip",
        "fpga/mister_nitro_console_island/NDS4MiSTer.qsf",
    ):
        if assignment not in (repo / relative).read_text(encoding="utf-8"):
            fail(f"{relative} does not package {spec.stem}.mif")


def vhdl_sparse_constant(name: str, words: list[int]) -> list[str]:
    lines = [
        f"   type {name.lower()}_type is array (0 to {len(words) - 1}) of std_logic_vector(31 downto 0);",
        f"   constant {name} : {name.lower()}_type := (",
    ]
    for address, word in enumerate(words):
        if word:
            lines.append(f'      {address} => x"{word:08X}",')
    lines.extend(["      others => (others => '0')", "   );"])
    return lines


def write_test_support(output_dir: pathlib.Path, all_words: dict[str, list[int]]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    package = """library ieee;
use ieee.std_logic_1164.all;

package altera_mf_components is
   component altsyncram is
      generic
      (
         clock_enable_input_a : string := "BYPASS";
         clock_enable_output_a : string := "BYPASS";
         init_file : string := " ";
         intended_device_family : string := "Cyclone V";
         lpm_hint : string := "UNUSED";
         lpm_type : string := "altsyncram";
         numwords_a : natural := 1;
         operation_mode : string := "ROM";
         outdata_aclr_a : string := "NONE";
         outdata_reg_a : string := "UNREGISTERED";
         power_up_uninitialized : string := "FALSE";
         ram_block_type : string := "AUTO";
         widthad_a : natural := 1;
         width_a : natural := 1;
         width_byteena_a : natural := 1
      );
      port
      (
         address_a : in std_logic_vector;
         clock0 : in std_logic;
         q_a : out std_logic_vector
      );
   end component;
end package;
"""
    (output_dir / "altera_mf_components.vhd").write_text(package, encoding="ascii")

    arm7 = all_words["bios_ntr_arm7"]
    arm9 = all_words["bios_ntr_arm9"]
    lines = [
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "use ieee.numeric_std.all;",
        "use std.env.all;",
        "",
        "entity tb_nds_nitro_freebios_m10k is end entity;",
        "",
        "architecture test of tb_nds_nitro_freebios_m10k is",
        "   signal clk : std_logic := '0';",
        "   signal addr7 : unsigned(13 downto 2) := (others => '0');",
        "   signal data7 : std_logic_vector(31 downto 0);",
        "   signal addr9 : unsigned(14 downto 2) := (others => '0');",
        "   signal data9 : std_logic_vector(31 downto 0);",
    ]
    lines.extend(vhdl_sparse_constant("REF7", arm7))
    lines.extend(vhdl_sparse_constant("REF9", arm9))
    lines.extend(
        [
            "   type address_vector is array (natural range <>) of natural;",
            "   constant SEQ7 : address_vector := (4095, 0, 1053, 1054, 7, 8, 2059, 2060, 1106, 2017, 0, 4095);",
            "   constant SEQ9 : address_vector := (8191, 0, 467, 468, 469, 1023, 4096, 8191, 1, 468, 0, 8191);",
            "begin",
            "   clk <= not clk after 5 ns;",
            "   dut7 : entity work.nds_nitro_freebios7",
            "      generic map (is_simu => '1')",
            "      port map (clk => clk, bios_addr => addr7, bios_data => data7);",
            "   dut9 : entity work.nds_nitro_freebios9",
            "      generic map (is_simu => '1')",
            "      port map (clk => clk, brom_addr => addr9, brom_data => data9);",
            "",
            "   process",
            "   begin",
            "      -- Every cycle accepts a new address; there are no bubbles between checks.",
            "      for address_value in REF7'range loop",
            "         addr7 <= to_unsigned(address_value, addr7'length);",
            "         wait until rising_edge(clk);",
            "         wait for 1 ns;",
            "         assert data7 = REF7(address_value)",
            "            report \"ARM7 exhaustive mismatch at \" & integer'image(address_value) severity failure;",
            "      end loop;",
            "      for address_value in SEQ7'range loop",
            "         addr7 <= to_unsigned(SEQ7(address_value), addr7'length);",
            "         wait until rising_edge(clk);",
            "         wait for 1 ns;",
            "         assert data7 = REF7(SEQ7(address_value))",
            "            report \"ARM7 back-to-back latency mismatch\" severity failure;",
            "      end loop;",
            "      for address_value in REF9'range loop",
            "         addr9 <= to_unsigned(address_value, addr9'length);",
            "         wait until rising_edge(clk);",
            "         wait for 1 ns;",
            "         assert data9 = REF9(address_value)",
            "            report \"ARM9 exhaustive mismatch at \" & integer'image(address_value) severity failure;",
            "      end loop;",
            "      for address_value in SEQ9'range loop",
            "         addr9 <= to_unsigned(SEQ9(address_value), addr9'length);",
            "         wait until rising_edge(clk);",
            "         wait for 1 ns;",
            "         assert data9 = REF9(SEQ9(address_value))",
            "            report \"ARM9 back-to-back latency mismatch\" severity failure;",
            "      end loop;",
            "      report \"PASS: exhaustive FreeBIOS M10K equivalence and one-cycle latency\" severity note;",
            "      stop;",
            "      wait;",
            "   end process;",
            "end architecture;",
            "",
        ]
    )
    (output_dir / "tb_nds_nitro_freebios_m10k.vhd").write_text("\n".join(lines), encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-vhdl-support", type=pathlib.Path)
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    header_path = repo / "third_party/melonDS/src/FreeBIOS_Data.h"
    header_bytes = header_path.read_bytes()
    if hashlib.sha256(header_bytes).hexdigest() != HEADER_SHA256:
        fail("FreeBIOS_Data.h audited hash changed")
    header = header_bytes.decode("ascii")
    all_words: dict[str, list[int]] = {}

    for spec in SPECS:
        words = source_words(header, spec)
        all_words[spec.name] = words
        compact = expected_compact(words, spec)
        mif_path = repo / "rtl" / f"{spec.stem}.mif"
        vhdl_path = repo / "rtl" / f"{spec.stem}.vhd"
        if parse_mif(mif_path, spec) != compact:
            fail(f"{mif_path.name} does not match the little-endian source")
        if parse_sim_rom(vhdl_path, spec) != compact:
            fail(f"{vhdl_path.name} simulation data differs from its MIF")
        if compact[spec.zero_row] != 0:
            fail(f"{spec.stem} sentinel row is not zero")
        check_vhdl(vhdl_path, spec)
        check_assignments(repo, spec)

        # Exhaustively prove every architectural word address.  Invalid words use
        # the sentinel and the delayed valid bit, never low-address truncation.
        for address in range(spec.address_count):
            row, valid = compact_address(address, spec)
            actual = compact[row] if valid else 0
            if actual != words[address]:
                fail(f"{spec.stem} address {address} differs: {actual:08X} != {words[address]:08X}")

    arm7_compact = expected_compact(all_words["bios_ntr_arm7"], SPECS[0])
    if arm7_compact[60] != 0 or arm7_compact[971] != 0:
        fail("ARM7 internal zero holes 1106/2017 were not preserved")
    if sum(minimum_m10ks(spec.depth) for spec in SPECS) != 6:
        fail("compact dimensions no longer target exactly six M10Ks")

    if args.write_vhdl_support is not None:
        write_test_support(args.write_vhdl_support, all_words)
    print("PASS: 4096 ARM7 + 8192 ARM9 addresses match the six-M10K compact artifacts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
