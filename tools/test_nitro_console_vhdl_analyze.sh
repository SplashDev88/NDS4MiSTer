#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-console-analyze.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
altera_components="${ALTERA_MF_COMPONENTS:-$repo_dir/.tooling/quartus-17.0.2/quartus/eda/sim_lib/altera_mf_components.vhd}"
if [[ ! -f "$altera_components" ]]; then
    echo "Set ALTERA_MF_COMPONENTS to Quartus's altera_mf_components.vhd" >&2
    exit 2
fi
run_analyze() {
    local source_root="$1" file library
    ghdl -a --std=08 -frelaxed --work=altera_mf "$2"
    while read -r file library; do
        file="${file/\$nitro_rtl/$source_root/third_party/Nitro_DarkSide/d2dabe/rtl}"
        file="${file/..\/../$source_root}"
        if [[ "$file" == */nds_nitro_console_top.vhd ]]; then
            ghdl -a --std=08 -frelaxed "$source_root/rtl/nds_palette_readback.vhd"
            ghdl -a --std=08 -frelaxed "$source_root/rtl/nds_gpu2d_register_shadow.vhd"
        fi
        ghdl -a --std=08 -frelaxed --work="${library:-work}" "$file"
    done < <(awk '$3 == "VHDL_FILE" {print $4, ($5 == "-library" ? $6 : "work")}' \
        "$source_root/fpga/mister_nitro_console_island/files.qip")
    echo "PASS: complete console VHDL analysis, including Engine B policy input"
}
if command -v ghdl >/dev/null 2>&1; then
    cd "$test_tmp"
    run_analyze "$repo_dir" "$altera_components"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -v "$altera_components:/altera_mf_components.vhd:ro" \
        -w /test nds4mister-vhdl-sim:24.04 \
        bash -lc "set -eu; $(declare -f run_analyze); run_analyze /workspace /altera_mf_components.vhd"
fi
