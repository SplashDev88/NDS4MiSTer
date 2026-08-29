#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-ipc-vhdl.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
ipc="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_ipc.vhd"

grep -Fq 'attribute ramstyle of fifo79 : signal is "MLAB";' "$ipc"
grep -Fq 'attribute ramstyle of fifo97 : signal is "MLAB";' "$ipc"
if sed -n '/attribute ramstyle of fifo79/,/signal cnt79/p' "$ipc" | grep -Fq no_rw_check; then
    echo "FAIL: IPC MLAB mapping discards read/write collision checking" >&2
    exit 1
fi

if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    nvc --std=2008 -a "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd"
    nvc --std=2008 -a "$ipc"
else
    docker run --rm \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd
            nvc --std=2008 -a /workspace/third_party/Nitro_DarkSide/d2dabe/rtl/nds_ipc.vhd
        '
fi

echo "PASS: NDS IPC payload FIFOs retain VHDL behavior with explicit MLAB mapping"
