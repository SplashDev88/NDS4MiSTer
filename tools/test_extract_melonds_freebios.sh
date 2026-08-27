#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/nds-freebios.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

python3 "$script_dir/extract_melonds_freebios.py" "$test_dir"
(
    cd "$test_dir"
    shasum -a 256 -c SHA256SUMS
    test "$(stat -f %z boot1.rom)" = 16384
    test "$(stat -f %z boot2.rom)" = 4096
)

echo "PASS: audited melonDS FreeBIOS extraction"
