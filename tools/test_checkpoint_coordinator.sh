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
    "$repo/rtl/nds_checkpoint_read_port.vhd" "$repo/rtl/nds_checkpoint_cpu_capture.vhd" \
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
for scenario in halt7 wfi9; do
  for delay in 1 11; do
    for step in 1 5; do
      for phase in 0 7 41; do
        nvc --std=2008 -e -gSCENARIO="$scenario" -gREAD_DELAY="$delay" \
            -gSTEP_PERIOD="$step" -gREQUEST_PHASE="$phase" -gHALT_PIPELINE=true tb_nds_checkpoint_coordinator
        nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off --exit-severity=error
      done
    done
  done
done
echo 'PASS: 24 additional CPU-pair holds with a sleeping CPU and pipeline coverage enabled'
for scenario in transport read_cancel read_stopped lease stale_keepalive stuck_keepalive read_lease common_reset; do
  for delay in 1 11; do
    for step in 1 5; do
      for phase in 0 7 41; do
        nvc --std=2008 -e -gSCENARIO="$scenario" -gREAD_DELAY="$delay" \
            -gSTEP_PERIOD="$step" -gREQUEST_PHASE="$phase" -gHALT_PIPELINE=true \
            -gUSE_CAPTURE=true tb_nds_checkpoint_coordinator
        nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off --exit-severity=error
      done
    done
  done
done
echo 'PASS: 96 real CPU capture-transport / cancellation / host-lease / reset cases'
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

# Stale host heartbeats must not extend a different attempt's hold.
sed 's/keepalive_epoch = epoch_i/true/g' "$repo/rtl/nds_checkpoint_coordinator.vhd" > lease-negative.vhd
nvc --std=2008 -a lease-negative.vhd "$repo/rtl/nds_checkpoint_cpu_capture.vhd" \
    "$repo/rtl/tb_nds_checkpoint_coordinator.vhd"
nvc --std=2008 -e -gSCENARIO=stale_keepalive -gUSE_CAPTURE=true -gHALT_PIPELINE=true tb_nds_checkpoint_coordinator
if nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off \
    --exit-severity=error > lease-negative.log 2>&1; then
    echo 'FAIL: stale keepalive epoch unexpectedly passed' >&2; exit 1
fi
grep -F 'lost host failed to expire CPU hold' lease-negative.log
# A timed-out read must finish its high request before rearming.
python3 - "$repo" <<'PYCODE'
import pathlib,sys
s=(pathlib.Path(sys.argv[1])/'rtl/nds_checkpoint_read_port.vhd').read_text()
pathlib.Path('reader-negative.vhd').write_text(s.replace('phase <= CANCEL_REPLY;', "request_i <= '0'; phase <= DRAIN;"))
PYCODE
nvc --std=2008 -a "$repo/rtl/nds_checkpoint_coordinator.vhd" reader-negative.vhd \
    "$repo/rtl/nds_checkpoint_cpu_capture.vhd" "$repo/rtl/tb_nds_checkpoint_coordinator.vhd"
nvc --std=2008 -e -gSCENARIO=read_stopped -gUSE_CAPTURE=true -gHALT_PIPELINE=true tb_nds_checkpoint_coordinator
if nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off \
    --exit-severity=error > reader-negative.log 2>&1; then
    echo 'FAIL: premature read rearm unexpectedly passed' >&2; exit 1
fi
grep -F 'stopped read falsely rearmed' reader-negative.log
echo 'PASS: stale-keepalive and late-read negative controls'
