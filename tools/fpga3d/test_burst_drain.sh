#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
docker run --rm -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -eu
python3 - <<"PY"
from pathlib import Path
s=Path("rtl/nds_fpga3d.sv").read_text()
old="(!enable && !flush_inflight)";assert s.count(old)==3
Path("build-fpga3d/abort_burst_mutant.sv").write_text(s.replace(old,"!enable"))
PY
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/abort-burst -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" build-fpga3d/abort_burst_mutant.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/abort-burst-build.log 2>&1
if build-fpga3d/abort-burst/Vnds_fpga3d > build-fpga3d/abort-burst-test.log 2>&1;then
 echo "FAIL: interrupted burst mutation survived";exit 1
fi
python3 - <<"PY"
from pathlib import Path
assert "FAIL gap in physical Avalon write burst" in Path("build-fpga3d/abort-burst-test.log").read_text()
print("PASS enable-loss abort mutation detected by physical burst continuity oracle")
PY
'
