#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-freebios-m10k.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

python3 "$script_dir/test_nitro_freebios_m10k.py" --write-vhdl-support "$test_tmp"

run_nvc_test() {
    cd "$test_tmp"
    nvc --std=2008 --work=altera_mf -a "$test_tmp/altera_mf_components.vhd"
    nvc --std=2008 -L . -a "$repo_dir/rtl/nds_nitro_freebios7.vhd"
    nvc --std=2008 -L . -a "$repo_dir/rtl/nds_nitro_freebios9.vhd"
    nvc --std=2008 -L . -a "$test_tmp/tb_nds_nitro_freebios_m10k.vhd"
    nvc --std=2008 -L . -e tb_nds_nitro_freebios_m10k
    nvc --std=2008 -L . -r tb_nds_nitro_freebios_m10k --exit-severity=error
}

if command -v nvc >/dev/null 2>&1; then
    run_nvc_test
else
    docker run --rm \
        -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" \
        -w /test \
        nds4mister-nvc-arm64:1.22.1 \
        sh -lc '
            set -eu
            nvc --std=2008 --work=altera_mf -a /test/altera_mf_components.vhd
            nvc --std=2008 -L . -a /workspace/rtl/nds_nitro_freebios7.vhd
            nvc --std=2008 -L . -a /workspace/rtl/nds_nitro_freebios9.vhd
            nvc --std=2008 -L . -a /test/tb_nds_nitro_freebios_m10k.vhd
            nvc --std=2008 -L . -e tb_nds_nitro_freebios_m10k
            nvc --std=2008 -L . -r tb_nds_nitro_freebios_m10k --exit-severity=error
        '
fi

echo "PASS: FreeBIOS M10K VHDL exhaustive and back-to-back equivalence"
