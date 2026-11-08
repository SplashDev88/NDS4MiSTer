#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
# Use the production port mux and the production four-client arbiter with
# simultaneous cartridge, display, event and control peers.
docker run --rm -v "$PWD:/work" -w /work --entrypoint bash nds4mister-rtl-verilator:24.04 -c '
set -eu
verilator --cc --exe --build -j 4 -Wno-fatal -Werror-UNOPTFLAT --top-module nds_fpga3d_shared -GPOLL_CYCLES=8 --Mdir build-fpga3d/shared -CFLAGS "-DSHARED_FABRIC -O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv rtl/nds_fpga3d_port_mux.sv rtl/nds_ddram_arbiter_4client.sv tools/fpga3d/shared_tb.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/shared-build.log 2>&1
build-fpga3d/shared/Vnds_fpga3d_shared > build-fpga3d/shared-test.log
python3 - <<"PY"
from pathlib import Path
s=Path("rtl/nds_fpga3d_port_mux.sv").read_text()
old="c_accepted=!reset && locked && !owner && accepted;"
assert s.count(old)==1
Path("build-fpga3d/early_accept_mutant.sv").write_text(s.replace(old,"c_accepted=!reset && !selected && enqueued;"))
PY
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d_shared -GPOLL_CYCLES=8 --Mdir build-fpga3d/early-accept -CFLAGS "-DSHARED_FABRIC -O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv build-fpga3d/early_accept_mutant.sv rtl/nds_ddram_arbiter_4client.sv tools/fpga3d/shared_tb.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/early-accept-build.log 2>&1
if build-fpga3d/early-accept/Vnds_fpga3d_shared > build-fpga3d/early-accept-test.log 2>&1; then
 echo "FAIL: premature physical-acceptance mutation survived";exit 1
fi
python3 - <<"PY"
from pathlib import Path
assert "control acceptance preceded physical acceptance" in Path("build-fpga3d/early-accept-test.log").read_text()
s=Path("rtl/nds_fpga3d_port_mux.sv").read_text()
old="wire selected=owner;"
assert s.count(old)==1
Path("build-fpga3d/comb_grant_mutant.sv").write_text(s.replace(old,"wire selected=locked?owner:(a_request && !c_request);"))
PY
if verilator --lint-only -Wno-fatal -Werror-UNOPTFLAT --top-module nds_fpga3d_shared rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv build-fpga3d/comb_grant_mutant.sv rtl/nds_ddram_arbiter_4client.sv tools/fpga3d/shared_tb.sv > build-fpga3d/comb-grant-test.log 2>&1; then
 echo "FAIL: combinational grant mutation survived";exit 1
fi
python3 - <<"PY"
from pathlib import Path
assert "%Error-UNOPTFLAT" in Path("build-fpga3d/comb-grant-test.log").read_text()
print("PASS shared fabric, busy-dependent control, and both acceptance/grant negative controls")
PY
verilator --cc --exe --build -j 4 -Wno-fatal --top-module nds_fpga3d_shared -GFAIR_PROBE_INTERVAL=0 -GPOLL_CYCLES=8 --Mdir build-fpga3d/no-probe -CFLAGS "-DSHARED_FABRIC -O2 -std=c++17 -I/work/tools/fpga3d" rtl/nds_fpga3d.sv rtl/nds_fpga3d_pixels.sv rtl/nds_fpga3d_port_mux.sv rtl/nds_ddram_arbiter_4client.sv tools/fpga3d/shared_tb.sv /work/tools/fpga3d/sim.cpp > build-fpga3d/no-probe-build.log 2>&1
if build-fpga3d/no-probe/Vnds_fpga3d_shared > build-fpga3d/no-probe-test.log 2>&1; then
 echo "FAIL: disabled grant probe survived saturated peers";exit 1
fi
python3 - <<"PY2"
from pathlib import Path
assert "event burst client starved" in Path("build-fpga3d/no-probe-test.log").read_text()
print("PASS saturated burst-write/readback contention and disabled-probe negative control")
PY2
'
