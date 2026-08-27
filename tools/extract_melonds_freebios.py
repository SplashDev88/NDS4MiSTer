#!/usr/bin/env python3
"""Extract redistributable NTR FreeBIOS images from melonDS source."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shutil


HEADER_SHA256 = "898554cf7dc726c808b3ef48a88040899e1bf7573c6005f0184acb71f90567f0"
LICENSE_SHA256 = "ae30cfa598415a01657dcc7c49d639eb76ab1cf175f2de85457e49d26d25865a"

IMAGES = (
    (
        "bios_ntr_arm7",
        "boot1.rom",
        8240,
        16384,
        "a067b0e483fc16fbcb9294d6b7a1ac86f7dc41a4407654ec3bc554d0809ae76a",
    ),
    (
        "bios_ntr_arm9",
        "boot2.rom",
        1876,
        4096,
        "e10e164e7d82c83cbf763388d0c3c8fb33e48451c39cbe3a052e589aa645de74",
    ),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_array(text: str, name: str) -> bytes:
    array_match = re.search(
        rf"unsigned char\s+{re.escape(name)}\[\]\s*=\s*\{{(.*?)\}};",
        text,
        re.DOTALL,
    )
    length_match = re.search(
        rf"unsigned int\s+{re.escape(name)}_len\s*=\s*(\d+)\s*;", text
    )
    if array_match is None or length_match is None:
        raise SystemExit(f"missing checked-in FreeBIOS array: {name}")
    data = bytes(int(token, 16) for token in re.findall(r"0x([0-9A-Fa-f]{2})", array_match.group(1)))
    declared = int(length_match.group(1))
    if len(data) != declared:
        raise SystemExit(
            f"{name}: array has {len(data)} bytes, declared length is {declared}"
        )
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument(
        "--repo",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    args = parser.parse_args()

    header = args.repo / "third_party/melonDS/src/FreeBIOS_Data.h"
    license_file = args.repo / "third_party/melonDS/freebios/drastic_bios_readme.txt"
    header_bytes = header.read_bytes()
    license_bytes = license_file.read_bytes()
    if sha256(header_bytes) != HEADER_SHA256:
        raise SystemExit("FreeBIOS_Data.h does not match the audited melonDS source")
    if sha256(license_bytes) != LICENSE_SHA256:
        raise SystemExit("FreeBIOS license does not match the audited notice")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    text = header_bytes.decode("ascii")
    manifest: list[str] = []
    for array_name, output_name, raw_size, padded_size, expected_sha in IMAGES:
        raw = extract_array(text, array_name)
        if len(raw) != raw_size:
            raise SystemExit(f"{array_name}: unexpected raw size {len(raw)}")
        padded = raw + bytes(padded_size - len(raw))
        digest = sha256(padded)
        if digest != expected_sha:
            raise SystemExit(f"{array_name}: padded image hash mismatch")
        (args.output_dir / output_name).write_bytes(padded)
        manifest.append(f"{digest}  {output_name}\n")

    license_name = "LICENSE.FreeBIOS.txt"
    shutil.copyfile(license_file, args.output_dir / license_name)
    manifest.append(f"{LICENSE_SHA256}  {license_name}\n")
    (args.output_dir / "SHA256SUMS").write_text("".join(manifest), encoding="ascii")
    print(f"FreeBIOS extraction PASS: {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
