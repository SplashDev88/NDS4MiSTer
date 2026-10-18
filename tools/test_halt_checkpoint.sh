#!/usr/bin/env bash
# Persist sleeping CPU components using the real HALTCNT/WFI regression paths.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-halt-checkpoint.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash /repo/tools/test_halt_checkpoint.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
export PYTHONDONTWRITEBYTECODE=1
python3 "$repo/tools/suspend_resume/generate_pipeline.py"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" "$p/reg_savestates.vhd" \
    "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" "$p/nds_membus7.vhd" "$p/nds_syscnt.vhd" \
    "$repo/rtl/tb_nds_arm7_halt_prefetch.vhd" "$repo/rtl/tb_nds_cpu9_wfi_return.vhd"

roundtrip() {
    python3 - "$repo" "$@" <<'PY'
import hashlib, json, pathlib, subprocess, sys
repo = pathlib.Path(sys.argv[1])
names = ['rtl/tb_nds_arm7_halt_prefetch.vhd', 'rtl/tb_nds_cpu9_wfi_return.vhd'] + [
    'third_party/Nitro_DarkSide/d2dabe/rtl/' + name for name in
    ['export.vhd', 'proc_bus_gba.vhd', 'reg_savestates.vhd', 'nds_cpu9.vhd',
     'gba_cpu.vhd', 'nds_membus7.vhd', 'nds_syscnt.vhd']]
names += ['tools/suspend_resume/pipeline_layout.py', 'tools/suspend_resume/capsule.py']
build = {'sources': {name: hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in names},
         'case': sys.argv[2:], 'simulator': subprocess.check_output(['nvc','--version']).decode()}
identity = {'component': sys.argv[2]+'-pipeline-v1',
            'rom_sha256': build['sources'][names[0 if sys.argv[2]=='arm7' else 1]],
            'build_sha256': hashlib.sha256(json.dumps(build,sort_keys=True).encode()).hexdigest()}
pathlib.Path('identity.json').write_text(json.dumps(identity))
PY
    python3 "$repo/tools/suspend_resume/capsule.py" save --identity identity.json \
        --slot cpu.suspend --words halt.state
    rm halt.state
    python3 "$repo/tools/suspend_resume/capsule.py" restore --identity identity.json \
        --slot cpu.suspend --words halt.state
}

for masked in true false; do
for thumb in false true; do
for return_thumb in false true; do
for padding in 0 1 2 3; do
for dma in false true; do
for phase in 0 1 7; do
    for operation in capture restore; do
        echo "arm7 $operation masked=$masked thumb=$thumb return=$return_thumb padding=$padding dma=$dma phase=$phase"
        nvc --std=2008 -e -gCHECKPOINT_OPERATION="$operation" -gMASK_IRQ="$masked" \
            -gTHUMB="$thumb" -gRETURN_THUMB="$return_thumb" -gHALT_NOPS="$padding" \
            -gDMA_PAUSE="$dma" -gWAKE_TICKS="$phase" tb_nds_arm7_halt_prefetch
        nvc --std=2008 -r tb_nds_arm7_halt_prefetch --ieee-warnings=off --exit-severity=error
        if [[ $operation == capture ]]; then
            roundtrip arm7 "$masked" "$thumb" "$return_thumb" "$padding" "$dma" "$phase"
        fi
    done
done
done
done
done
done
done

for irq in true false; do
for delay in 1 8 11; do
for phase in 0 4 12; do
    for operation in capture restore; do
        echo "arm9 $operation irq=$irq delay=$delay phase=$phase"
        nvc --std=2008 -e -gCHECKPOINT_OPERATION="$operation" -gIRQ_ENABLED="$irq" \
            -gREAD_DELAY="$delay" -gWAKE_DELAY="$phase" tb_nds_cpu9_wfi_return
        nvc --std=2008 -r tb_nds_cpu9_wfi_return --ieee-warnings=off --exit-severity=error
        if [[ $operation == capture ]]; then roundtrip arm9 "$irq" "$delay" "$phase"; fi
    done
done
done
done

# RAM can change after an instruction was prefetched. With IRQ masked, restore
# must execute the captured BX, not the changed RAM word at that address.
for delay in 1 8 11; do
for phase in 0 4 12; do
    for operation in capture restore; do
        nvc --std=2008 -e -gCHECKPOINT_OPERATION="$operation" -gIRQ_ENABLED=false \
            -gREAD_DELAY="$delay" -gWAKE_DELAY="$phase" -gMUTATE_PREFETCH=true tb_nds_cpu9_wfi_return
        nvc --std=2008 -r tb_nds_cpu9_wfi_return --ieee-warnings=off --exit-severity=error
        if [[ $operation == capture ]]; then roundtrip arm9 false "$delay" "$phase" mutated; fi
    done
done
done
echo 'PASS: 9 additional WFI restores preserve the prefetched opcode after RAM is changed'
# Functional negative controls omit pipeline writes and their readback check.
# The resumed guest must catch a skipped weighted operation/BX.
for cpu in arm7 arm9; do
    if [[ $cpu == arm7 ]]; then tb=tb_nds_arm7_halt_prefetch; else tb=tb_nds_cpu9_wfi_return; fi
    nvc --std=2008 -e -gCHECKPOINT_OPERATION=capture "$tb"
    nvc --std=2008 -r "$tb" --ieee-warnings=off --exit-severity=error
    nvc --std=2008 -e -gCHECKPOINT_OPERATION=restore -gOMIT_PIPELINE_RESTORE=true "$tb"
    if nvc --std=2008 -r "$tb" --ieee-warnings=off --exit-severity=error > "$cpu-negative.log" 2>&1; then
        echo "FAIL: missing $cpu pipeline unexpectedly resumed" >&2; exit 1
    fi
    grep -E 'Post-halt operation skipped/repeated|HALT wake failed return|FAIL: executed terminal guard|did not return to caller after WFI/IRQ' "$cpu-negative.log"
done
python3 "$repo/tools/suspend_resume/test_capsule.py"
echo 'PASS: 192 ARM7 HALT and 18 ARM9 WFI fresh-process restores through capsule, plus two missing-pipeline negative controls'
