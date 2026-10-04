#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-vram-cd-mirrors.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
source_file="$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd"
if [[ -n "${SOURCE_REVISION:-}" ]]; then
    git -C "$repo_dir" show "$SOURCE_REVISION:third_party/Nitro_DarkSide/d2dabe/rtl/nds_vram_map.vhd" > "$test_tmp/source.vhd"
else
    cp "$source_file" "$test_tmp/source.vhd"
fi
cp "$repo_dir/rtl/tb_nds_vram_cd_mirrors.vhd" "$test_tmp/test.vhd"
run_tests() {
    ghdl -a --std=08 source.vhd test.vhd
    ghdl -e --std=08 tb_nds_vram_cd_mirrors
    ghdl -r --std=08 tb_nds_vram_cd_mirrors --assert-level=error
}
if command -v ghdl >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests
else
    docker run --rm --network none -v "$test_tmp:/test" -w /test \
        nds4mister-vhdl-sim:24.04 bash -lc "set -eu; $(declare -f run_tests); run_tests"
fi
