#!/usr/bin/env python3
"""Verify an installable NDS4MiSTer ZIP before it is uploaded publicly."""

from __future__ import annotations

import argparse
import hashlib
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath


ROOT_FILES = {"LICENSE.txt", "README.txt", "SHA256SUMS"}
SUPPORT_FILES = {
    "Scripts/NDS_Kickstart.sh",
    "Scripts/NDS_Support/nds_hybrid_3d_service",
    "Scripts/NDS_Support/nds_hybrid_3d_service.sha256",
}
DIRECTORIES = {"_Console/", "Scripts/", "Scripts/NDS_Support/"}
CORE_PATTERN = re.compile(r"_Console/NDS_[0-9A-Za-z_.-]+\.rbf$")
FORBIDDEN_SUFFIXES = {
    ".3ds",
    ".bios",
    ".chd",
    ".cia",
    ".dsv",
    ".duc",
    ".heic",
    ".img",
    ".iso",
    ".key",
    ".mov",
    ".mp4",
    ".nds",
    ".nsp",
    ".p12",
    ".pem",
    ".pfx",
    ".rom",
    ".sav",
    ".srl",
    ".wad",
    ".xci",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def allowed_file(name: str) -> bool:
    return name in ROOT_FILES or name in SUPPORT_FILES or CORE_PATTERN.fullmatch(name) is not None


def content_problems(name: str, data: bytes) -> list[str]:
    problems: list[str] = []
    signatures = [
        ("absolute macOS home path", re.compile(b"/" + b"Users" + b"/[A-Za-z0-9._-]+/")),
        ("absolute Linux home path", re.compile(b"/" + b"home" + b"/[A-Za-z0-9._-]+/")),
        (
            "personal email address",
            re.compile(
                b"[A-Za-z0-9._%+-]+@"
                b"(gmail|yahoo|hotmail|outlook|icloud)\\.(com|net|org)",
                re.IGNORECASE,
            ),
        ),
        ("private-key header", re.compile(b"-----BEGIN " + b"([A-Z]+ )?" + b"PRIVATE" + b" KEY-----")),
        ("GitHub token", re.compile(b"gh" + b"[pousr]_[A-Za-z0-9]{20,}")),
        ("GitHub fine-grained token", re.compile(b"github" + b"_pat_[A-Za-z0-9_]{20,}")),
        ("AWS access key", re.compile(b"AK" + b"IA[0-9A-Z]{16}")),
    ]
    for label, pattern in signatures:
        if pattern.search(data):
            problems.append(label)
    return problems


def parse_manifest(data: bytes) -> dict[str, str]:
    entries: dict[str, str] = {}
    for raw_line in data.decode("utf-8", "strict").splitlines():
        if not raw_line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  \./(.+)", raw_line)
        if match is None:
            raise ValueError(f"invalid SHA256SUMS line: {raw_line!r}")
        digest, name = match.groups()
        entries[name] = digest
    return entries


def audit_zip(zip_path: Path, sidecar: Path | None) -> list[str]:
    failures: list[str] = []
    if not zip_path.is_file():
        return [f"release ZIP does not exist: {zip_path}"]

    if sidecar is not None:
        if not sidecar.is_file():
            failures.append(f"checksum sidecar does not exist: {sidecar}")
        else:
            fields = sidecar.read_text(encoding="utf-8").strip().split()
            if len(fields) != 2 or fields[1] != zip_path.name:
                failures.append("outer checksum sidecar has the wrong filename or format")
            elif fields[0] != sha256(zip_path.read_bytes()):
                failures.append("outer checksum does not match the release ZIP")

    try:
        archive = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as exc:
        return failures + [f"invalid ZIP: {exc}"]

    with archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            failures.append(f"CRC failure in {bad_member}")

        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            failures.append("ZIP contains duplicate paths")

        file_data: dict[str, bytes] = {}
        core_count = 0
        for info in infos:
            name = info.filename.replace("\\", "/")
            path = PurePosixPath(name.rstrip("/"))
            if name.startswith("/") or ".." in path.parts:
                failures.append(f"{name}: unsafe path")
                continue

            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                failures.append(f"{name}: symbolic links are forbidden")
                continue

            if info.is_dir():
                if name not in DIRECTORIES:
                    failures.append(f"{name}: unexpected directory")
                continue

            suffix = path.suffix.lower()
            if suffix in FORBIDDEN_SUFFIXES:
                failures.append(f"{name}: forbidden ROM/save/private extension")
            if not allowed_file(name):
                failures.append(f"{name}: unexpected release file")
            if CORE_PATTERN.fullmatch(name):
                core_count += 1
            if info.file_size > 16 * 1024 * 1024:
                failures.append(f"{name}: unexpectedly large release member")

            data = archive.read(info)
            file_data[name] = data
            for problem in content_problems(name, data):
                failures.append(f"{name}: {problem}")

        if core_count != 1:
            failures.append(f"expected exactly one dated NDS RBF, found {core_count}")
        for required in ROOT_FILES | SUPPORT_FILES:
            if required not in file_data:
                failures.append(f"missing required file: {required}")

        if "SHA256SUMS" in file_data:
            try:
                manifest = parse_manifest(file_data["SHA256SUMS"])
            except (UnicodeDecodeError, ValueError) as exc:
                failures.append(str(exc))
            else:
                expected_names = set(file_data) - {"SHA256SUMS"}
                if set(manifest) != expected_names:
                    failures.append("SHA256SUMS does not cover exactly every other release file")
                for name, expected in manifest.items():
                    if name in file_data and sha256(file_data[name]) != expected:
                        failures.append(f"SHA256SUMS mismatch: {name}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("zip", type=Path, help="installable public release ZIP")
    parser.add_argument("--sidecar", type=Path, help="optional outer .zip.sha256 file")
    args = parser.parse_args()
    failures = audit_zip(args.zip, args.sidecar)
    if failures:
        print("PUBLIC RELEASE AUDIT FAILED", file=sys.stderr)
        for failure in sorted(set(failures)):
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("PASS: public release ZIP audit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
