#!/bin/sh
# HW_TIME_LIMIT budget-polarity check for nds_drawer_obj: proves the
# 954/1210 H-Blank budget switch and the walk's exact truncation boundary
# (1 hw cycle per field pixel, clip elisions charged at setup/walk-end).
set -eu
cd "$(dirname "$0")/.."

TIMEOUT_MS="${TIMEOUT_MS:-10}"
WORK=sim/nvc_work_budget
mkdir -p "$WORK"

nvc -L "$WORK" --work="$WORK/work" -a --relaxed \
   rtl/nds_drawer_obj.vhd \
   sim/tb_gpu_obj_budget.vhd

nvc -H 1g -L "$WORK" --work="$WORK/work" -e tb_gpu_obj_budget -gTIMEOUT_MS="$TIMEOUT_MS"
nvc -H 1g -L "$WORK" --work="$WORK/work" -r tb_gpu_obj_budget --ieee-warnings=off --exit-severity=failure