#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-nitro-island-host.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

python3 "$script_dir/test_arm7_shared_shifter.py"
python3 "$script_dir/test_sound_fetch_state_packing.py"
"$script_dir/test_nds_sound_vhdl_analyze.sh"
python3 "$script_dir/test_cache_tag_packing.py"
"$script_dir/test_nds_cache_vhdl_analyze.sh"

"$script_dir/test_extract_melonds_freebios.sh"
freebios7_before="$(shasum -a 256 "$repo_dir/rtl/nds_nitro_freebios7.vhd")"
freebios9_before="$(shasum -a 256 "$repo_dir/rtl/nds_nitro_freebios9.vhd")"
python3 "$script_dir/generate_nitro_freebios_vhdl.py" >/dev/null
test "$freebios7_before" = "$(shasum -a 256 "$repo_dir/rtl/nds_nitro_freebios7.vhd")"
test "$freebios9_before" = "$(shasum -a 256 "$repo_dir/rtl/nds_nitro_freebios9.vhd")"

run_sv() {
    local top="$1"
    shift
    iverilog -g2012 -Wall -s "$top" -o "$test_tmp/$top" "$@"
    vvp "$test_tmp/$top"
}

run_sv tb_nds_nitro_ddram_cache_flush \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/tb_nds_nitro_ddram_cache_flush.sv"

run_sv tb_nds_nitro_cart_readahead \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/tb_nds_nitro_cart_readahead.sv"

run_sv tb_nds_nitro_async_fifo \
    "$repo_dir/rtl/nds_nitro_async_fifo.sv" \
    "$repo_dir/rtl/tb_nds_nitro_async_fifo.sv"

run_sv tb_nds_nitro_video_scanout \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/rtl/tb_nds_nitro_video_scanout.sv"

run_sv tb_nds_nitro_fb_side_by_side \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/tb_nds_nitro_fb_side_by_side.sv"

# Keep the optional diagnostic implementation correct without enabling it in
# the product. The static product checks below keep this test-only parameter
# from consuming FPGA resources in an alpha RBF.
run_sv tb_nds_nitro_fb_telemetry \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/tb_nds_nitro_fb_telemetry.sv"

run_sv tb_nds_nitro_arm9_math_unit \
    "$repo_dir/rtl/nds_nitro_arm9_math_unit.sv" \
    "$repo_dir/rtl/tb_nds_nitro_arm9_math_unit.sv"

run_sv tb_nds_nitro_save_bridge \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/tb_nds_nitro_save_bridge.sv"

iverilog -g2012 -Wall -i -s tb_nds_nitro_input_boundary \
    -o "$test_tmp/tb_nds_nitro_input_boundary" \
    "$repo_dir/rtl/nds_nitro_arm9_math_unit.sv" \
    "$repo_dir/rtl/nds_nitro_async_fifo.sv" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/nds_nitro_console_island.sv" \
    "$repo_dir/rtl/tb_nds_nitro_input_boundary.sv"
vvp "$test_tmp/tb_nds_nitro_input_boundary"

# Bind the simulated synchronized levels to the standard MiSTer J1 ordering
# and the exact donor key ports.  These are structural product contracts, not
# a duplicate behavioral model in the testbench.
grep -Fq '        "NDS;;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '        "FS3,NDS,Load NDS (max 128 MiB),30000000;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'nds_nitro_integer_scale integer_scale (' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '"O[6:5],Video Layout,Left/Right,Top/Bottom,Left Only,Right Only;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '"O[7],Screen Order,Main First,Touch First;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '"O[9:8],Screen Gap,8 Pixels,None,16 Pixels,24 Pixels;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'wire [1:0] video_gap_select = status[9:8] == 2'"'"'d0 ? 2'"'"'d1 :' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '        "v,1;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '"O[4],FPS Counter,Off,On;",' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq "wire console_enabled=1'b1;" \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'wire media_reset=RESET|~shell_pll_locked;' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'wire core_reset=media_reset|status[0]|buttons[1];' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '.media_reset(media_reset)' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq 'wire save_bridge_reset_request = media_reset | ~island_locked | ~enable;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'save_cart_ready_sync_video[0], cart_loaded_ddr' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.reset(save_bridge_reset_video)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.cart_download(save_cart_event_pulse)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.img_mounted(save_mount_pulse)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
if grep -Fq 'Nitro console,On,Off' \
        "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"; then
    echo "FAIL: always-on Nitro console still has an OSD toggle" >&2
    exit 1
fi
grep -Fq 'localparam logic [1:0] LAYOUT_SIDE   = 2'"'"'d0;' \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv"
grep -Fq 'localparam logic [1:0] LAYOUT_STACK  = 2'"'"'d1;' \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv"
grep -Fq '{fps_active,gap_active,screen_order_active,' \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv"
grep -Fq 'set_global_assignment -name VERILOG_MACRO "NDS_FORCE_NEAREST=1"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.qsf"
grep -Fq 'set_global_assignment -name VERILOG_MACRO "NDS_FORCE_INTEGER_SCALE=1"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.qsf"
grep -Fq 'set_global_assignment -name VERILOG_MACRO "NDS_HDMI_SCALER_ONLY=1"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.qsf"
grep -Fq 'assign hdmi_tx_clk = hdmi_clk_out;' \
    "$repo_dir/fpga/mister_nitro_console_island/sys/sys_top.v"
grep -Fq 'set_global_assignment -name VERILOG_MACRO "NDS_HYBRID_3D=1"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.qsf"
for h3d_source in \
    nds_h3d_console_event_gate.vhd nds_h3d_gx_status.vhd \
    nds_h3d_ddr_fabric.sv nds_h3d_control_init.sv \
    nds_h3d_event_async_fifo.sv nds_gx_fifo_packet_frontend.sv \
    nds_h3d_frame_record_cdc.sv nds_h3d_frame_packet_writer.sv \
    nds_h3d_plane_reader.sv; do
    grep -Fq "$h3d_source" \
        "$repo_dir/fpga/mister_nitro_console_island/files.qip"
done
for retired_product_source in \
    nds_h3d_event_queue_cdc.sv nds_h3d_event_ring.sv \
    nds_h3d_gpu_event_capture.sv; do
    if grep -Fq "$retired_product_source" \
        "$repo_dir/fpga/mister_nitro_console_island/files.qip"; then
        echo "FAIL: retired H3D product source remains in files.qip" >&2
        exit 1
    fi
done
# The outer island fabric uses physical 64-bit word addresses. Pin the H3B
# control and four-slot aperture below the first return-plane bank; never fall
# back to the standalone writer's translated-aperture defaults.
grep -Fq "localparam logic [28:0] H3D_CONTROL_WORD = 29'h07f80000;" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq "localparam logic [28:0] H3D_SLOT_WORD    = 29'h07f82000;" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq "localparam logic [28:0] H3D_BANK0_WORD   = 29'h07fa0000;" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.CONTROL_BASE_WORD(H3D_CONTROL_WORD)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.SLOT_BASE_WORD(H3D_SLOT_WORD)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq ".PACKET_MODE(1'b1)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
# Plane handoff belongs to the scanout clock, not to the architectural event
# queue.  A continuously-valid queued boundary has no per-frame rising edge
# and would hold one completed ARM plane for arbitrarily many display frames.
grep -Fq 'wire h3d_scanout_frame_boundary = h3d_core_line_end &&' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.frame_boundary(h3d_scanout_frame_boundary)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
if grep -Fq 'h3d_frame_valid && !h3d_frame_valid_q' \
        "$repo_dir/rtl/nds_nitro_console_island.sv"; then
    echo "FAIL: H3D plane handoff still uses queued-boundary valid edge" >&2
    exit 1
fi
grep -Fq 'ibios7 : entity work.nds_nitro_freebios7' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq 'ibios9 : entity work.nds_nitro_freebios9' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
# In 3D-plane mode BG/OBJ traffic remains local to the FPGA; only LCDC texture
# uploads cross to HPS. Pin that filter and the local-write acceptance seam.
grep -Fq 'h3d_vram9_source_address(27 downto 20) = x"68"' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq 'vram9_ena and not vram9_rnw and h3d_vram9_needed_by_h3d;' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq "h3d_vram9_needed_by_h3d = '0') else" \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq '"J1,A,B,X,Y,L,R,Select,Start,Touch;"' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
grep -Fq '.joystick_r_analog_0(touch_analog_0)' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
if grep -Fq '.joystick_l_analog_0(' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"; then
    echo "FAIL: touchscreen must not consume the left analog stick" >&2
    exit 1
fi
grep -Fq '.KeyA(joystick_sync[4]),.KeyB(joystick_sync[5])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.KeySelect(joystick_sync[10]),.KeyStart(joystick_sync[11])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.KeyRight(joystick_sync[0]),.KeyLeft(joystick_sync[1])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.KeyUp(joystick_sync[3]),.KeyDown(joystick_sync[2])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.KeyR(joystick_sync[9]),.KeyL(joystick_sync[8])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.KeyX(joystick_sync[6]),.KeyY(joystick_sync[7])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.touch_active(joystick_sync[12])' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.touch_x(touch_x),.touch_y(touch_y)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'wire [7:0] touch_y = touch_y_scaled[9:2];' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'touch_active => touch_active, touch_x => touch_x, touch_y => touch_y' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"

# Keep the large per-pixel telemetry cone compiled out. The seam diagnostic
# publishes the plane reader's compact passive frame counters through FPGA
# heartbeat word 12 without changing CPU, renderer, or display behavior.
grep -Fq ".RUNTIME_TELEMETRY(1'b0)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq ".source_fault(1'b0)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq ".telemetry_session(32'd0)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq ".fpga_heartbeat_value(h3d_diagnostic_heartbeat)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'wire [31:0] h3d_bg1_scroll_triplet;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_bg1_scroll_meta_ddr <= h3d_bg1_scroll_triplet;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_plane_descriptor_valid && h3d_plane_line_missed &&' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.pixel_line_missed(h3d_plane_pixel_line_missed)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.pixel_frame_diagnostic(h3d_plane_frame_diagnostic)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'assign pixel_line_missed = line_start && pixel_descriptor_valid &&' \
    "$repo_dir/rtl/nds_h3d_plane_reader.sv"
grep -Fq 'h3d_plane_frame_diagnostic_ddr' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq "4'h9, dbg_pc9_diag[27:0]" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_line_seed_remaining <= 2' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_line_pending_frame <= h3d_pixel_descriptor_frame;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.runtime_fault_flags(h3d_fb_fault_flags)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq '.bank_diagnostic(h3d_fb_bank_diagnostic)' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_fb_bank_diagnostic' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'scanout_write_collision' \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv"
grep -Fq 'wire [7:0] h3d_scanout_late_count;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'logic [7:0] h3d_line_drop_count_ddr;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'logic [7:0] h3d_plane_miss_count_ddr;' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'wire [31:0] fb_runtime_heartbeat = dbg_pc9_diag != 0 ? dbg_pc9_diag : {' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_control_release, h3d_record_source_active, h3d_console_release,' \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
grep -Fq 'h3d_gpu_source_address <= io_bus9.Adr;' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq "hblank_pulse => '0'" \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq ".external_frame_mode(1'b0), .external_frame_publish(1'b0)" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"
# The measured one-engine fit diagnostic keeps timing-critical engine A in
# fabric and mirrors it to both screens.  Pin the selector so a build cannot
# silently restore the 7K-ALM engine-B cone and return to the 98% fit failure.
grep -Fq 'GPU_FAST => 0, GPU2D_B_ENABLE => 0,' \
    "$repo_dir/rtl/nds_nitro_console_wrap.vhd"
grep -Fq 'g_no_gpu2d_b : if GPU2D_B_ENABLE = 0 generate' \
    "$repo_dir/rtl/nds_nitro_console_top.vhd"
grep -Fq 'assign LED_USER=nitro_boot_error|nitro_boundary_fault|~nitro_cart_loaded;' \
    "$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.sv"
qsf="$repo_dir/fpga/mister_nitro_console_island/NDS4MiSTer.qsf"
if grep -Eq 'VERILOG_MACRO.*NDS_FB_TELEMETRY' "$qsf"; then
    if ! grep -Eq 'VERILOG_MACRO.*NDS_BOOT_DIAGNOSTIC' "$qsf"; then
        echo "FAIL: legacy framebuffer telemetry lacks diagnostic guard" >&2
        exit 1
    fi
    grep -Fq ".dbg0(18'h2d15a)" \
        "$repo_dir/rtl/nds_nitro_console_island.sv"
elif grep -Eq 'VERILOG_MACRO.*NDS_BOOT_DIAGNOSTIC' "$qsf"; then
    echo "FAIL: diagnostic build lacks framebuffer publication lane" >&2
    exit 1
fi

# Quartus 17 cannot resolve SystemVerilog shorthand connections on a VHDL
# instance.  Keep every port on the mixed-language console boundary explicit.
if sed -n '/nds_nitro_console_wrap #(/,/^);/p' \
    "$repo_dir/rtl/nds_nitro_console_island.sv" | \
    grep -Eq '\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(,|\)|$)'; then
    echo "FAIL: shorthand port remains on VHDL console instance" >&2
    exit 1
fi
console_ports=$(sed -n '/nds_nitro_console_wrap #(/,/^);/p' \
    "$repo_dir/rtl/nds_nitro_console_island.sv")
for required_port in \
    h3d_pixel_valid h3d_line_request h3d_service_ready \
    h3d_gx_fifo_level h3d_current_frame h3d_source_fault \
    diagnostic_hold9 diagnostic_hold7 \
    diagnostic_release9 diagnostic_release7 \
    h3d_gpu_write_valid \
    h3d_vram9_write_valid h3d_vram7_write_valid h3d_frame_valid; do
    grep -Fq ".$required_port(" <<<"$console_ports"
done

# Parse/elaborate the complete SystemVerilog island boundary.  The VHDL
# console wrapper remains the focused GHDL/Quartus mixed-language gate.
iverilog -g2012 -Wall -i -tnull -s nds_nitro_console_island \
    "$repo_dir/rtl/nds_nitro_arm9_math_unit.sv" \
    "$repo_dir/rtl/nds_nitro_async_fifo.sv" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"

# Parse/elaborate the exact product H3D branch with every SystemVerilog
# transport/fabric block present. VHDL remains a black box here and is closed
# independently by tools/test_h3d_product_seam.sh.
iverilog -g2012 -Wall -i -tnull -s nds_nitro_console_island \
    -DNDS_HYBRID_3D=1 \
    "$repo_dir/rtl/nds_nitro_arm9_math_unit.sv" \
    "$repo_dir/rtl/nds_nitro_async_fifo.sv" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/rtl/nds_ddram_arbiter_4client.sv" \
    "$repo_dir/rtl/nds_h3d_ddr_fabric.sv" \
    "$repo_dir/rtl/nds_h3d_control_init.sv" \
    "$repo_dir/rtl/nds_h3d_event_async_fifo.sv" \
    "$repo_dir/rtl/nds_gx_fifo_packet_frontend.sv" \
    "$repo_dir/rtl/nds_h3d_frame_record_cdc.sv" \
    "$repo_dir/rtl/nds_h3d_frame_packet_writer.sv" \
    "$repo_dir/rtl/nds_h3d_plane_reader.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"

# Parse the temporary boot-diagnostic branch too. This does not enable it in a
# release QSF; it only prevents the guarded snapshot/publication cone from
# becoming an uncompiled path.
iverilog -g2012 -Wall -i -tnull -s nds_nitro_console_island \
    -DNDS_BOOT_DIAGNOSTIC=1 -DNDS_FB_TELEMETRY=1 \
    "$repo_dir/rtl/nds_nitro_arm9_math_unit.sv" \
    "$repo_dir/rtl/nds_nitro_async_fifo.sv" \
    "$repo_dir/rtl/nds_nitro_fb_ddr3.sv" \
    "$repo_dir/rtl/nds_nitro_save_bridge.sv" \
    "$repo_dir/rtl/nds_nitro_video_scanout.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/sdram.sv" \
    "$repo_dir/third_party/Nitro_DarkSide/d2dabe/rtl/ddram.sv" \
    "$repo_dir/rtl/nds_nitro_console_island.sv"

echo "PASS: r355 Nitro console-island host RTL gates"
