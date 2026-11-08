#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
docker run --rm --network none -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -eu
verilator --cc --exe --build -j 4 -Wno-fatal -Werror-UNOPTFLAT --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/stream-transport -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/stream_transport_test.cpp > build-fpga3d/stream-transport-build.log 2>&1
build-fpga3d/stream-transport/Vnds_fpga3d > build-fpga3d/stream-transport-test.log 2>&1
python3 - <<"PY"
from pathlib import Path
s=Path("rtl/nds_fpga3d.sv").read_text()
old="count-index>fetch_limit?fetch_limit:5\x27(count-index)";assert s.count(old)==1
Path("build-fpga3d/prefix_mutant.sv").write_text(s.replace(old,"count-index>=fetch_limit?fetch_limit:5\x27(count-index+1)"))
old="page_commands>16?5\x27d16:page_commands[4:0]";assert s.count(old)==1
Path("build-fpga3d/page_mutant.sv").write_text(s.replace(old,"5\x27d16"))
s=Path("tools/fpga3d/transport.h").read_text();old=" bool submit(uint32_t* destination,size_t stride){";assert s.count(old)==1
Path("build-fpga3d/cancel_mutant.h").write_text(s.replace(old,old+"\n  if(!valid)return false;"))
s=Path("tools/fpga3d/stream_transport_test.cpp").read_text().replace("#include \"transport.h\"","#include \"cancel_mutant.h\"")
Path("build-fpga3d/cancel_mutant.cpp").write_text(s)
PY
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/prefix-mutant -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" build-fpga3d/prefix_mutant.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/prefix-mutant-build.log 2>&1
if build-fpga3d/prefix-mutant/Vnds_fpga3d > build-fpga3d/prefix-mutant-test.log 2>&1; then echo "FAIL: unpublished prefetch mutation survived";exit 1;fi
grep -q "read beyond published immutable command prefix" build-fpga3d/prefix-mutant-test.log
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/page-mutant -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d" build-fpga3d/page_mutant.sv rtl/nds_fpga3d_pixels.sv /work/tools/fpga3d/stream_transport_test.cpp > build-fpga3d/page-mutant-build.log 2>&1
if build-fpga3d/page-mutant/Vnds_fpga3d > build-fpga3d/page-mutant-test.log 2>&1; then echo "FAIL: page-crossing read mutation survived";exit 1;fi
grep -q "physical read crossed a 4 KiB page" build-fpga3d/page-mutant-test.log
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d -GPOLL_CYCLES=8 --Mdir build-fpga3d/cancel-mutant -CFLAGS "-O2 -std=c++17 -I/work/tools/fpga3d -I/work/build-fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv /work/build-fpga3d/cancel_mutant.cpp > build-fpga3d/cancel-mutant-build.log 2>&1
if build-fpga3d/cancel-mutant/Vnds_fpga3d > build-fpga3d/cancel-mutant-test.log 2>&1; then echo "FAIL: abandoned producer mutation survived";exit 1;fi
grep -q "intentional admission cancel did not drain cleanly" build-fpga3d/cancel-mutant-test.log
echo "PASS CPU/RTL streaming, bounded prefetch and cancellation negative controls"
'
