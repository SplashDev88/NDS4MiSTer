#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-gx-readback-adapter.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
iverilog -g2012 -Wall -s tb_nds_h3d_readback_legacy_adapter \
    -o "$test_tmp/test" "$repo_dir/rtl/nds_h3d_readback_legacy_adapter.sv" \
    "$repo_dir/rtl/tb_nds_h3d_readback_legacy_adapter.sv"
vvp "$test_tmp/test"
