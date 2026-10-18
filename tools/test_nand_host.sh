#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/nds-nand-host.XXXXXX")
trap 'rm -rf "$out"' EXIT
docker run --rm --network none -v "$root:/workspace:ro" -v "$out:/test" -w /test nds4mister-nvc-arm64:1.22.1 sh -c '
set -e
c++ -std=c++17 -O2 -Wall -Wextra -Werror /workspace/tools/standalone_host/test_host_nand.cpp -o host-nand
./host-nand'
