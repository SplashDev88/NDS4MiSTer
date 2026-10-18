#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
 test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint-owners.XXXXXX")
 trap 'rm -rf "$test_tmp"' EXIT
 docker run --rm --network none -v "$repo:/repo:ro" -v "$test_tmp:/test" -w /test \
  nds4mister-nvc-arm64:1.22.1 bash /repo/tools/test_checkpoint_owners.sh --inside
 exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" \
 "$repo/rtl/nds_checkpoint_endpoint.vhd" "$repo/rtl/nds_checkpoint_coordinator.vhd" \
 "$repo/rtl/nds_checkpoint_read_port.vhd" "$repo/rtl/nds_checkpoint_cpu_capture.vhd" \
 "$repo/rtl/nds_checkpoint_console_guard.vhd" "$repo/rtl/nds_nitro_rtc.vhd" \
 "$repo/rtl/tb_nds_checkpoint_coordinator.vhd" "$repo/rtl/tb_nds_checkpoint_console_guard.vhd"
for scenario in transport owner_timeout owner_delivery owner_release owner_loss owner_seen_loss lease read_cancel read_stopped read_lease common_reset; do
 for delay in 1 11; do
  for phase in 0 41; do
   nvc --std=2008 -e -gSCENARIO="$scenario" -gREAD_DELAY="$delay" -gREQUEST_PHASE="$phase" \
    -gSTEP_PERIOD=5 -gHALT_PIPELINE=true -gUSE_CAPTURE=true -gOWNER_MODE=true tb_nds_checkpoint_coordinator
   nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off --exit-severity=error
  done
 done
done
# Join both real CPUs, the final-stage guard and the live RTC in one capture
# path. External host/storage owners remain synthetic receipts in this proof.
for scenario in transport owner_timeout owner_loss lease; do
 for delay in 1 11; do
  nvc --std=2008 -e -gSCENARIO="$scenario" -gREAD_DELAY="$delay" -gREQUEST_PHASE=41 \
   -gSTEP_PERIOD=5 -gHALT_PIPELINE=true -gUSE_CAPTURE=true -gOWNER_MODE=true -gRTC_GUARD=true tb_nds_checkpoint_coordinator
  nvc --std=2008 -r tb_nds_checkpoint_coordinator --ieee-warnings=off --exit-severity=error
 done
done
nvc --std=2008 -e tb_nds_checkpoint_console_guard
nvc --std=2008 -r tb_nds_checkpoint_console_guard --ieee-warnings=off --exit-severity=error
python3 - "$repo/rtl" <<'PYCODE'
from pathlib import Path
import sys
r=Path(sys.argv[1]);s=(r/'nds_checkpoint_coordinator.vhd').read_text()
old='seen_sync = ALL_HIGH then';assert s.count(old)==2
# Drop only additional delivery receipts in cancellation cleanup, retaining
# the CPU high phase. This must expose premature rearm while host delivery lags.
needle='''when CANCEL_DELIVERY =>''';first,tail=s.split(needle)
tail=tail.replace('seen_sync = ALL_HIGH then','seen_sync(1 downto 0) = "11" then',1)
Path('early-release.vhd').write_text(first+needle+tail)
Path('lost-receipt.vhd').write_text(s.replace(' or seen_sync /= ALL_HIGH then',' then'))
s=(r/'nds_checkpoint_cpu_capture.vhd').read_text()
Path('reopened-permit.vhd').write_text(s.replace('and not owner_violation and','and'))
old='permit <= held and not reset and not owner_violation and owners_paused(0) and owners_paused(1) and\n    owners_seen(0) and owners_seen(1) when REQUIRE_OWNERS else held and not reset;';assert s.count(old)==1
# Losing the same-cycle guard must expose a stale in-flight read before the
# synchronized owner loss reaches the coordinator.
Path('stale-permit.vhd').write_text(s.replace(old,'permit <= held and not reset;'))
s=(r/'nds_checkpoint_console_guard.vhd').read_text();old='eligible <= hold and cpus_observed and local_idle and external_seen and external_paused;';assert s.count(old)==1
Path('early-rtc.vhd').write_text(s.replace(old,'eligible <= hold;'))
PYCODE
for mutation in early-release stale-permit reopened-permit lost-receipt early-rtc; do
 coordinator="$repo/rtl/nds_checkpoint_coordinator.vhd"
 capture="$repo/rtl/nds_checkpoint_cpu_capture.vhd"
 guard="$repo/rtl/nds_checkpoint_console_guard.vhd"
 case $mutation in
  early-release|lost-receipt) coordinator="/test/$mutation.vhd" ;;
  stale-permit|reopened-permit) capture="/test/$mutation.vhd" ;;
  early-rtc) guard="/test/$mutation.vhd" ;;
 esac
 # Separate libraries prevent replacement units invalidating old dependency
 # closures during mutation elaboration. Compile the tested variant once.
 mkdir "negative-$mutation"
 pushd "negative-$mutation" >/dev/null
 nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" \
  "$repo/rtl/nds_checkpoint_endpoint.vhd" "$coordinator" "$repo/rtl/nds_checkpoint_read_port.vhd" "$capture" \
  "$guard" "$repo/rtl/nds_nitro_rtc.vhd" "$repo/rtl/tb_nds_checkpoint_coordinator.vhd" "$repo/rtl/tb_nds_checkpoint_console_guard.vhd"
 if [[ $mutation == early-rtc ]]; then
  top=tb_nds_checkpoint_console_guard
  nvc --std=2008 -e "$top"
 else
  top=tb_nds_checkpoint_coordinator;scenario=owner_loss
  if [[ $mutation == early-release ]]; then scenario=owner_delivery;fi
  if [[ $mutation == lost-receipt ]]; then scenario=owner_seen_loss;fi
  nvc --std=2008 -e -gSCENARIO="$scenario" -gHALT_PIPELINE=true -gUSE_CAPTURE=true -gOWNER_MODE=true "$top"
 fi
 if nvc --std=2008 -r "$top" --ieee-warnings=off --exit-severity=error > "$mutation.log" 2>&1; then
  echo "FAIL: $mutation negative control passed" >&2;exit 1
 fi
 grep -E 'missing owner delivery falsely rearmed|owner recovery reopened invalid capture|invalid CPU capture returned usable state|lost owner failed to abort shared hold|RTC sampled before all owners settled' "$mutation.log"
 echo "PASS: detected $mutation negative control"
 popd >/dev/null
done
echo 'PASS: 44 additional-owner cases, 8 joined CPU/RTC captures and final RTC guard'
