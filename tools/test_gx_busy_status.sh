#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
bash "$repo/tools/test_gx_swap_retirement.sh"
bash "$repo/tools/test_h3d_gx_readback_owner.sh"
python3 - "$repo" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
root = Path(sys.argv[1])
for retirement in (0, 1):
    for busy in (0, 1):
        args = ["iverilog", "-g2012", "-DNDS_HYBRID_3D=1", "-E", "-o", "-"]
        if retirement:
            args.append("-DNDS_GX_SWAP_RETIREMENT_EXPERIMENT=1")
        if busy:
            args.append("-DNDS_GX_BUSY_STATUS_EXPERIMENT=1")
        args.append(str(root / "rtl/nds_nitro_console_island.sv"))
        source = subprocess.check_output(args, text=True)
        selected = "h3d_gx_geometry_busy" if busy else "1'b0"
        assert f".h3d_gx_geometry_busy({selected})" in source
        assert ".gx_geometry_busy(h3d_gx_geometry_busy)" in source
        assert f".SWAP_VBLANK_RETIREMENT(1'b{retirement})" in source
qsf = (root / "fpga/mister_nitro_console_island/NDS4MiSTer.qsf").read_text()
assert not re.search(r"^\s*set_global_assignment.*NDS_GX_BUSY_STATUS_EXPERIMENT", qsf, re.M)
print("PASS: busy status is opt-in and uses the source-clock SWAP retirement state")
PY
