#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-fw-boot-core.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
altera_components=${ALTERA_MF_COMPONENTS:-$repo_dir/.tooling/quartus-17.0.2/quartus/eda/sim_lib/altera_mf_components.vhd}
if [[ ! -f "$altera_components" ]]; then
    echo 'Set ALTERA_MF_COMPONENTS to Quartus altera_mf_components.vhd' >&2
    exit 2
fi

python3 - "$repo_dir" <<'PY'
import pathlib, sys
repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / 'tools'))
from generate_nitro_bootbios import outputs
for path, content in outputs(repo).items():
    assert path.read_text() == content, f'stale generated BIOS artifact: {path}'
print('PASS: full-size BIOS artifacts match audited public FreeBIOS source')
PY

run_tests() {
    local root=$1 components=$2 out=$3
    cd "$out"
    nvc --std=2008 --work=altera_mf -a "$components"
    nvc --std=2008 -L . -a \
        "$root/rtl/nds_nitro_freebios7.vhd" "$root/rtl/nds_nitro_freebios9.vhd" \
        "$root/rtl/nds_nitro_bootbios7.vhd" "$root/rtl/nds_nitro_bootbios9.vhd" \
        "$root/rtl/tb_nds_nitro_bootbios.vhd"
    nvc --std=2008 -L . -e tb_nds_nitro_bootbios
    nvc --std=2008 -L . -r tb_nds_nitro_bootbios --exit-severity=error
    nvc --std=2008 -a \
        "$root/third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd" \
        "$root/rtl/tb_nds_firmware_loader.vhd" \
        "$root/rtl/tb_nds_loader_touch_calibration.vhd"
    for scenario in 0 1 2 3; do
        nvc --std=2008 -e -gscenario="$scenario" tb_nds_firmware_loader
        nvc --std=2008 -r tb_nds_firmware_loader --exit-severity=error
    done
    nvc --std=2008 -e tb_nds_loader_touch_calibration
    nvc --std=2008 -r tb_nds_loader_touch_calibration --exit-severity=error
    local p="$root/third_party/Nitro_DarkSide/d2dabe/rtl"
    nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
        "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" \
        "$root/rtl/tb_nds_cpu9_cold_reset.vhd"
    nvc --std=2008 -e tb_nds_cpu9_cold_reset
    nvc --std=2008 -r tb_nds_cpu9_cold_reset --ieee-warnings=off --exit-severity=error
    nvc --std=2008 -a "$p/nds_syscnt.vhd" "$root/rtl/tb_nds_syscnt_cold_reset.vhd"
    nvc --std=2008 -e tb_nds_syscnt_cold_reset
    nvc --std=2008 -r tb_nds_syscnt_cold_reset --ieee-warnings=off --exit-severity=error
}
if command -v nvc >/dev/null 2>&1; then
    run_tests "$repo_dir" "$altera_components" "$test_tmp"
else
    docker run --rm --network none -v "$repo_dir:/repo:ro" \
        -v "$test_tmp:/test" -v "$altera_components:/altera_mf_components.vhd:ro" \
        -w /test nds4mister-nvc-arm64:1.22.1 /bin/bash -euo pipefail -c \
        "$(declare -f run_tests); run_tests /repo /altera_mf_components.vhd /test"
fi
