"""Reassemble the guest instructions and verify their installed catalog entries."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from golden_sun import LAYOUTS, build_edits

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT.parents[1] / "standalone_host/fmv/guest_catalog.json"


# Offsets from the US build for the joint routine and its SDK calls.
FFIII_OFFSETS = {"AFFE": (0, 0), "AFFP": (0x9D0, 0x958), "AFFJ": (-0x338, -0x224)}
FFIII_MOVIE_WAIT = {"AFFE": 0x0206E828, "AFFP": 0x0206F2EC, "AFFJ": 0x0206E5F8}
FFIII_MOVIE_HEADROOM = {"AFFE": 0x0206E964, "AFFP": 0x0206F428, "AFFJ": 0x0206E734}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="arm-linux-gnueabihf-",
                        help="GNU binutils executable prefix")
    args = parser.parse_args()
    entries = json.loads(CATALOG.read_text())["entries"]

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        def tool(name, *arguments):
            return subprocess.check_output([args.prefix + name, *map(str, arguments)])

        def assemble(name, *link_options):
            obj, elf = work / (name + ".o"), work / name
            tool("as", "-march=armv5te", ROOT / (name + ".S"), "-o", obj)
            tool("ld", *link_options, "-T", ROOT / (name + ".ld"), obj, "-o", elf)
            return elf

        for code, (joint_delta, sdk_delta) in FFIII_OFFSETS.items():
            elf = assemble("ff_skin", "--defsym", f"joint_delta={joint_delta}",
                           "--defsym", f"sdk_delta={sdk_delta}")
            ff, = [e["manifest"] for e in entries if e["manifest"]["game_code"] == code and
                   e["manifest"]["revision"] == 0]
            assert {p["id"] for p in ff["patches"]} == {
                "joint-mix", "joint-request", "joint-weight", "joint-finish", "joint-final",
                "movie-audio-buffer-wait", "movie-audio-headroom"}
            assert ff["atomic_selection"]
            section_headers = tool("objdump", "-h", elf).decode()
            for patch in ff["patches"]:
                if patch["id"] == "movie-audio-buffer-wait":
                    assert int(patch["addr"], 0) == FFIII_MOVIE_WAIT[code]
                    assert patch["expect"] == "fbffff0a" and patch["replace"] == "f4ffff0a"
                    continue
                if patch["id"] == "movie-audio-headroom":
                    # Retain six frames of queued audio before taking the
                    # existing video-decode path. Heavy frames can exhaust the
                    # original three-frame reserve on the current FPGA build.
                    assert int(patch["addr"], 0) == FFIII_MOVIE_HEADROOM[code]
                    assert patch["expect"] == "0300a0e3" and patch["replace"] == "0600a0e3"
                    continue
                section = "." + patch["id"].removeprefix("joint-")
                row = re.search(r"^\s*\d+\s+" + re.escape(section) +
                                r"\s+\w+\s+(\w+)\s+", section_headers, re.MULTILINE)
                assert row and int(row[1], 16) == int(patch["addr"], 0)
                binary = work / "fragment"
                tool("objcopy", "-j", section, "-O", "binary", elf, binary)
                assert binary.read_bytes() == bytes.fromhex(patch["replace"])

        for code in LAYOUTS:
            manifest, = [item["manifest"] for item in entries if item["manifest"]["game_code"] == code
                         and item["manifest"]["revision"] == 0]
            recipe, = manifest["patches"]
            assert recipe["id"] == "opening-display" and len(recipe["title_model"]["hidden"]) == 82
            expected = [(edit["offset"], bytes.fromhex(edit["after"])) for edit in recipe["edits"]]
            assert build_edits(code, work / code, args.prefix) == expected
    print("Both RPG instruction profiles match the runtime catalog.")


if __name__ == "__main__":
    main()
