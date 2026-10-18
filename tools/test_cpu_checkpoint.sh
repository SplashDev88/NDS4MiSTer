#!/usr/bin/env bash
# CPU component proof only; does not build or deploy a console bitstream.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-checkpoint.XXXXXX")
    trap 'rm -rf "$test_tmp"' EXIT
    docker run --rm --network none -v "$repo:/repo:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash /repo/tools/test_cpu_checkpoint.sh --inside
    exit
fi
p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
    "$p/reg_savestates.vhd" "$p/nds_cpu9.vhd" "$p/gba_cpu.vhd" "$repo/rtl/tb_nds_cpu_checkpoint.vhd"
for arm9 in true false; do
  for thumb in false true; do
    for step in 1 5; do
      for delay in 1 11; do
        for phase in 0 7 41; do
          for operation in capture restore; do
            echo "arm9=$arm9 thumb=$thumb step=$step delay=$delay phase=$phase operation=$operation"
            nvc --std=2008 -e -gREAD_DELAY="$delay" -gREQUEST_PHASE="$phase" \
                -gOPERATION="$operation" -gARM9="$arm9" -gTHUMB_LOOP="$thumb" \
                -gSTEP_PERIOD="$step" tb_nds_cpu_checkpoint
            nvc --std=2008 -r tb_nds_cpu_checkpoint --ieee-warnings=off --exit-severity=error
            if [[ "$operation" == capture ]]; then
              # The identity names this authored fixture and exact simulator
              # inputs, not a commercial ROM or hardware FPGA image.
              python3 - "$repo" "$arm9" "$thumb" "$step" "$delay" <<'PY'
import hashlib, json, pathlib, subprocess, sys
repo = pathlib.Path(sys.argv[1])
files = ['rtl/tb_nds_cpu_checkpoint.vhd'] + [
    'third_party/Nitro_DarkSide/d2dabe/rtl/' + name
    for name in ['export.vhd','proc_bus_gba.vhd','reg_savestates.vhd','nds_cpu9.vhd','gba_cpu.vhd']]
build = {'sources': {name: hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in files},
         'generics': sys.argv[2:], 'simulator': subprocess.check_output(['nvc','--version']).decode()}
identity = {'component': 'arm9-branch-v1' if sys.argv[2]=='true' else 'arm7-branch-v1',
            'rom_sha256': build['sources'][files[0]],
            'build_sha256': hashlib.sha256(json.dumps(build,sort_keys=True).encode()).hexdigest()}
pathlib.Path('identity.json').write_text(json.dumps(identity))
PY
              python3 "$repo/tools/suspend_resume/capsule.py" save --identity identity.json \
                  --slot cpu.suspend --words cpu.state
              rm cpu.state
              python3 "$repo/tools/suspend_resume/capsule.py" restore --identity identity.json \
                  --slot cpu.suspend --words cpu.state
            fi
          done
        done
      done
    done
  done
done
# Capture the first ARM-to-Thumb BX itself, before the Thumb loop starts.
for arm9 in true false; do
  for delay in 1 11; do
    for operation in capture restore; do
      nvc --std=2008 -e -gARM9="$arm9" -gREAD_DELAY="$delay" -gTHUMB_LOOP=true \
          -gEARLY_CAPTURE=true -gOPERATION="$operation" tb_nds_cpu_checkpoint
      nvc --std=2008 -r tb_nds_cpu_checkpoint --ieee-warnings=off --exit-severity=error
    done
  done
done
# The pipeline-enabled CPU must still preserve branch checkpoints in both
# instruction sets, including slow enables and delayed memory responses.
for arm9 in true false; do
  for thumb in false true; do
    for step in 1 5; do
      for delay in 1 11; do
        for operation in capture restore; do
          nvc --std=2008 -e -gARM9="$arm9" -gTHUMB_LOOP="$thumb" -gSTEP_PERIOD="$step" \
              -gREAD_DELAY="$delay" -gHALT_PIPELINE=true -gOPERATION="$operation" tb_nds_cpu_checkpoint
          nvc --std=2008 -r tb_nds_cpu_checkpoint --ieee-warnings=off --exit-severity=error
        done
      done
    done
  done
done
echo 'PASS: 16 additional branch restores with the halted-pipeline extension enabled'
# Generate a CPU9 state for the negative control after the final ARM7 case.
nvc --std=2008 -e tb_nds_cpu_checkpoint
nvc --std=2008 -r tb_nds_cpu_checkpoint --ieee-warnings=off --exit-severity=error
# Reverting to the legacy CP15/Q reset must fail the state comparison.
nvc --std=2008 -e -gOPERATION=restore -gOMIT_EXT_RESTORE=true tb_nds_cpu_checkpoint
if nvc --std=2008 -r tb_nds_cpu_checkpoint --ieee-warnings=off \
    --exit-severity=error > negative.log 2>&1; then
    echo 'FAIL: incomplete legacy restore unexpectedly passed' >&2; exit 1
fi
grep -F 'restored CPU state mismatch' negative.log
echo 'PASS: 48 ARM9/ARM7 capture/fresh-process restore pairs and incomplete-state negative control'
echo 'PASS: 4 additional fresh-process restores at the ARM-to-Thumb BX transition'
nvc --std=2008 -a "$repo/rtl/tb_nds_cpu9_cold_reset.vhd"
nvc --std=2008 -e tb_nds_cpu9_cold_reset
nvc --std=2008 -r tb_nds_cpu9_cold_reset --ieee-warnings=off --exit-severity=error
PYTHONDONTWRITEBYTECODE=1 python3 "$repo/tools/suspend_resume/test_capsule.py"
