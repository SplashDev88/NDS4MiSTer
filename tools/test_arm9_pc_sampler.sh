#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm --network none -v "$repo:/src:ro" -w /tmp nds4mister-nvc-icarus-fwtest:20261001 \
 bash -c 'iverilog -g2012 -s tb_nds_arm9_pc_sampler -o sampler /src/rtl/nds_arm9_pc_sampler.sv /src/rtl/tb_nds_arm9_pc_sampler.sv && vvp sampler'
