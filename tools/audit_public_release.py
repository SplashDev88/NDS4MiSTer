#!/usr/bin/env python3
"""Verify an installable NDS4MiSTer ZIP before it is uploaded publicly."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

import package_standalone_release as standalone

SOURCE_ROOT = Path(__file__).resolve().parents[1]
STANDALONE_PREFIX = standalone.SUPPORT
STANDALONE_DOCS = {"LICENSE.txt", "README.md", "RELEASE_NOTES.md", "QUICK_START.txt"}

ROOT_FILES = {"LICENSE.txt", "README.txt", "SHA256SUMS"}
SUPPORT_FILES = {
    "Scripts/NDS_Kickstart.sh",
    "Scripts/NDS_Support/nds_hybrid_3d_service",
    "Scripts/NDS_Support/nds_hybrid_3d_service.sha256",
}
WC_FILES = {
    "Scripts/NDS_Support/nds_mem_wc.ko",
    "Scripts/NDS_Support/nds_mem_wc.ko.sha256",
    "WC_MODULE_LICENSE.txt",
    "WC_MODULE_SOURCE.txt",
}
DIRECTORIES = {"_Console/", "Scripts/", "Scripts/NDS_Support/"}
CORE_PATTERN = re.compile(r"_Console/NDS_[0-9A-Za-z_.-]+\.rbf$")
FORBIDDEN_SUFFIXES = {
    ".3ds",
    ".bios",
    ".chd",
    ".bin",
    ".cfg",
    ".cia",
    ".dsv",
    ".duc",
    ".heic",
    ".img",
    ".ini",
    ".iso",
    ".key",
    ".mov",
    ".map",
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
    return name in ROOT_FILES | SUPPORT_FILES | WC_FILES or CORE_PATTERN.fullmatch(name) is not None


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


def safe_name(name: str) -> bool:
    return (bool(name) and "\\" not in name and ":" not in name
            and not name.startswith("/")
            and all(part not in ("", ".", "..") for part in name.split("/")))


def parse_manifest(data: bytes, prefix: str = "./") -> dict[str, str]:
    entries: dict[str, str] = {}
    for raw_line in data.decode("utf-8", "strict").splitlines():
        if not raw_line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  " + re.escape(prefix) + r"(.+)", raw_line)
        if match is None:
            raise ValueError(f"invalid SHA256SUMS line: {raw_line!r}")
        digest, name = match.groups()
        if not safe_name(name) or name in entries:
            raise ValueError(f"duplicate/unsafe SHA256SUMS path: {name!r}")
        entries[name] = digest
    return entries


def standalone_contract():
    """Read the public packager and runtime source; never execute the supervisor."""
    host = SOURCE_ROOT / "tools/standalone_host"
    tree = ast.parse((host / "supervisor.py").read_text())
    constants = {
        node.targets[0].id: ast.literal_eval(node.value)
        for node in tree.body if isinstance(node, ast.Assign)
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id.startswith("EXPECTED_")
    }
    source_files = {
        "Scripts/NDS4MiSTer.sh": host / "NDS4MiSTer.sh",
        STANDALONE_PREFIX + "supervisor.py": host / "supervisor.py",
        STANDALONE_PREFIX + "Kickstart.sh": host / "Kickstart.sh",
        STANDALONE_PREFIX + "clock_control.py": host / "clock_control.py",
        STANDALONE_PREFIX + "support/modules/6.18.38-MiSTer/BUILD_PROVENANCE.json":
            SOURCE_ROOT / "kernel/nds_mem_wc/BUILD_PROVENANCE-6.18.38.json",
        "LICENSE.txt": SOURCE_ROOT / "LICENSE.txt",
    }
    source_files.update({STANDALONE_PREFIX + "licenses/" + name: SOURCE_ROOT / path
                         for name, path in standalone.LICENSES.items()})
    source_files.update({STANDALONE_PREFIX + "licenses/runtime/" + name:
                         SOURCE_ROOT / "licenses/runtime" / name
                         for name in standalone.RUNTIME_LICENSES})
    hashes = {name: sha256(path.read_bytes()) for name, path in source_files.items()}
    hashes.update({STANDALONE_PREFIX + name: digest for name, digest in {
        "NDS_Standalone.rbf": constants["EXPECTED_CORE"],
        "nds_standalone_host": standalone.HOST_SHA,
        "support/nds_hybrid_3d_service": constants["EXPECTED_HELPER"],
        "support/nds_mem_wc.ko": constants["EXPECTED_WC"],
        "support/modules/6.18.38-MiSTer/nds_mem_wc.ko": constants["EXPECTED_WC_618"],
    }.items()})
    if hashes[STANDALONE_PREFIX + "Kickstart.sh"] != constants["EXPECTED_KICKSTART"]:
        raise ValueError("public source Kickstart does not match supervisor pin")
    if hashes[STANDALONE_PREFIX + "clock_control.py"] != constants["EXPECTED_CLOCK"]:
        raise ValueError("public source clock control does not match supervisor pin")
    return hashes, constants["EXPECTED_SPEED_ENV"]


def strict_json(data: bytes):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(data.decode("utf-8", "strict"), object_pairs_hook=unique)


def audit_standalone(file_data, hashes, environment):
    failures = []
    support = STANDALONE_PREFIX
    manifest_name = support + "manifest.json"
    provenance_name = support + "BUILD_PROVENANCE.json"
    sums_name = support + "SHA256SUMS"
    for name, expected in hashes.items():
        if name in file_data and sha256(file_data[name]) != expected:
            failures.append("approved standalone input mismatch: " + name)
    for name in ("nds_hybrid_3d_service", "nds_mem_wc.ko",
                 "modules/6.18.38-MiSTer/nds_mem_wc.ko"):
        path = support + "support/" + name
        if path in file_data and file_data.get(path + ".sha256") != (
                sha256(file_data[path]) + "  " + PurePosixPath(name).name + "\n").encode():
            failures.append("standalone component checksum mismatch: " + name)
    if sums_name in file_data:
        try:
            manifest = parse_manifest(file_data[sums_name], "")
        except (UnicodeDecodeError, ValueError) as exc:
            failures.append(str(exc))
        else:
            expected = {name[len(support):] for name in file_data
                        if name.startswith(support) and name != sums_name}
            if set(manifest) != expected:
                failures.append("standalone SHA256SUMS does not cover exactly every support file")
            for name, digest in manifest.items():
                if support + name in file_data and sha256(file_data[support + name]) != digest:
                    failures.append("standalone SHA256SUMS mismatch: " + name)
    try:
        manifest = strict_json(file_data.get(manifest_name, b"{}"))
        provenance = strict_json(file_data.get(provenance_name, b"{}"))
        if not isinstance(manifest, dict) or not isinstance(provenance, dict):
            raise ValueError("standalone metadata must be JSON objects")
        revision = manifest.get("source_revision", "")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise ValueError("standalone source_revision must be a full commit hash")
        expected_manifest = {
            "name": "NDS4MiSTer", "version": standalone.VERSION, "source_revision": revision,
            "source_tag": standalone.VERSION, "runtime_baseline": "standalone-fw1-20261003",
            "host_change": "Linux 6.18.38 compatibility and release version label; gameplay renderer and FPGA unchanged.",
            "runtime_environment": environment, "hps_clock_khz": 1000000,
            "remote_kit": "/media/fat/Scripts/.NDS_Standalone", "rom_directory": "/media/fat/games/NDS",
            "shared_saves": "/media/fat/saves/NDS", "firmware_working_image": "/media/fat/saves/NDS/firmware.bin",
            "user_dumps_included": False, "user_settings_included": False,
            "diagnostic_revision": "native-pc9-memctl-v1",
            "fpga_source_manifest_sha256": standalone.FPGA_SOURCE_SHA,
            "frontend_build_sha256": standalone.FRONTEND_BUILD_SHA,
        }
        for key, name in {
            "host_sha256": "nds_standalone_host", "core_sha256": "NDS_Standalone.rbf",
            "helper_sha256": "support/nds_hybrid_3d_service", "module_sha256": "support/nds_mem_wc.ko",
            "kickstart_sha256": "Kickstart.sh", "supervisor_sha256": "supervisor.py",
            "clock_control_sha256": "clock_control.py",
        }.items():
            expected_manifest[key] = hashes[support + name]
        expected_manifest["kernel_module_sha256"] = {
            "5.15.1-MiSTer": hashes[support + "support/nds_mem_wc.ko"],
            "6.18.38-MiSTer": hashes[support + "support/modules/6.18.38-MiSTer/nds_mem_wc.ko"],
        }
        expected_manifest["launcher_sha256"] = hashes["Scripts/NDS4MiSTer.sh"]
        expected_provenance = {
            "release": standalone.VERSION, "source_revision": revision,
            "fpga_build_sha256": standalone.FPGA_BUILD_SHA,
            "fpga_source_manifest_sha256": standalone.FPGA_SOURCE_SHA,
            "accepted_host_sha256": standalone.ACCEPTED_HOST_SHA,
            "frontend_build_sha256": standalone.FRONTEND_BUILD_SHA,
            "release_host_sha256": hashes[support + "nds_standalone_host"],
            "runtime_input_receipt_sha256": standalone.RUNTIME_INPUT_SHA,
            "scope": "Linux 6.18.38 compatibility port on rc.2: rebuilt WC module and boost-aware 1 GHz clock setup; accepted FPGA, renderer and runtime speed options unchanged; host release label updated.",
        }
        if json.dumps(manifest, sort_keys=True) != json.dumps(expected_manifest, sort_keys=True):
            failures.append("standalone manifest fields do not match approved runtime/source contract")
        if json.dumps(provenance, sort_keys=True) != json.dumps(expected_provenance, sort_keys=True):
            failures.append("standalone BUILD_PROVENANCE fields do not match approved contract")
    except (UnicodeDecodeError, ValueError) as exc:
        failures.append(str(exc))
    return failures


def audit_zip(zip_path: Path, sidecar: Path | None, layout: str = "auto") -> list[str]:
    failures: list[str] = []
    if not zip_path.is_file() or zip_path.is_symlink():
        return [f"release ZIP does not exist: {zip_path}"]

    if sidecar is not None:
        if not sidecar.is_file() or sidecar.is_symlink():
            failures.append(f"checksum sidecar does not exist: {sidecar}")
        else:
            try:
                fields = sidecar.read_text(encoding="utf-8").strip().split()
            except (OSError, UnicodeDecodeError):
                fields = []
            if len(fields) != 2 or fields[1] != zip_path.name:
                failures.append("outer checksum sidecar has the wrong filename or format")
            elif fields[0] != sha256(zip_path.read_bytes()):
                failures.append("outer checksum does not match the release ZIP")

    try:
        archive = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as exc:
        return failures + [f"invalid ZIP: {exc}"]

    with archive:
        if any(info.file_size > 16 * 1024 * 1024 for info in archive.infolist()):
            return failures + ["unexpectedly large release member"]
        try:
            bad_member = archive.testzip()
        except (OSError, RuntimeError, zipfile.BadZipFile, NotImplementedError) as exc:
            return failures + [f"unreadable ZIP: {exc}"]
        if bad_member is not None:
            failures.append(f"CRC failure in {bad_member}")

        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            failures.append("ZIP contains duplicate paths")
        if layout == "auto":
            layout = "standalone" if any(name.startswith(STANDALONE_PREFIX)
                or name == "Scripts/NDS4MiSTer.sh" for name in names) else "normal"
        hashes, environment = {}, {}
        required = ROOT_FILES | SUPPORT_FILES
        directories = DIRECTORIES
        if layout == "standalone":
            if sidecar is None:
                failures.append("standalone audit requires the outer checksum sidecar")
            try:
                hashes, environment = standalone_contract()
            except (OSError, ValueError, KeyError) as exc:
                return failures + [f"cannot read public standalone contract: {exc}"]
            required = set(hashes) | STANDALONE_DOCS | {
                STANDALONE_PREFIX + name for name in (
                    "manifest.json", "BUILD_PROVENANCE.json", "SHA256SUMS",
                    "support/nds_hybrid_3d_service.sha256", "support/nds_mem_wc.ko.sha256",
                    "support/modules/6.18.38-MiSTer/nds_mem_wc.ko.sha256")}
            directories = {str(parent) + "/" for name in required
                           for parent in PurePosixPath(name).parents if str(parent) != "."}

        file_data: dict[str, bytes] = {}
        core_count = 0
        for info in infos:
            name = info.filename
            path = PurePosixPath(name.rstrip("/"))
            if not safe_name(name[:-1] if info.is_dir() else name):
                failures.append(f"{name}: unsafe path")
                continue

            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                failures.append(f"{name}: symbolic links are forbidden")
                continue
            if mode not in (0, stat.S_IFREG, stat.S_IFDIR) or (mode == stat.S_IFDIR and not info.is_dir()):
                failures.append(f"{name}: nonregular ZIP member")
                continue

            if info.is_dir():
                if name not in directories:
                    failures.append(f"{name}: unexpected directory")
                continue

            suffix = path.suffix.lower()
            if suffix in FORBIDDEN_SUFFIXES:
                failures.append(f"{name}: forbidden ROM/save/private extension")
            if not (name in required if layout == "standalone" else allowed_file(name)):
                failures.append(f"{name}: unexpected release file")
            if CORE_PATTERN.fullmatch(name):
                core_count += 1
            if info.file_size > 16 * 1024 * 1024:
                failures.append(f"{name}: unexpectedly large release member")
                continue
            if layout == "standalone":
                executable = name in {"Scripts/NDS4MiSTer.sh", STANDALONE_PREFIX + "supervisor.py",
                    STANDALONE_PREFIX + "Kickstart.sh", STANDALONE_PREFIX + "clock_control.py",
                    STANDALONE_PREFIX + "nds_standalone_host",
                    STANDALONE_PREFIX + "support/nds_hybrid_3d_service"}
                expected_mode = stat.S_IFREG | (0o755 if executable else 0o644)
                if info.create_system != 3 or (info.external_attr >> 16) != expected_mode:
                    failures.append(f"{name}: incorrect standalone file mode")

            data = archive.read(info)
            file_data[name] = data
            for problem in content_problems(name, data):
                failures.append(f"{name}: {problem}")

        if layout == "normal" and core_count != 1:
            failures.append(f"expected exactly one dated NDS RBF, found {core_count}")
        for name in required:
            if name not in file_data:
                failures.append(f"missing required file: {name}")
        if layout == "standalone":
            return failures + audit_standalone(file_data, hashes, environment)

        # The optional WC payload is an indivisible module/hash/license/source
        # set. Older installers without WC remain valid.
        if WC_FILES & file_data.keys():
            for required in WC_FILES - file_data.keys():
                failures.append(f"incomplete WC payload: missing {required}")
            module_name = "Scripts/NDS_Support/nds_mem_wc.ko"
            module = file_data.get(module_name)
            module_hash = file_data.get(module_name + ".sha256")
            if module is not None:
                # ELF32, little-endian, relocatable, EM_ARM.
                if (len(module) < 52 or module[:7] != b"\x7fELF\x01\x01\x01"
                        or module[16:20] != b"\x01\x00\x28\x00"):
                    failures.append("WC module is not a 32-bit ARM relocatable ELF")
                if b"vermagic=5.15.1-MiSTer SMP mod_unload ARMv7 p2v8 \0" not in module:
                    failures.append("WC module vermagic does not match the qualified kernel")
                if module_hash is not None and module_hash != (
                        sha256(module) + "  nds_mem_wc.ko\n").encode("ascii"):
                    failures.append("WC module checksum manifest does not match")
            license_text = file_data.get("WC_MODULE_LICENSE.txt", b"")
            if license_text and (b"GNU GENERAL PUBLIC LICENSE" not in license_text
                                 or b"Version 2, June 1991" not in license_text):
                failures.append("WC module license is not GPL version 2")

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
    parser.add_argument("--sidecar", type=Path, help="outer .zip.sha256 file (required for standalone)")
    parser.add_argument("--layout", choices=("auto", "normal", "standalone"), default="auto",
                        help="auto-detect, or require one installation layout (standalone requires sidecar)")
    args = parser.parse_args()
    failures = audit_zip(args.zip, args.sidecar, args.layout)
    if failures:
        print("PUBLIC RELEASE AUDIT FAILED", file=sys.stderr)
        for failure in sorted(set(failures)):
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("PASS: public release ZIP audit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
