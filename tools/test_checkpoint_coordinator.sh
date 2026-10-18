#!/usr/bin/env bash
# Authored CPU-pair pause/abort proof; no console image or hardware deployment.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-pair.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash /repo/tools/test_checkpoint_coordinator.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
    "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" \
    "$repo/rtl/nds_checkpoint_endpoint.vhd" "$repo/rtl/nds_checkpoint_coordinator.vhd" \
    "$repo/rtl/tb_nds_checkpoint_coordinator.vhd"
for scenario in normal dma9 dma7 halt7 wfi9 no_branch9 early_cancel stuck_release stopped_clock; do
  for delay in 1 11; do
    for step in 1 5; do
      for phase in 0 7 41; do
        nvc --std=2008 -e -gSCENARIO="$scenario" -gREAD_DELAY="$delay" \
            -gSTEP_PERIOD="$step" -gREQUEST_PHASE="$phase" tb_nds_checkpoint_coordinator
        nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off --exit-severity=error
      done
    done
  done
done
echo 'PASS: 108 real CPU-pair barrier/cancel/timeout/CDC cases'
# If cancellation skips delivery acknowledgement, an old low level can make
# the controller rearm while the stopped endpoint has not seen the request.
sed 's/phase <= CANCEL_DELIVERY;/phase <= DRAIN;/g' \
    "$repo/rtl/nds_checkpoint_coordinator.vhd" > coordinator-negative.vhd
nvc --std=2008 -a coordinator-negative.vhd
nvc --std=2008 -a "$repo/rtl/tb_nds_checkpoint_coordinator.vhd"
nvc --std=2008 -e -gSCENARIO=stopped_clock tb_nds_checkpoint_coordinator
if nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off \
    --exit-severity=error > negative.log 2>&1; then
    echo 'FAIL: omitted delivery acknowledgement unexpectedly passed' >&2; exit 1
fi
grep -F 'stopped endpoint clock falsely reported release' negative.log
echo 'PASS: premature-rearm negative control'
