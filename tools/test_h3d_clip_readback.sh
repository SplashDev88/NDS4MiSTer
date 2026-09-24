#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nds-clip-readback.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

run_transport() {
    local root=$1 tmp=$2 name deps
    for name in gx_fifo_packet_frontend h3d_frame_packet_writer h3d_frame_record_cdc h3d_delayed_scanline_tag; do
        deps=()
        case "$name" in
            h3d_frame_record_cdc|h3d_delayed_scanline_tag)
                deps=("$root/rtl/nds_h3d_event_async_fifo.sv" "$root/rtl/nds_gx_fifo_packet_frontend.sv") ;;
        esac
        if [[ $name == h3d_delayed_scanline_tag ]]; then
            deps+=("$root/rtl/nds_h3d_frame_record_cdc.sv")
        else
            deps+=("$root/rtl/nds_$name.sv")
        fi
        iverilog -g2012 -Wall -s "tb_nds_$name" -o "$tmp/$name.vvp" \
            "${deps[@]}" "$root/rtl/tb_nds_$name.sv"
        vvp "$tmp/$name.vvp"
    done
}
if command -v iverilog >/dev/null 2>&1; then
    run_transport "$repo_dir" "$test_tmp"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" nds4mister-rtl-sim:24.04 \
        bash -lc "set -eu; $(declare -f run_transport); run_transport /workspace /test"
fi
bash "$repo_dir/tools/test_h3d_gx_readback_owner.sh"
bash "$repo_dir/tools/test_h3d_gx_readback_reply.sh"
bash "$repo_dir/tools/test_h3d_readback_legacy_adapter.sh"

# Includes malformed fences, continuation ownership, commit ordering and
# session changes. The service --self-test separately exercises actual GPU
# execution in synchronous/asynchronous and matched-display modes.
"${CXX:-c++}" -std=c++17 -O2 -fwrapv -Wall -Wextra -Werror -pedantic \
    -DNDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION -I"$repo_dir/src" \
    "$repo_dir/src/replay/Hybrid3DFramePacketTest.cpp" \
    "$repo_dir/src/replay/Hybrid3DFramePacket.cpp" -o "$test_tmp/packet-test"
"$test_tmp/packet-test"
