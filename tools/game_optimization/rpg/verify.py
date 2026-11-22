"""Reassemble the guest instructions and verify their installed catalog entries."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT.parents[1] / "standalone_host/fmv/guest_catalog.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="arm-linux-gnueabihf-",
                        help="GNU binutils executable prefix")
    args = parser.parse_args()
    entries = json.loads(CATALOG.read_text())["entries"]
    manifests = {item["manifest"]["game_code"]: item["manifest"] for item in entries}

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        def tool(name, *arguments):
            return subprocess.check_output([args.prefix + name, *map(str, arguments)])

        def assemble(name):
            obj, elf = work / (name + ".o"), work / name
            tool("as", "-march=armv5te", ROOT / (name + ".S"), "-o", obj)
            tool("ld", "-T", ROOT / (name + ".ld"), obj, "-o", elf)
            return elf

        elf = assemble("ff_skin")
        ff = manifests["AFFE"]
        assert ff["atomic_selection"]
        section_headers = tool("objdump", "-h", elf).decode()
        for patch in ff["patches"]:
            section = "." + patch["id"].removeprefix("joint-")
            row = re.search(r"^\s*\d+\s+" + re.escape(section) +
                            r"\s+\w+\s+(\w+)\s+", section_headers, re.MULTILINE)
            assert row and int(row[1], 16) == int(patch["addr"], 0)
            binary = work / "fragment"
            tool("objcopy", "-j", section, "-O", "binary", elf, binary)
            assert binary.read_bytes() == bytes.fromhex(patch["replace"])

        elf = assemble("scene_dma")
        symbols = {label: int(value, 16) for value, kind, label in
                   (line.split() for line in tool("nm", "-n", elf).decode().splitlines())}
        recipe = manifests["BO5E"]["patches"][0]
        body, hook, hud, reuse = recipe["edits"]
        binary = work / "display"
        tool("objcopy", "-O", "binary", elf, binary)
        assert symbols["primary"] == 0x02000000 + body["offset"]
        expected = bytes.fromhex(body["after"])
        assert binary.read_bytes().ljust(len(expected), b"\0") == expected
        delta = symbols["can_send_shape"] - 0x01FFA440 - 8
        assert delta % 2 == 0 and -(1 << 25) <= delta < (1 << 25)
        instruction = 0xFA000000 | ((delta & 2) << 23) | ((delta >> 2) & 0xFFFFFF)
        assert instruction.to_bytes(4, "little") == bytes.fromhex(hook["after"])

        elf = assemble("hud_dma")
        tool("objcopy", "-O", "binary", elf, binary)
        expected = bytes.fromhex(hud["after"])
        assert hud["offset"] == 0x528E8 and len(expected) == 0xE8
        assert binary.read_bytes().ljust(len(expected), b"\0") == expected
        symbols = tool("nm", "-n", elf).decode()
        assert "020528e8 T word_entry" in symbols and "0205295c T half_entry" in symbols
        elf = assemble("hud_reuse")
        tool("objcopy", "-O", "binary", elf, binary)
        assert reuse["offset"] == 0x31A0C
        assert binary.read_bytes().ljust(0x6C, b"\0") == bytes.fromhex(reuse["after"])
        symbols = tool("nm", "-n", elf).decode()
        assert "02031a0c T sdk_seek" in symbols and "02031a10 T hud_needs_upload" in symbols
        if "title_model" in recipe:
            assert len(recipe["title_model"]["hidden"]) == 82
    print("Both RPG instruction profiles match the runtime catalog.")


if __name__ == "__main__":
    main()
