#!/usr/bin/env python3
"""Fail closed when a public NDS4MiSTer commit contains private artifacts."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import PurePosixPath


MAX_TRACKED_BYTES = 5 * 1024 * 1024

FORBIDDEN_SUFFIXES = {
    ".3ds",
    ".7z",
    ".a",
    ".avi",
    ".bin",
    ".chd",
    ".cia",
    ".dll",
    ".dsv",
    ".duc",
    ".dylib",
    ".elf",
    ".exe",
    ".heic",
    ".img",
    ".iso",
    ".jks",
    ".kdbx",
    ".key",
    ".mkv",
    ".mobileprovision",
    ".mov",
    ".mp4",
    ".nds",
    ".nsp",
    ".o",
    ".p12",
    ".pem",
    ".pfx",
    ".pof",
    ".qdb",
    ".qws",
    ".rar",
    ".rbf",
    ".rom",
    ".sav",
    ".so",
    ".sof",
    ".srl",
    ".tar",
    ".tgz",
    ".wad",
    ".xci",
    ".zip",
}

FORBIDDEN_BASENAMES = {
    ".env",
    ".netrc",
    "credentials.json",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_rsa",
}

FORBIDDEN_PARTS = {
    ".git-upstream",
    "artifacts",
    "db",
    "incremental_db",
    "output_files",
    "releases",
}

MEDIA_SUFFIXES = {".gif", ".ico", ".icns", ".jpeg", ".jpg", ".png", ".svg", ".webp"}
VENDORED_MEDIA_PREFIXES = (
    "third_party/melonds/res/",
    "third_party/melonds/src/frontend/qt_sdl/",
)
VENDORED_PCAP_PREFIX = "third_party/melonds/src/net/libslirp/fuzzing/"

ARCHIVE_OR_EXECUTABLE_MAGICS = (
    b"\x7fELF",
    b"MZ",
    b"PK\x03\x04",
    b"Rar!\x1a\x07",
    b"7z\xbc\xaf\x27\x1c",
    b"\x1f\x8b\x08",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
)


def git(*args: str, check: bool = True) -> bytes:
    result = subprocess.run(
        ["git", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        raise SystemExit(result.returncode)
    return result.stdout


def normalized(path: str) -> str:
    clean = path.replace("\\", "/")
    while clean.startswith("./"):
        clean = clean[2:]
    return clean


def path_problems(path: str, size: int | None = None) -> list[str]:
    clean = normalized(path)
    pure = PurePosixPath(clean)
    lower = clean.lower()
    suffix = pure.suffix.lower()
    problems: list[str] = []

    if not clean or clean.startswith("/") or ".." in pure.parts:
        problems.append("unsafe or non-relative path")
    if suffix in FORBIDDEN_SUFFIXES or lower.endswith(".tar.gz"):
        problems.append(f"forbidden public-source extension {suffix or lower}")
    if pure.name.lower() in FORBIDDEN_BASENAMES or pure.name.lower().startswith(".env."):
        problems.append("credential or environment filename")
    if any(part.lower() in FORBIDDEN_PARTS for part in pure.parts[:-1]):
        problems.append("generated/private directory")
    if suffix in MEDIA_SUFFIXES and not lower.startswith(VENDORED_MEDIA_PREFIXES):
        problems.append("image/media outside the audited vendored asset paths")
    if suffix == ".pcap" and not lower.startswith(VENDORED_PCAP_PREFIX.lower()):
        problems.append("packet capture outside the audited melonDS fixtures")
    if size is not None and size > MAX_TRACKED_BYTES:
        problems.append(f"file is larger than {MAX_TRACKED_BYTES // (1024 * 1024)} MiB")
    return problems


def secret_patterns() -> list[tuple[str, re.Pattern[bytes]]]:
    # Split sensitive signatures so this scanner does not flag its own source.
    private_key = b"-----BEGIN " + b"([A-Z]+ )?" + b"PRIVATE" + b" KEY-----"
    github_classic = b"gh" + b"[pousr]_[A-Za-z0-9]{20,}"
    github_fine = b"github" + b"_pat_[A-Za-z0-9_]{20,}"
    aws_access = b"AK" + b"IA[0-9A-Z]{16}"
    slack = b"xo" + b"x[baprs]-[A-Za-z0-9-]{10,}"
    return [
        ("private-key header", re.compile(private_key)),
        ("GitHub token", re.compile(github_classic)),
        ("GitHub fine-grained token", re.compile(github_fine)),
        ("AWS access key", re.compile(aws_access)),
        ("Slack token", re.compile(slack)),
    ]


def privacy_patterns() -> list[tuple[str, re.Pattern[bytes]]]:
    mac_home = b"/" + b"Users" + b"/[A-Za-z0-9._-]+/"
    linux_home = b"/" + b"home" + b"/[A-Za-z0-9._-]+/"
    windows_home = b"[A-Za-z]:" + b"\\\\Users\\\\[A-Za-z0-9._-]+\\\\"
    personal_email = (
        b"[A-Za-z0-9._%+-]+@"
        b"(gmail|yahoo|hotmail|outlook|icloud)\\.(com|net|org)"
    )
    return [
        ("absolute macOS home path", re.compile(mac_home)),
        ("absolute Linux home path", re.compile(linux_home)),
        ("absolute Windows home path", re.compile(windows_home, re.IGNORECASE)),
        ("personal email address", re.compile(personal_email, re.IGNORECASE)),
    ]


def content_problems(path: str, data: bytes) -> list[str]:
    problems: list[str] = []
    lower = normalized(path).lower()

    if any(data.startswith(magic) for magic in ARCHIVE_OR_EXECUTABLE_MAGICS):
        problems.append("archive or executable binary magic")

    for label, pattern in secret_patterns():
        if pattern.search(data):
            problems.append(label)

    # Vendored upstream sources legitimately retain contributor email addresses.
    if not lower.startswith("third_party/"):
        for label, pattern in privacy_patterns():
            if pattern.search(data):
                problems.append(label)
    return problems


def split_nul(data: bytes) -> list[str]:
    return [item.decode("utf-8", "surrogateescape") for item in data.split(b"\0") if item]


def audit_paths(paths: list[str], source: str) -> list[str]:
    failures: list[str] = []
    for path in sorted(set(paths)):
        if source == "staged":
            data = git("show", f":{path}", check=False)
        elif source == "tracked":
            data = git("show", f"HEAD:{path}", check=False)
        else:
            data = b""

        for problem in path_problems(path, len(data) if source != "history" else None):
            failures.append(f"{path}: {problem}")
        if source != "history":
            for problem in content_problems(path, data):
                failures.append(f"{path}: {problem}")
    return failures


def audit_staged() -> list[str]:
    paths = split_nul(git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"))
    return audit_paths(paths, "staged")


def audit_tracked() -> list[str]:
    if not git("rev-parse", "--verify", "HEAD", check=False):
        return []
    return audit_paths(split_nul(git("ls-tree", "-r", "--name-only", "-z", "HEAD")), "tracked")


def audit_history() -> list[str]:
    failures: list[str] = []
    commits = git("rev-list", "--all").decode().split()
    historical_paths: list[str] = []

    for commit in commits:
        historical_paths.extend(
            split_nul(git("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", commit))
        )
    failures.extend(audit_paths(historical_paths, "history"))

    identities = git("log", "--all", "--format=%H%x09%an%x09%ae%x09%cn%x09%ce").decode(
        "utf-8", "replace"
    )
    allowed_email = re.compile(r"(?:[0-9]+\+[^@]+@users\.noreply\.github\.com|noreply@github\.com)$")
    for line in identities.splitlines():
        fields = line.split("\t")
        if len(fields) != 5:
            failures.append("could not parse commit identity metadata")
            continue
        commit, _author_name, author_email, _committer_name, committer_email = fields
        if not allowed_email.fullmatch(author_email):
            failures.append(f"{commit[:12]}: author email is not a GitHub noreply address")
        if not allowed_email.fullmatch(committer_email):
            failures.append(f"{commit[:12]}: committer email is not a GitHub noreply address")

    # Scan every reachable first-party revision so deleting a secret in a later
    # commit cannot make the earlier public object look safe.
    for offset in range(0, len(commits), 100):
        batch = commits[offset : offset + 100]
        for label, pattern in secret_patterns() + privacy_patterns():
            result = subprocess.run(
                [
                    "git",
                    "grep",
                    "-I",
                    "-n",
                    "-E",
                    "-e",
                    pattern.pattern.decode("ascii"),
                    *batch,
                    "--",
                    ".",
                    ":(exclude)third_party/**",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode == 0:
                first = result.stdout.decode("utf-8", "replace").splitlines()[0]
                failures.append(f"history contains {label}: {first[:240]}")
            elif result.returncode not in (1,):
                failures.append(f"history scan failed for {label}")
    return failures


def self_test() -> list[str]:
    failures: list[str] = []

    def require_problem(label: str, problems: list[str]) -> None:
        if not problems:
            failures.append(f"self-test did not reject {label}")

    if path_problems("src/safe_source.cpp", 20):
        failures.append("self-test rejected a safe source path")
    require_problem("commercial ROM", path_problems("games/example.nds", 1024))
    require_problem("save file", path_problems("example.sav", 1024))
    require_problem("release archive", path_problems("release.zip", 1024))
    require_problem("oversized file", path_problems("src/large.txt", MAX_TRACKED_BYTES + 1))
    require_problem("renamed executable", content_problems("src/data.txt", b"\x7fELFdata"))
    require_problem(
        "developer home path",
        content_problems("docs/note.txt", b"path=" + b"/" + b"Users" + b"/private/work"),
    )
    require_problem(
        "personal email",
        content_problems("docs/note.txt", b"person" + b"@gmail.com"),
    )
    require_problem(
        "private key",
        content_problems("src/test.txt", b"-----BEGIN " + b"PRIVATE" + b" KEY-----"),
    )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--staged", action="store_true", help="audit the exact staged blobs")
    parser.add_argument("--tracked", action="store_true", help="audit the current HEAD tree")
    parser.add_argument("--history", action="store_true", help="audit all reachable public history")
    parser.add_argument("--self-test", action="store_true", help="exercise the fail-closed checks")
    args = parser.parse_args()
    if not any((args.staged, args.tracked, args.history, args.self_test)):
        parser.error("select at least one audit mode")

    failures: list[str] = []
    if args.self_test:
        failures.extend(self_test())
    if args.staged:
        failures.extend(audit_staged())
    if args.tracked:
        failures.extend(audit_tracked())
    if args.history:
        failures.extend(audit_history())

    if failures:
        print("PUBLIC SAFETY AUDIT FAILED", file=sys.stderr)
        for failure in sorted(set(failures)):
            print(f"  - {failure}", file=sys.stderr)
        print("Nothing was pushed. Remove the private/forbidden material and recommit.", file=sys.stderr)
        return 1

    print("PASS: public repository safety audit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
