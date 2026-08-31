// SPDX-License-Identifier: GPL-3.0-or-later
// Hybrid execution island derived from Nitro_DarkSide NDS.sv at
// d2dabe03344c0a685cd0f00e42b1a89606710dee (tree
// 5b7f2671bbab83855bad314ba8d00704bba035ef).
//
// This is deliberately not a second MiSTer shell.  It terminates only the
// donor console, SDRAM and framebuffer interfaces; NDS4MiSTer.sv retains the
// project's hps_io, OSD, controller, publication, HDMI and audio boundaries.
module nds_nitro_console_island (
    input  logic        clk1x,
    input  logic        clk2x,
    input  logic        clk_mem,
    input  logic        clk_video,
    input  logic        ddr_clk,
    input  logic        island_locked,
    input  logic        shell_reset,
    // Hard/core-lifecycle reset for mounted-media state. Console soft reset
    // deliberately excludes this input so the one-shot MiSTer mount survives.
    input  logic        media_reset,
    input  logic        enable,
    input  logic [1:0]  video_layout_select,
    input  logic        video_screen_order_select,
    input  logic [1:0]  video_gap_select,
    input  logic        video_fps_select,
    output logic [1:0]  video_layout_active,
    output logic        video_screen_order_active,
    output logic [1:0]  video_gap_active,
    output logic        video_fps_active,
    input  logic [31:0] joystick,
    input  logic [15:0] joystick_analog,
    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    output logic        ioctl_wait,
    // MiSTer mounted-save block channel (slot zero, opened automatically by
    // the FS3 ROM selector in the retained shell).
    input  logic        save_img_mounted,
    input  logic        save_img_readonly,
    input  logic [63:0] save_img_size,
    output logic [31:0] save_sd_lba,
    output logic        save_sd_rd,
    output logic        save_sd_wr,
    input  logic        save_sd_ack,
    input  logic [12:0] save_sd_buff_addr,
    input  logic [15:0] save_sd_buff_dout,
    output logic [15:0] save_sd_buff_din,
    input  logic        save_sd_buff_wr,

    output logic        boot_done,
    output logic        boot_error,
    output logic        cart_loaded,

    output logic        video_ce,
    output logic        video_de,
    output logic        video_hs,
    output logic        video_vs,
    output logic [7:0]  video_r,
    output logic [7:0]  video_g,
    output logic [7:0]  video_b,
    output logic        boundary_fault,
    output logic [15:0] audio_left,
    output logic [15:0] audio_right,

    output logic [7:0]  island_ddr_burst,
    output logic [28:0] island_ddr_addr,
    input  logic [63:0] island_ddr_dout,
    input  logic        island_ddr_dout_ready,
    output logic        island_ddr_read,
    output logic [63:0] island_ddr_din,
    output logic [7:0]  island_ddr_be,
    output logic        island_ddr_write,
    input  logic        island_ddr_busy,

    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire [15:0]  SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE
);
// Keep every phase-sensitive bridge in lockstep with nitro_pll.  The 4x build
// changes only clk_mem; clk1x and clk2x retain the architectural DS cadence.
// A PLL-only switch would leave IDX_ACCEPT at phase 2 and could accept the
// same held request twice during the fourth memory-clock phase.
`ifdef NDS_CLKMEM_4X
localparam integer CLKMEM_RATIO = 4;
`else
localparam integer CLKMEM_RATIO = 3;
`endif
localparam integer IDX_ACCEPT = CLKMEM_RATIO - 1;
localparam integer IDX_DONE = CLKMEM_RATIO - 2;
wire pll_locked = island_locked;

// Cartridge replacement is a DDR-domain transaction, not just an OSD edge.
// The donor stays reset from the first observed download beat until the old
// card transaction has drained and ddram's ch2 read cache has been displaced.
localparam logic [1:0] CART_EMPTY    = 2'd0;
localparam logic [1:0] CART_DOWNLOAD = 2'd1;
localparam logic [1:0] CART_FLUSH    = 2'd2;
localparam logic [1:0] CART_READY    = 2'd3;

wire cart_download_raw = ioctl_download &&
    ((ioctl_index[5:0] == 6'h03) || (ioctl_index == 16'h00c0));
logic cart_download_ddr = 1'b0;
logic cart_download_d = 1'b0;
logic [1:0] cart_state = CART_EMPTY;
logic flush_complete;
always_ff @(posedge ddr_clk) begin
    // hps_io and ddram use this clock in the retained shell.  Register the
    // decoded level so all lifecycle edges are local to the DDR domain.
    cart_download_ddr <= cart_download_raw;
    cart_download_d <= cart_download_ddr;

    case (cart_state)
        CART_EMPTY: begin
            if (cart_download_ddr) cart_state <= CART_DOWNLOAD;
        end
        CART_DOWNLOAD: begin
            if (!cart_download_ddr && cart_download_d)
                cart_state <= CART_FLUSH;
        end
        CART_FLUSH: begin
            // A replacement that starts during the flush invalidates that
            // epoch too.  Its own post-download flush is still mandatory.
            if (cart_download_ddr) cart_state <= CART_DOWNLOAD;
            else if (flush_complete) cart_state <= CART_READY;
        end
        default: begin // CART_READY
            if (cart_download_ddr) cart_state <= CART_DOWNLOAD;
        end
    endcase
end

wire cart_hold_ddr = cart_state != CART_READY;
wire cart_loaded_ddr = cart_state == CART_READY;
// A hybrid-3D product never lets either CPU run against an absent, stale, or
// restarting HPS renderer.  The control block lives outside console_reset and
// raises this release only after its ordered H3DQ/H3D1 session handshake.
`ifdef NDS_HYBRID_3D
wire h3d_console_release;
logic [31:0] h3d_external_fault_bits;
wire h3d_fatal_reset = |h3d_external_fault_bits;
wire h3d_boundary_fatal = h3d_fatal_reset;
`else
wire h3d_console_release = 1'b1;
wire h3d_fatal_reset = 1'b0;
wire h3d_boundary_fatal = 1'b0;
`endif
wire save_ready;
wire console_reset_request = shell_reset | ~island_locked | ~enable |
    cart_download_raw | cart_hold_ddr | ~h3d_console_release |
    h3d_fatal_reset | ~save_ready;
// Async assertion prevents either CPU from observing a partially rewritten
// image.  Each receiving domain deasserts locally; the PLL outputs are related,
// but none of the four reset releases relies on that relationship.
(* async_reg = "true" *) logic [1:0] console_reset_sync_1x = 2'b11;
(* async_reg = "true" *) logic [1:0] console_reset_sync_2x = 2'b11;
(* async_reg = "true" *) logic [1:0] console_reset_sync_mem = 2'b11;
(* async_reg = "true" *) logic [1:0] console_reset_sync_ddr = 2'b11;
// Video timing is an electrical shell contract, not console state.  A
// fail-closed H3D/CPU reset must not hold HS/VS/CE inactive: doing so makes
// HDMI sinks report an invalid mode exactly when the console faults.  Keep
// the scanout and its line-buffer read port alive through cartridge/session
// and H3D resets; their contents may go black or retain the last frame, but
// the raster remains continuously valid.
wire video_output_reset_request = shell_reset | ~island_locked | ~enable;
(* async_reg = "true" *) logic [1:0] video_output_reset_sync = 2'b11;
always_ff @(posedge clk1x or posedge console_reset_request) begin
    if (console_reset_request) console_reset_sync_1x <= 2'b11;
    else console_reset_sync_1x <= {console_reset_sync_1x[0], 1'b0};
end
always_ff @(posedge clk2x or posedge console_reset_request) begin
    if (console_reset_request) console_reset_sync_2x <= 2'b11;
    else console_reset_sync_2x <= {console_reset_sync_2x[0], 1'b0};
end
always_ff @(posedge clk_mem or posedge console_reset_request) begin
    if (console_reset_request) console_reset_sync_mem <= 2'b11;
    else console_reset_sync_mem <= {console_reset_sync_mem[0], 1'b0};
end
always_ff @(posedge ddr_clk or posedge console_reset_request) begin
    if (console_reset_request) console_reset_sync_ddr <= 2'b11;
    else console_reset_sync_ddr <= {console_reset_sync_ddr[0], 1'b0};
end
always_ff @(posedge clk_video or posedge video_output_reset_request) begin
    if (video_output_reset_request) video_output_reset_sync <= 2'b11;
    else video_output_reset_sync <= {video_output_reset_sync[0], 1'b0};
end
wire console_reset_1x = console_reset_sync_1x[1];
wire console_reset_2x = console_reset_sync_2x[1];
wire console_reset_mem = console_reset_sync_mem[1];
wire console_reset_ddr = console_reset_sync_ddr[1];
wire video_output_reset = video_output_reset_sync[1];

// The card pager is infrastructure for completing the cache-displacing read;
// unlike the CPUs, it must remain alive throughout CART_DOWNLOAD/CART_FLUSH.
wire bridge_reset_request = shell_reset | ~island_locked | ~enable;
(* async_reg = "true" *) logic [1:0] bridge_reset_sync_ddr = 2'b11;
always_ff @(posedge ddr_clk or posedge bridge_reset_request) begin
    if (bridge_reset_request) bridge_reset_sync_ddr <= 2'b11;
    else bridge_reset_sync_ddr <= {bridge_reset_sync_ddr[0], 1'b0};
end
wire bridge_reset_ddr = bridge_reset_sync_ddr[1];

// ---------------- Cartridge backup persistence ----------------
// One 512-byte cache covers all EEPROM/FRAM/flash sizes through 1 MiB. Port A
// is the emulated byte-wide save chip; port B is hps_io's 16-bit sector view.
// The complete chip address goes to the bridge while only its low nine bits
// select this M10K.
wire [19:0] backup_addr;
wire [7:0] backup_write_data;
wire backup_write_enable;
wire [7:0] backup_read_data;
wire backup_write_toggle;
wire backup_is_64k;
wire [3:0] backup_save_type;
wire backup_profile_valid;
wire backup_access_active;
(* async_reg = "true" *) logic [3:0] backup_save_type_meta_video;
(* async_reg = "true" *) logic [3:0] backup_save_type_sync_video;
(* async_reg = "true" *) logic backup_profile_valid_meta_video;
(* async_reg = "true" *) logic backup_profile_valid_sync_video;
wire backup_cache_ready_video;
wire save_run_ready_video;
(* async_reg = "true" *) logic backup_cache_ready_meta_1x;
(* async_reg = "true" *) logic backup_cache_ready_sync_1x;
(* async_reg = "true" *) logic save_run_ready_meta_1x;
(* async_reg = "true" *) logic save_run_ready_sync_1x;
wire [7:0] backup_host_addr;
wire [15:0] backup_host_write_data;
wire backup_host_write_enable;
wire [15:0] backup_host_read_data;

// hps_io can publish its one-cycle img_mounted notice while the console
// island is still held in its power/media reset.  Queue that notice outside
// the save bridge reset domain, then replay it for exactly one clk_video cycle
// after reset has deasserted cleanly.  The image metadata is captured with the
// notice so the replay cannot observe a later hps_io transaction's values.
wire save_bridge_reset_request = media_reset | ~island_locked | ~enable;
(* async_reg = "true" *) logic [1:0] save_bridge_reset_sync_video = 2'b11;
logic save_mount_queued = 1'b0;
logic save_mount_pulse = 1'b0;
logic save_mount_readonly = 1'b0;
logic [63:0] save_mount_size = 64'd0;
(* async_reg = "true" *) logic [1:0] save_cart_ready_sync_video = 2'b00;
logic save_cart_ready_d = 1'b0;
logic save_cart_download_d = 1'b0;
logic save_cart_event_seen = 1'b0;
logic save_cart_event_pulse = 1'b0;

always_ff @(posedge clk_video or posedge save_bridge_reset_request) begin
    if (save_bridge_reset_request)
        save_bridge_reset_sync_video <= 2'b11;
    else
        save_bridge_reset_sync_video <= {save_bridge_reset_sync_video[0], 1'b0};
end
wire save_bridge_reset_video = save_bridge_reset_sync_video[1];

always_ff @(posedge clk_video) begin
    save_mount_pulse <= 1'b0;

    if (save_img_mounted) begin
        save_mount_readonly <= save_img_readonly;
        save_mount_size <= save_img_size;
        // Hold every mount until the local bridge is definitely out of reset.
        // A reset can begin just after hps_io's pulse, so directly forwarding
        // the pulse while reset is low is not sufficient.
        save_mount_queued <= 1'b1;
    end else if (!save_bridge_reset_video && save_mount_queued) begin
        save_mount_queued <= 1'b0;
        save_mount_pulse <= 1'b1;
    end
end

// The raw hps_io download level is the earliest cartridge-replacement notice,
// so retain it for flushing an outgoing dirty save before MiSTer mounts the
// next sidecar.  A direct MGL load can place the complete raw pulse inside the
// bridge reset interval, however.  The cartridge FSM's verified-ready level
// survives that interval and provides an authoritative fallback edge after
// reset.  One event is emitted per reset/load epoch; a normal raw edge marks
// the fallback as already satisfied.
always_ff @(posedge clk_video or posedge save_bridge_reset_request) begin
    if (save_bridge_reset_request) begin
        save_cart_ready_sync_video <= 2'b00;
        save_cart_ready_d <= 1'b0;
        save_cart_download_d <= 1'b0;
        save_cart_event_seen <= 1'b0;
        save_cart_event_pulse <= 1'b0;
    end else begin
        save_cart_ready_sync_video <= {
            save_cart_ready_sync_video[0], cart_loaded_ddr
        };
        save_cart_ready_d <= save_cart_ready_sync_video[1];
        save_cart_download_d <= cart_download_raw;
        save_cart_event_pulse <= 1'b0;

        if (cart_download_raw && !save_cart_download_d) begin
            save_cart_event_seen <= 1'b1;
            save_cart_event_pulse <= 1'b1;
        end else if (save_cart_ready_sync_video[1] && !save_cart_ready_d &&
                     !save_cart_event_seen) begin
            save_cart_event_seen <= 1'b1;
            save_cart_event_pulse <= 1'b1;
        end
    end
end

always_ff @(posedge clk_video) begin
    backup_save_type_meta_video <= backup_save_type;
    backup_save_type_sync_video <= backup_save_type_meta_video;
    backup_profile_valid_meta_video <= backup_profile_valid;
    backup_profile_valid_sync_video <= backup_profile_valid_meta_video;
end

always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        backup_cache_ready_meta_1x <= 1'b0;
        backup_cache_ready_sync_1x <= 1'b0;
        save_run_ready_meta_1x <= 1'b0;
        save_run_ready_sync_1x <= 1'b0;
    end else begin
        backup_cache_ready_meta_1x <= backup_cache_ready_video;
        backup_cache_ready_sync_1x <= backup_cache_ready_meta_1x;
        save_run_ready_meta_1x <= save_run_ready_video;
        save_run_ready_sync_1x <= save_run_ready_meta_1x;
    end
end

altsyncram backup_ram (
    .address_a(backup_addr[8:0]),
    .address_b(backup_host_addr),
    .clock0(clk1x),
    .clock1(clk_video),
    .data_a(backup_write_data),
    .data_b(backup_host_write_data),
    .wren_a(backup_write_enable),
    .wren_b(backup_host_write_enable),
    .q_a(backup_read_data),
    .q_b(backup_host_read_data),
    .byteena_a(1'b1),
    .byteena_b(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    backup_ram.address_reg_b = "CLOCK1",
    backup_ram.clock_enable_input_a = "BYPASS",
    backup_ram.clock_enable_input_b = "BYPASS",
    backup_ram.clock_enable_output_a = "BYPASS",
    backup_ram.clock_enable_output_b = "BYPASS",
    backup_ram.indata_reg_b = "CLOCK1",
    backup_ram.intended_device_family = "Cyclone V",
    backup_ram.lpm_type = "altsyncram",
    backup_ram.numwords_a = 512,
    backup_ram.numwords_b = 256,
    backup_ram.operation_mode = "BIDIR_DUAL_PORT",
    backup_ram.outdata_aclr_a = "NONE",
    backup_ram.outdata_aclr_b = "NONE",
    backup_ram.outdata_reg_a = "CLOCK0",
    backup_ram.outdata_reg_b = "UNREGISTERED",
    backup_ram.power_up_uninitialized = "FALSE",
    backup_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    backup_ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    backup_ram.width_a = 8,
    backup_ram.widthad_a = 9,
    backup_ram.width_b = 16,
    backup_ram.widthad_b = 8,
    backup_ram.width_byteena_a = 1,
    backup_ram.width_byteena_b = 1,
    backup_ram.wrcontrol_wraddress_reg_b = "CLOCK1";

nds_nitro_save_bridge save_bridge (
    .clk(clk_video),
    .reset(save_bridge_reset_video),
    .cart_download(save_cart_event_pulse),
    .img_mounted(save_mount_pulse),
    .img_readonly(save_mount_readonly),
    .img_size(save_mount_size),
    .backup_save_type(backup_save_type_sync_video),
    .backup_profile_valid(backup_profile_valid_sync_video),
    .backup_linear_addr(backup_addr),
    .backup_access_active(backup_access_active),
    .backup_write_toggle(backup_write_toggle),
    .save_ready(save_ready),
    .save_run_ready(save_run_ready_video),
    .backup_cache_ready(backup_cache_ready_video),
    .sd_lba(save_sd_lba),
    .sd_rd(save_sd_rd),
    .sd_wr(save_sd_wr),
    .sd_ack(save_sd_ack),
    .sd_buff_addr(save_sd_buff_addr),
    .sd_buff_dout(save_sd_buff_dout),
    .sd_buff_din(save_sd_buff_din),
    .sd_buff_wr(save_sd_buff_wr),
    .backup_host_addr(backup_host_addr),
    .backup_host_write_data(backup_host_write_data),
    .backup_host_write_enable(backup_host_write_enable),
    .backup_host_read_data(backup_host_read_data)
);

`ifdef NDS_HYBRID_3D
// requested_session is a trigger, not the published epoch.  A newly verified
// cartridge (including the first one after FPGA configuration) advances it.
// The DDR control initializer derives the persistent nonzero public session
// from its FPGA-owned word 14, so a same-RBF reload and a reconfiguration
// cannot accidentally reuse an HPS renderer generation.
logic [31:0] h3d_session_trigger;
logic h3d_cart_ready_d;
always_ff @(posedge ddr_clk or posedge bridge_reset_ddr) begin
    if (bridge_reset_ddr) begin
        h3d_session_trigger <= 32'd0;
        h3d_cart_ready_d <= 1'b0;
    end else begin
        h3d_cart_ready_d <= cart_loaded_ddr;
        if (cart_loaded_ddr && !h3d_cart_ready_d) begin
            if (h3d_session_trigger == 32'hffffffff)
                h3d_session_trigger <= 32'd1;
            else
                h3d_session_trigger <= h3d_session_trigger + 1'b1;
        end
    end
end
`endif

// hps_io registers these levels on clk_video/ddr_clk.  Buttons are slow and
// analog coordinates are held between reports, so a conventional two-stage
// level synchronizer is the complete shell-to-console input boundary.
(* async_reg = "true" *) logic [31:0] joystick_meta, joystick_sync;
(* async_reg = "true" *) logic [15:0] analog_meta, analog_sync;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        joystick_meta <= '0;
        joystick_sync <= '0;
        analog_meta <= '0;
        analog_sync <= '0;
    end else begin
        joystick_meta <= joystick;
        joystick_sync <= joystick_meta;
        analog_meta <= joystick_analog;
        analog_sync <= analog_meta;
    end
end

// Convert the public beta's right analog stick to native DS pixels for both
// the console and scanout pointer. Flipping X's sign bit maps -128..127 to
// 0..255; multiplying Y by 3/4 maps it to 0..191, centered at (128,96).
wire [7:0] touch_x = {~analog_sync[7],analog_sync[6:0]};
wire [7:0] touch_y_unscaled = {~analog_sync[15],analog_sync[14:8]};
wire [9:0] touch_y_scaled = {2'b00,touch_y_unscaled} +
                             {2'b00,touch_y_unscaled} +
                             {2'b00,touch_y_unscaled};
wire [7:0] touch_y = touch_y_scaled[9:2];

logic tgl_1x;
logic tgl_mem;
logic [1:0] clkMemIndex;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) tgl_1x <= 1'b0;
    else tgl_1x <= ~tgl_1x;
end
always_ff @(posedge clk_mem or posedge console_reset_mem) begin
    if (console_reset_mem) begin
        tgl_mem <= 1'b0;
        clkMemIndex <= 2'd0;
    end else begin
        tgl_mem <= tgl_1x;
        if (tgl_mem != tgl_1x) clkMemIndex <= 2'd1;
        else clkMemIndex <= clkMemIndex == IDX_ACCEPT[1:0]
            ? 2'd0 : clkMemIndex + 1'b1;
    end
end

// The retained hps_io load-address form stages the image directly at HPS DDR
// byte 0x30000000.  CART_READY is the only valid/public cartridge epoch.

(* async_reg = "true" *) logic [1:0] cart_loaded_sync;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) cart_loaded_sync <= 2'b00;
    else cart_loaded_sync <= {cart_loaded_sync[0], cart_loaded_ddr};
end
always_comb begin
    cart_loaded = cart_loaded_sync[1];
    ioctl_wait = 1'b0;
end
wire nds_on = cart_loaded_sync[1] && !console_reset_1x;

// Card request/response toggle bridge: the donor card port permits one
// outstanding word, so payloads stay stable until the acknowledgement returns.
wire card_ena;
wire [24:0] card_addr;
logic [31:0] card_din;
logic card_done;
logic [24:0] card_addr_hold;
logic card_req_toggle;
(* async_reg = "true" *) logic [2:0] card_rsp_sync;
logic card_rsp_toggle;
logic [31:0] card_rsp_data;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        card_addr_hold <= '0;
        card_req_toggle <= 1'b0;
        card_rsp_sync <= '0;
        card_din <= '0;
        card_done <= 1'b0;
    end else begin
        card_done <= 1'b0;
        card_rsp_sync <= {card_rsp_sync[1:0], card_rsp_toggle};
        if (card_ena) begin
            card_addr_hold <= card_addr;
            card_req_toggle <= ~card_req_toggle;
        end
        if (card_rsp_sync[2] != card_rsp_sync[1]) begin
            card_din <= card_rsp_data;
            card_done <= 1'b1;
        end
    end
end

(* async_reg = "true" *) logic [2:0] card_req_sync;
logic card_req_seen;
logic cd_busy;
logic cd_flush;
logic cd_req;
logic [24:0] cd_addr;
// ddram ch2 retains one aligned four-beat cartridge read-ahead line. Probe
// byte 0, then byte 32 (beat 4): the probes cannot share a line, so probe 1
// proves a real post-download DDR read displaced any stale pre-download line.
localparam logic [24:0] FLUSH_PROBE0_WORD = 25'd0;
localparam logic [24:0] FLUSH_PROBE1_WORD = 25'd8;
logic [1:0] flush_probe_count;
wire cd_ready;
wire [31:0] cd_dout;
always_ff @(posedge ddr_clk or posedge bridge_reset_ddr) begin
    if (bridge_reset_ddr) begin
        card_req_sync <= '0;
        card_req_seen <= 1'b0;
        card_rsp_toggle <= 1'b0;
        card_rsp_data <= '0;
        cd_busy <= 1'b0;
        cd_flush <= 1'b0;
        cd_req <= 1'b0;
        cd_addr <= '0;
        flush_probe_count <= 2'd0;
        flush_complete <= 1'b0;
    end else begin
        card_req_sync <= {card_req_sync[1:0], card_req_toggle};
        cd_req <= 1'b0;
        flush_complete <= 1'b0;

        // Start a new bridge epoch with the download.  While the console is
        // held reset, continuously consume/align any old toggle that was still
        // crossing so it cannot become the first request of the new image.
        if (cart_download_ddr && !cart_download_d) begin
            card_req_sync <= '0;
            card_req_seen <= 1'b0;
            card_rsp_toggle <= 1'b0;
            flush_probe_count <= 2'd0;
        end else if (cart_state != CART_READY) begin
            card_req_seen <= card_req_sync[2];
        end

        if (cart_state != CART_FLUSH) flush_probe_count <= 2'd0;

        if (!cd_busy) begin
            // Both probes win over card requests. Do not launch one on the
            // first edge of a replacement download; any already-outstanding
            // probe may drain, but its completion cannot qualify that epoch.
            if ((cart_state == CART_FLUSH) && !cart_download_raw &&
                !cart_download_ddr && (flush_probe_count != 2'd2)) begin
                cd_addr <= (flush_probe_count == 2'd0)
                    ? FLUSH_PROBE0_WORD : FLUSH_PROBE1_WORD;
                cd_flush <= 1'b1;
                cd_req <= 1'b1;
                cd_busy <= 1'b1;
                flush_probe_count <= flush_probe_count + 1'b1;
            end else if ((cart_state == CART_READY) && !cart_download_raw &&
                         !cart_download_ddr &&
                         (card_req_sync[2] != card_req_seen)) begin
                card_req_seen <= card_req_sync[2];
                cd_addr <= card_addr_hold;
                cd_flush <= 1'b0;
                cd_req <= 1'b1;
                cd_busy <= 1'b1;
            end
        end else if (cd_ready) begin
            cd_busy <= 1'b0;
            if (cd_flush) begin
                if ((flush_probe_count == 2'd2) && !cart_download_raw &&
                    !cart_download_ddr)
                    flush_complete <= 1'b1;
            end else if ((cart_state == CART_READY) && !cart_download_raw &&
                         !cart_download_ddr) begin
                card_rsp_data <= cd_dout;
                card_rsp_toggle <= ~card_rsp_toggle;
            end
        end
    end
end

// Direct HLE boot still probes SPI firmware.  The first beta intentionally has
// no RTC/firmware service; acknowledge a zero word one clk1x later, matching
// the inert fixture used by the focused donor simulation.
wire [15:0] fw_addr_unused;
wire fw_req;
logic fw_done;
logic [31:0] fw_data;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        fw_done <= 1'b0;
        fw_data <= 32'd0;
    end else begin
        fw_done <= fw_req;
        fw_data <= 32'd0;
    end
end

////////////////////////////  SDRAM  ////////////////////////////////////

// SDRAM map (v1): VRAM banks A..D at 0x000000..0x07FFFF (bank * 128 KB),
// 4 MB main RAM at 0x800000 (nds_top's Softmap_NDS_MAINRAM_ADDR default).
//
// ch2 (32-bit r/w + byte enables) is shared: main RAM normally owns it; the
// CPU VRAM channel (vsrv) borrows it through the allow/busy scheduler
// handshake. The renderer VRAM feed (vrsrv, read-only) lives on ch1 and
// never needs the scheduler - sdram.sv serializes the channels internally.
// Refresh: sdram.sv self-refreshes when idle (refresh_req tied low), so
// mainram_allow only gates the vsrv borrow, not refresh.

wire        mr_ena, mr_rnw;
wire [26:0] mr_adr;
wire [31:0] mr_din;
wire  [3:0] mr_be;
wire        mainram_active, mainram_busy;
reg         mainram_allow = 1;

// core-side VRAM channels (clk1x domain, req pulse -> done pulse)
wire        vsrv_req_c, vsrv_rnw_c;
wire  [1:0] vsrv_bank_c;
wire [14:0] vsrv_addr_c;
wire  [3:0] vsrv_be_c;
wire [31:0] vsrv_din_c;
wire        vrsrv_req_c;
wire  [1:0] vrsrv_bank_c;
wire [13:0] vrsrv_addr_c;
wire        vrsrv_ready_c;

reg  [31:0] vsrv_dout_r;
reg  [63:0] vrsrv_dout_r;   // 64-bit A..D line, see nds_vram's rsrv_* port
reg         vsrv_done_r,  vrsrv_done_r;

wire        sd_ch2_ready;
wire [31:0] sd_ch2_dout;
// the other half of the same ch2 burst - see rtl/sdram.sv ch2_dout_hi. Only
// main RAM consumes it; the vsrv side of this arbiter stays 32-bit.
wire [31:0] sd_ch2_dout_hi;
wire        sd_ch2_ready64;
wire        sd_ch1_ready;
wire [63:0] sd_ch1_dout;
wire        sd_ch1_accept;

// ---- vsrv arbiter: park main RAM, run one ch2 op, hand ch2 back ----
localparam A_IDLE  = 2'd0;
localparam A_DRAIN = 2'd1;
localparam A_WAIT  = 2'd2;

reg  [1:0] arb_state = A_IDLE;
reg        vs_req_d = 0, vs_pend = 0, vs_fin = 0;
reg        sd_vs_req = 0;
reg [26:0] vs_adr;
reg        vs_rnw;
reg  [3:0] vs_be;
reg [31:0] vs_din;
reg  [2:0] drain_cnt;

wire vs_owns = (arb_state == A_WAIT);
wire mr_done32 = sd_ch2_ready & ~vs_owns;
// Gated by the SAME vs_owns as done32: while the arbiter has parked main RAM
// and handed ch2 to vsrv, neither done belongs to us.
wire mr_done64 = sd_ch2_ready64 & ~vs_owns;

always @(posedge clk_mem or posedge console_reset_mem) begin
	if (console_reset_mem) begin
		arb_state <= A_IDLE;
		vs_req_d <= 0;
		vs_pend <= 0;
		vs_fin <= 0;
		sd_vs_req <= 0;
		vs_adr <= 0;
		vs_rnw <= 0;
		vs_be <= 0;
		vs_din <= 0;
		drain_cnt <= 0;
		mainram_allow <= 1;
		vsrv_dout_r <= 0;
		vsrv_done_r <= 0;
	end else begin
		vs_req_d  <= vsrv_req_c;
		sd_vs_req <= 0;

	// vsrv_req is clk1x-registered (CLKMEM_RATIO clkMem cycles wide) - edge detect
	if (vsrv_req_c & ~vs_req_d) begin
		vs_pend <= 1;
		vs_adr  <= {8'd0, vsrv_bank_c, vsrv_addr_c, 2'b00};
		vs_rnw  <= vsrv_rnw_c;
		vs_be   <= vsrv_be_c;
		vs_din  <= vsrv_din_c;
	end

	case (arb_state)
		A_IDLE: begin
			mainram_allow <= 1;
			if (vs_pend) begin
				mainram_allow <= 0;
				drain_cnt     <= 0;
				arb_state     <= A_DRAIN;
			end
		end

		A_DRAIN: begin
			// allow has been low through at least one full clk1x period and
			// no main-RAM op is in flight -> ch2 is ours
			// strictly MORE than one clk1x period of clkMem cycles, so the
			// count has to move with the ratio (it was a bare 4 at 3x, which
			// is exactly one period at 4x and no longer a full drain)
			if (~&drain_cnt) drain_cnt <= drain_cnt + 1'd1;
			if (!mainram_busy && drain_cnt >= CLKMEM_RATIO[2:0] + 3'd1) begin
				sd_vs_req <= 1;
				vs_pend   <= 0;
				arb_state <= A_WAIT;
			end
		end

		A_WAIT: begin
			if (sd_ch2_ready) begin
				vsrv_dout_r <= sd_ch2_dout;
				vs_fin      <= 1;
				arb_state   <= A_IDLE;
			end
		end

		default: arb_state <= A_IDLE;
	endcase

	// done pulse aligned to exactly one clk1x period: raise it during the
	// clkMem cycle whose end is the clk1x rising edge (index IDX_ACCEPT),
	// which means triggering one edge earlier, at IDX_DONE
	vsrv_done_r <= 0;
		if (vs_fin && clkMemIndex == IDX_DONE[1:0]) begin
			vsrv_done_r <= 1;
			vs_fin      <= 0;
		end
	end
end

// ---- vrsrv: renderer read feed on ch1 (no scheduler needed) ----
// sdram.sv's ch1 holds ONE request at a time (ch1_rq is a single bit), while
// nds_vram's renderer server issues its A..D reads pipelined. Without a ready
// line, every request arriving while ch1 was busy was simply dropped - the core
// would then wait forever for a word that was never asked for. So the channel
// exports back-pressure and the core throttles itself to what ch1 can actually
// take. Pipelining ch1 itself is a separate change and needs hardware to
// validate; this makes the current depth correct rather than lucky.
//
// req/ready is now a proper VALID/READY handshake: nds_vram HOLDS the request
// until an edge at which ready is high, and that edge is the transfer. It gave
// up pulsing because a pulse is issued on a ready sampled BEFORE the request
// exists, so its correctness depends on how fast ready falls after acceptance -
// see nds_vram's port comment for the drop that produced in simulation.
//
// This side had to change with it, and the edge detect it replaces is why:
// `vrsrv_req_c & ~vr_req_d` needs the request to go low between requests. A held
// request never does, so the first would have been taken and every later one
// silently ignored - a wedge on hardware only. It is not an independent fix.
//
// For both ends to agree on WHICH edge the transfer was, this side must sample
// the interface at exactly the edge the core does: IDX_ACCEPT is the clkMem edge
// coincident with the clk1x rising edge (see the counter's contract at the top of
// this file). Accepting at any other phase would take a request the core goes on
// holding, and then serve it twice - which is exactly why the index is derived
// from CLKMEM_RATIO rather than written as a literal 2.
//
// Note what is NOT claimed here. The old pulse scheme did not drop on hardware:
// the busy flag rose, and so ready fell, one clkMem cycle after acceptance, i.e.
// 1/CLKMEM_RATIO of a clk1x period before the core samples again - so the core
// never issued into a busy channel. It was correct by a coincidence between two
// domains, and this removes the reliance on it rather than fixing a silicon bug.
// The hardware white screen was a livelock in nds_gpu2d's drawline routing.
//
// It also removes the need to latch a dropped request the way the firmware
// channel does with fwr_pend: with a held request there is nothing to drop.
// PIPELINED. This used to allow exactly one op in flight - ready went low at
// acceptance and stayed low until the done pulse had been presented - so every
// renderer read paid the full round trip: accept on a clk1x edge, ~11 clkMem of
// SDRAM, then wait for the next IDX_DONE and the next IDX_ACCEPT. Around 16
// clkMem cycles per op, of which the SDRAM only needed 8. nds_vram's rsrv port
// has always been pipelined (AD_DEPTH = 4, answered in issue order); this side
// was the whole restriction.
//
// Two outstanding is the useful maximum, and it is set by sdram.sv, not chosen:
// ch1_rq is a single bit, so the channel holds one request awaiting grant plus
// one in service. Beyond that a request would be dropped and the core would wait
// forever for a word nobody asked for.
//
// No response queue is needed, and that is worth stating because it looks like
// an omission. The controller's slot is 8 clkMem cycles (grant, WAIT, RW1, then
// IDLE_5..IDLE), so two ch1 completions can never be closer than that, while a
// held response is presented at the next IDX_DONE, at most CLKMEM_RATIO-1 cycles
// away. vr_fin can therefore never still be occupied when the next response
// lands. Anything that delays a grant - refresh, ch2 traffic - only widens the
// gap.
reg        vr_pend = 0;    // request presented to ch1, not yet granted
reg  [1:0] vr_out  = 0;    // granted or presented, data not yet returned
reg        vr_fin  = 0;
reg        sd_vr_req = 0;
reg [25:0] vr_adr;

// A clk1x-observable level, as before. Low while a request is still awaiting
// grant (vr_adr must hold until then - ch1 samples the address live), and low
// once two ops are outstanding.
assign vrsrv_ready_c = ~vr_pend & (vr_out < 2'd2);

always @(posedge clk_mem or posedge console_reset_mem) begin
	if (console_reset_mem) begin
		vr_pend <= 0;
		vr_out <= 0;
		vr_fin <= 0;
		sd_vr_req <= 0;
		vr_adr <= 0;
		vrsrv_dout_r <= 0;
		vrsrv_done_r <= 0;
	end else begin
		sd_vr_req <= 0;

	// grant clears the pending slot first, so that if it ever coincided with an
	// acceptance the acceptance would win. It cannot today: ready is low while
	// vr_pend is set, so no new request is taken until the grant is seen.
	if (sd_ch1_accept) vr_pend <= 0;

	if (vrsrv_req_c & vrsrv_ready_c & (clkMemIndex == IDX_ACCEPT[1:0])) begin
		// halfword addr [26:1]; the line address makes it 8-byte aligned, which is
		// what lets the whole burst be used - a sequential SDRAM burst wraps inside
		// its aligned block, so an unaligned request returns these same eight bytes
		// rotated and dout[63:32] would not be the neighbouring word.
		vr_adr    <= {8'd0, vrsrv_bank_c, vrsrv_addr_c, 2'b00};
		sd_vr_req <= 1;
		vr_pend   <= 1;
		if (!sd_ch1_ready) vr_out <= vr_out + 2'd1;
	end
	else if (sd_ch1_ready) vr_out <= vr_out - 2'd1;

	if (sd_ch1_ready) begin
		vrsrv_dout_r <= sd_ch1_dout;   // the whole aligned 8-byte line
		vr_fin       <= 1;
	end

	vrsrv_done_r <= 0;
		if (vr_fin && clkMemIndex == IDX_DONE[1:0]) begin
			vrsrv_done_r <= 1;
			vr_fin       <= 0;
		end
	end
end

// The SDRAM controller's three clock-rate-dependent knobs, all derived from the
// one ratio. At 3x these are the values the file has always had, so 3x builds
// are unchanged. At 4x:
//   DQ_PIPE     splits the pin-capture -> ch*_dout hop, which is ~5.8ns of pure
//               interconnect with zero logic in it and the worst path in the fit
//   CAS_LATENCY the part needs 3 above 100MHz, per the controller's own comment
//   TRCD_WAIT   2 clocks of ACTIVE->READ is 14.9ns at 134MHz, under tRCD
// The last two are chip-protocol, invisible to STA: timing can close while the
// SDRAM returns wrong data. See sim/run_sdram_ch.sh.
sdram #(
	.DQ_PIPE    (CLKMEM_RATIO >= 4 ? 1 : 0),
	.CAS_LATENCY(CLKMEM_RATIO >= 4 ? 3 : 2),
	.TRCD_WAIT  (CLKMEM_RATIO >= 4 ? 2 : 1)
) sdram
(
	.*,
	.init(~pll_locked),
	.clk(clk_mem),

	.refresh_req(1'b0),          // controller self-refreshes when idle

	.ch1_addr(vr_adr),
	.ch1_din(16'd0),
	.ch1_dout(sd_ch1_dout),
	.ch1_req(sd_vr_req),
	.ch1_rnw(1'b1),
	.ch1_ready(sd_ch1_ready),
	.ch1_accept(sd_ch1_accept),

	.ch2_addr  (vs_owns ? vs_adr[26:1] : mr_adr[26:1]),
	.ch2_din   (vs_owns ? vs_din       : mr_din),
	.ch2_be    (vs_owns ? vs_be        : mr_be),
	.ch2_dout  (sd_ch2_dout),
	.ch2_req   (sd_vs_req | mr_ena),
	.ch2_cancel(1'b0),
	.ch2_rnw   (vs_owns ? vs_rnw       : mr_rnw),
	.ch2_ready (sd_ch2_ready),
	.ch2_ready16(),
	.ch2_dout_hi(sd_ch2_dout_hi),
	.ch2_ready64(sd_ch2_ready64),

	.ch3_addr(24'd0),
	.ch3_din(16'd0),
	.ch3_dout(),
	.ch3_req(1'b0),
	.ch3_rnw(1'b1),
	.ch3_ready()
);


// Pixel streams cross once into the retained 60 MHz DDR domain.  Both engines
// are packed into one record so simultaneous writes cannot reorder.
wire [7:0] pix_x, pix_y, pixb_x, pixb_y;
wire [17:0] pix_d, pixb_d;
wire pix_we, pixb_we;
wire [69:0] pixel_fifo_write =
    {pixb_we,pixb_d,pixb_y,pixb_x,pix_we,pix_d,pix_y,pix_x};
wire [69:0] pixel_fifo_read;
wire pixel_fifo_full, pixel_fifo_empty, pixel_fifo_valid, pixel_fifo_overflow;
nds_nitro_async_fifo #(.WIDTH(70), .LGDEPTH(4)) pixel_boundary (
    .write_clk(clk1x), .write_reset(console_reset_1x),
    .write_enable(pix_we | pixb_we), .write_data(pixel_fifo_write),
    .write_full(pixel_fifo_full), .write_overflow(pixel_fifo_overflow),
    .read_clk(ddr_clk), .read_reset(console_reset_ddr),
    .read_enable(!pixel_fifo_empty), .read_data(pixel_fifo_read),
    .read_valid(pixel_fifo_valid), .read_empty(pixel_fifo_empty)
);
(* async_reg = "true" *) logic [1:0] pixel_overflow_sync;
always_ff @(posedge ddr_clk or posedge console_reset_ddr) begin
    if (console_reset_ddr) begin
        pixel_overflow_sync <= 2'b00;
    end else begin
        pixel_overflow_sync <= {pixel_overflow_sync[0],pixel_fifo_overflow};
    end
end
// Keep a fatal product-path indication visible while its own console reset is
// asserted. Only the independent bridge reset begins a new diagnostic epoch.
always_ff @(posedge ddr_clk or posedge bridge_reset_ddr) begin
    if (bridge_reset_ddr)
        boundary_fault <= 1'b0;
    else if (pixel_overflow_sync[1] || h3d_boundary_fatal)
        boundary_fault <= 1'b1;
end
wire fb_pix_we = pixel_fifo_valid && pixel_fifo_read[34];
wire [17:0] fb_pix_d = pixel_fifo_read[33:16];
wire [7:0] fb_pix_y = pixel_fifo_read[15:8];
wire [7:0] fb_pix_x = pixel_fifo_read[7:0];
wire fb_pixb_we = pixel_fifo_valid && pixel_fifo_read[69];
wire [17:0] fb_pixb_d = pixel_fifo_read[68:51];
wire [7:0] fb_pixb_y = pixel_fifo_read[50:43];
wire [7:0] fb_pixb_x = pixel_fifo_read[42:35];

// The production image keeps all telemetry off.  A temporary diagnostic image
// can enable NDS_BOOT_DIAGNOSTIC together with the framebuffer's legacy debug
// lane.  Snapshot the live clk1x signals slowly, then hold them across a normal
// two-stage DDR-domain synchronizer so the twelve published pixels are coherent
// enough to distinguish reset/loader state from a running CPU.  This cone is
// absent when NDS_BOOT_DIAGNOSTIC is not defined.
wire [31:0] dbg_pc9_diag, dbg_pc7_diag, dbg_r0_diag;
wire [31:0] dbg_lr_diag, dbg_cpsr_diag, dbg_vfy_addr_unused;
wire [17:0] dbg_vfy_bad_unused, dbg_hwstat_diag;
wire [31:0] dbg_rsp_unused;
wire dbg_rsp_stb_unused;
`ifdef NDS_BOOT_DIAGNOSTIC
logic [15:0] diag_sample_div9, diag_sample_div7;
logic [31:0] diag_pc9_hold, diag_pc7_hold, diag_r0_hold;
logic [31:0] diag_lr_hold;
logic [17:0] diag_hwstat_hold;
logic [17:0] diag_heartbeat;
(* async_reg = "true" *) logic [31:0] diag_pc9_meta, diag_pc9_ddr;
(* async_reg = "true" *) logic [31:0] diag_pc7_meta, diag_pc7_ddr;
(* async_reg = "true" *) logic [31:0] diag_r0_meta, diag_r0_ddr;
(* async_reg = "true" *) logic [31:0] diag_lr_meta, diag_lr_ddr;
(* async_reg = "true" *) logic [17:0] diag_hwstat_meta, diag_hwstat_ddr;

// ARM9 taps originate on clk2x. Latch the complete bundle in that source
// domain before it enters the slow, held snapshot crossing.
always_ff @(posedge clk2x or posedge console_reset_2x) begin
    if (console_reset_2x) begin
        diag_sample_div9 <= '0;
        diag_pc9_hold <= '0;
        diag_r0_hold <= '0;
        diag_lr_hold <= '0;
    end else begin
        diag_sample_div9 <= diag_sample_div9 + 1'b1;
        if (&diag_sample_div9) begin
            diag_pc9_hold <= dbg_pc9_diag;
            diag_r0_hold <= dbg_r0_diag;
            diag_lr_hold <= dbg_lr_diag;
        end
    end
end

always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        diag_sample_div7 <= '0;
        diag_pc7_hold <= '0;
        diag_hwstat_hold <= '0;
    end else begin
        diag_sample_div7 <= diag_sample_div7 + 1'b1;
        if (&diag_sample_div7) begin
            diag_pc7_hold <= dbg_pc7_diag;
            diag_hwstat_hold <= dbg_hwstat_diag;
        end
    end
end

// The diagnostic publisher and heartbeat intentionally use bridge_reset_ddr,
// which stays released during CART_DOWNLOAD/CART_FLUSH. This makes a reset or
// flush stall observable instead of silencing the diagnostic channel.
always_ff @(posedge ddr_clk or posedge bridge_reset_ddr) begin
    if (bridge_reset_ddr) begin
        diag_heartbeat <= '0;
        diag_pc9_meta <= '0; diag_pc9_ddr <= '0;
        diag_pc7_meta <= '0; diag_pc7_ddr <= '0;
        diag_r0_meta <= '0; diag_r0_ddr <= '0;
        diag_lr_meta <= '0; diag_lr_ddr <= '0;
        diag_hwstat_meta <= '0; diag_hwstat_ddr <= '0;
    end else begin
        diag_heartbeat <= diag_heartbeat + 1'b1;
        diag_pc9_meta <= diag_pc9_hold; diag_pc9_ddr <= diag_pc9_meta;
        diag_pc7_meta <= diag_pc7_hold; diag_pc7_ddr <= diag_pc7_meta;
        diag_r0_meta <= diag_r0_hold; diag_r0_ddr <= diag_r0_meta;
        diag_lr_meta <= diag_lr_hold; diag_lr_ddr <= diag_lr_meta;
        diag_hwstat_meta <= diag_hwstat_hold;
        diag_hwstat_ddr <= diag_hwstat_meta;
    end
end

wire [17:0] diag_lifecycle = {
    cart_state, flush_probe_count, flush_complete,
    cart_download_raw, cart_download_ddr, cart_loaded_ddr,
    cart_loaded_sync[1], nds_on, console_reset_request, console_reset_1x,
    bridge_reset_ddr, pll_locked, enable, shell_reset, boot_done, boot_error
};
`endif

localparam [27:1] FB_HW_BASE = 27'h7f00000;
localparam [7:0] FB_BURST = 8'd128;
wire [27:1] fb5_addr, fb6_addr;
wire [63:0] fb5_din, fb6_dout;
wire fb5_req, fb5_next, fb5_ready;
wire fb6_req, fb6_valid, fb6_ready;
logic pf_tgl, pf_scr, pf_bank;
logic [1:0] pf_frame_bank;
logic [7:0] pf_line;
logic [8:0] lb_raddr;
wire [35:0] lb_q;
wire fb_published_frame_toggle;
wire [1:0] fb_published_frame_bank;
logic effective_3d_frame_toggle;
wire [7:0] h3d_scanout_late_count;
wire [9:0] h3d_fb_fault_flags;
wire [27:0] h3d_fb_bank_diagnostic;
`ifdef NDS_HYBRID_3D
// H3D uses a physical 2 MiB window immediately below the proven framebuffer:
// control at 0x3fc00000, four packet slots at 0x3fc10000..0x3fc4ffff,
// and raw plane banks at 0x3fd00000/0x3fd40000.
// These are physical 64-bit word addresses because the outer fabric sits
// after the legacy ddram controller's built-in 0x30000000 translation.
localparam logic [28:0] H3D_CONTROL_WORD = 29'h07f80000;
localparam logic [28:0] H3D_SLOT_WORD    = 29'h07f82000;
localparam logic [28:0] H3D_BANK0_WORD   = 29'h07fa0000;
localparam logic [28:0] H3D_BANK1_WORD   = 29'h07fa8000;

wire h3d_control_active, h3d_control_initialized, h3d_control_fault;
wire h3d_control_release;
wire [31:0] h3d_active_session, h3d_control_fault_bits;
wire [2:0] h3d_telemetry_index;
wire h3d_diagnostic_hold_ddr;
wire h3d_control_read, h3d_control_write;
wire [7:0] h3d_control_burst;
wire [28:0] h3d_control_addr;
wire [63:0] h3d_control_din;
wire [7:0] h3d_control_be;
wire h3d_control_busy, h3d_control_command_accepted;
wire [63:0] h3d_control_dout;
wire h3d_control_dout_ready;

// The public crash hold is a bounded DDR-domain lease. Synchronize the level
// independently into each CPU domain; release is guaranteed by the control
// block even if the requesting HPS process disappears during capture.
(* async_reg = "true" *) logic [1:0] h3d_hold_sync_1x;
(* async_reg = "true" *) logic [1:0] h3d_hold_sync_2x;
logic h3d_hold_previous_1x, h3d_hold_previous_2x;
always_ff @(posedge clk1x or posedge bridge_reset_request) begin
    if (bridge_reset_request) begin
        h3d_hold_sync_1x <= 2'b00;
        h3d_hold_previous_1x <= 1'b0;
    end else begin
        h3d_hold_sync_1x <= {
            h3d_hold_sync_1x[0], h3d_diagnostic_hold_ddr
        };
        h3d_hold_previous_1x <= h3d_hold_sync_1x[1];
    end
end
always_ff @(posedge clk2x or posedge bridge_reset_request) begin
    if (bridge_reset_request) begin
        h3d_hold_sync_2x <= 2'b00;
        h3d_hold_previous_2x <= 1'b0;
    end else begin
        h3d_hold_sync_2x <= {
            h3d_hold_sync_2x[0], h3d_diagnostic_hold_ddr
        };
        h3d_hold_previous_2x <= h3d_hold_sync_2x[1];
    end
end
wire h3d_diagnostic_release_1x =
    h3d_hold_previous_1x && !h3d_hold_sync_1x[1];
wire h3d_diagnostic_release_2x =
    h3d_hold_previous_2x && !h3d_hold_sync_2x[1];

wire h3d_record_valid, h3d_record_ready;
wire [127:0] h3d_record;
wire [31:0] h3d_record_frame;
wire h3d_record_frame_end;
wire h3d_boundary_valid, h3d_boundary_ready;
wire [31:0] h3d_boundary_frame;
wire h3d_record_source_active, h3d_record_ddr_active;
wire h3d_record_source_fault, h3d_record_ddr_fault;
wire [3:0] h3d_record_source_fault_reason, h3d_record_ddr_fault_reason;
wire [8:0] h3d_gx_fifo_level;
wire h3d_gx_fifo_empty, h3d_gx_fifo_below_half, h3d_gx_fifo_full;

wire h3d_packet_active, h3d_packet_full, h3d_packet_done;
wire h3d_packet_fault;
wire [4:0] h3d_packet_fault_reason;
wire [31:0] h3d_producer_sequence, h3d_consumer_sequence;
wire h3d_packet_read, h3d_packet_write;
wire [7:0] h3d_packet_burst;
wire [28:0] h3d_packet_addr;
wire [63:0] h3d_packet_din;
wire [7:0] h3d_packet_be;
wire h3d_packet_busy, h3d_packet_command_accepted;
wire [63:0] h3d_packet_dout;
wire h3d_packet_dout_ready;

wire h3d_plane_read, h3d_plane_write;
wire [7:0] h3d_plane_burst;
wire [28:0] h3d_plane_addr;
wire [63:0] h3d_plane_din;
wire [7:0] h3d_plane_be;
wire h3d_plane_busy, h3d_plane_command_accepted;
wire [63:0] h3d_plane_dout;
wire h3d_plane_dout_ready;
wire h3d_plane_ddr_active, h3d_plane_line_valid;
wire [1:0] h3d_plane_line_bank;
wire [31:0] h3d_plane_pixel_packed;
wire h3d_plane_pixel_valid;
wire h3d_plane_descriptor_request_ready, h3d_plane_line_request_ready;
wire h3d_plane_busy_state, h3d_plane_descriptor_busy;
wire h3d_plane_line_fetch_busy, h3d_plane_descriptor_accepted;
wire h3d_plane_descriptor_rejected, h3d_plane_line_loaded;
wire h3d_plane_line_missed, h3d_plane_descriptor_valid;
wire h3d_plane_pixel_line_missed;
wire [27:0] h3d_plane_frame_diagnostic;
wire [31:0] h3d_plane_descriptor_sequence, h3d_plane_descriptor_frame;
wire h3d_plane_descriptor_bank;
wire h3d_pixel_descriptor_valid, h3d_pixel_descriptor_pending;
wire [31:0] h3d_pixel_descriptor_sequence, h3d_pixel_descriptor_frame;
wire h3d_pixel_descriptor_bank;
wire h3d_full_frame_publish;
wire [1:0] h3d_full_frame_bank;
wire h3d_full_frame_adopted;

wire h3d_legacy_busy, h3d_legacy_command_accepted;
wire [63:0] h3d_legacy_dout;
wire h3d_legacy_dout_ready;
wire h3d_fabric_epoch_quiescent, h3d_fabric_protocol_error;
wire [31:0] h3d_fabric_debug;
wire h3d_physical_read, h3d_physical_write;
wire [7:0] h3d_physical_burst;
wire [28:0] h3d_physical_addr;
wire [63:0] h3d_physical_din;
wire [7:0] h3d_physical_be;
// Control/HPS readiness first releases the H3D transports. The CPUs remain
// reset until the source-side CDC has also observed both clock domains, so
// no early GX/VRAM write can slip through legacy unclaimed-IO behavior.
wire h3d_path_reset = bridge_reset_ddr | ~h3d_control_release;
assign h3d_console_release =
    h3d_control_release && h3d_record_source_active;
// Do not reset the outer owner table after configuration.  The legacy ddram
// block has no reset port and may still be streaming a write or waiting for a
// response during a shell reset or a transient PLL unlock; the fabric must
// preserve that ownership and drain it before exposing another client.  The
// FPGA power-up value supplies exactly one synchronous reset edge when the
// retained DDR clock first becomes live.  H3D clients reset independently and
// ignore any drained response belonging to their old epoch.
logic h3d_fabric_boot_reset = 1'b1;
always_ff @(posedge ddr_clk) begin
    if (island_locked)
        h3d_fabric_boot_reset <= 1'b0;
end
wire h3d_fabric_reset = h3d_fabric_boot_reset;

// Held clk1x product seam exported by the mixed-language console wrapper.
wire h3d_gpu_write_valid, h3d_gpu_write_ready;
wire [27:0] h3d_gpu_write_address;
wire [1:0] h3d_gpu_write_access;
wire [3:0] h3d_gpu_write_byte_enable;
wire [31:0] h3d_gpu_write_data, h3d_gpu_write_frame;
wire [63:0] h3d_gpu_write_timestamp;
wire h3d_vram9_write_valid, h3d_vram9_write_ready;
wire [31:0] h3d_vram9_write_address, h3d_vram9_write_data;
wire [31:0] h3d_vram9_write_frame;
wire [1:0] h3d_vram9_write_access;
wire [3:0] h3d_vram9_write_byte_enable;
wire [63:0] h3d_vram9_write_timestamp;
wire h3d_vram7_write_valid, h3d_vram7_write_ready;
wire [31:0] h3d_vram7_write_address, h3d_vram7_write_data;
wire [31:0] h3d_vram7_write_frame;
wire [1:0] h3d_vram7_write_access;
wire [3:0] h3d_vram7_write_byte_enable;
wire [63:0] h3d_vram7_write_timestamp;
wire h3d_hblank_valid, h3d_hblank_ready;
wire h3d_hblank_ready_unused;
wire [8:0] h3d_hblank_line;
wire [31:0] h3d_hblank_frame;
wire [63:0] h3d_hblank_timestamp;
wire h3d_frame_valid, h3d_frame_ready;
wire [31:0] h3d_frame_number, h3d_current_frame;
wire [63:0] h3d_frame_timestamp, h3d_timestamp_live;
wire h3d_console_source_fault;
wire h3d_core_line_drop;
wire [31:0] h3d_bg1_scroll_triplet;
(* async_reg = "true" *) logic [31:0] h3d_bg1_scroll_meta_ddr;
(* async_reg = "true" *) logic [31:0] h3d_bg1_scroll_ddr;

logic [7:0] h3d_line_drop_count_1x;
logic [7:0] h3d_plane_deadline_count_1x;
(* async_reg = "true" *) logic [7:0] h3d_line_drop_meta_ddr;
(* async_reg = "true" *) logic [7:0] h3d_line_drop_count_ddr;
(* async_reg = "true" *) logic [7:0] h3d_plane_deadline_meta_ddr;
(* async_reg = "true" *) logic [7:0] h3d_plane_deadline_count_ddr;
(* async_reg = "true" *) logic [27:0] h3d_plane_frame_diagnostic_meta_ddr;
(* async_reg = "true" *) logic [27:0] h3d_plane_frame_diagnostic_ddr;
logic [7:0] h3d_plane_miss_count_ddr;

always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        h3d_line_drop_count_1x <= 8'd0;
        h3d_plane_deadline_count_1x <= 8'd0;
    end else if (h3d_core_line_drop && h3d_line_drop_count_1x != 8'hff) begin
        h3d_line_drop_count_1x <= h3d_line_drop_count_1x + 1'b1;
    end else if (h3d_plane_pixel_line_missed &&
                 h3d_plane_deadline_count_1x != 8'hff) begin
        h3d_plane_deadline_count_1x <=
            h3d_plane_deadline_count_1x + 1'b1;
    end
end

always_ff @(posedge ddr_clk or posedge console_reset_ddr) begin
    if (console_reset_ddr) begin
        h3d_bg1_scroll_meta_ddr <= 32'd0;
        h3d_bg1_scroll_ddr <= 32'd0;
        h3d_line_drop_meta_ddr <= 8'd0;
        h3d_line_drop_count_ddr <= 8'd0;
        h3d_plane_deadline_meta_ddr <= 8'd0;
        h3d_plane_deadline_count_ddr <= 8'd0;
        h3d_plane_frame_diagnostic_meta_ddr <= 28'd0;
        h3d_plane_frame_diagnostic_ddr <= 28'd0;
        h3d_plane_miss_count_ddr <= 8'd0;
    end else begin
        h3d_bg1_scroll_meta_ddr <= h3d_bg1_scroll_triplet;
        h3d_bg1_scroll_ddr <= h3d_bg1_scroll_meta_ddr;
        h3d_line_drop_meta_ddr <= h3d_line_drop_count_1x;
        h3d_line_drop_count_ddr <= h3d_line_drop_meta_ddr;
        h3d_plane_deadline_meta_ddr <= h3d_plane_deadline_count_1x;
        h3d_plane_deadline_count_ddr <= h3d_plane_deadline_meta_ddr;
        h3d_plane_frame_diagnostic_meta_ddr <=
            h3d_plane_frame_diagnostic;
        h3d_plane_frame_diagnostic_ddr <=
            h3d_plane_frame_diagnostic_meta_ddr;
        if (h3d_plane_descriptor_valid && h3d_plane_line_missed &&
            h3d_plane_miss_count_ddr != 8'hff)
            h3d_plane_miss_count_ddr <= h3d_plane_miss_count_ddr + 1'b1;
    end
end

// White-screen diagnostic: publish the live architectural ARM9 PC through
// the already-polled FPGA heartbeat word. This changes no CPU, renderer,
// packet, or display behavior and lets the read-only board monitor identify
// the exact stuck control-flow location.
// A running CPU publishes its architectural PC exactly as before.  If the PC
// is still zero, use the same word as a compact boot-stall receipt instead of
// losing every upstream state bit behind an indistinguishable zero.  The 0xd
// signature cannot be a valid ARM9 PC in this core's mapped execution regions.
wire [31:0] fb_runtime_heartbeat = dbg_pc9_diag != 0 ? dbg_pc9_diag : {
    4'hd,
    h3d_control_release, h3d_record_source_active, h3d_console_release,
    console_reset_request, console_reset_1x, cart_loaded_ddr,
    cart_loaded_sync[1], nds_on, bridge_reset_ddr, h3d_path_reset,
    dbg_hwstat_diag
};
// Passive renderer line-30 receipt. F[27:0] carries the accepted BG1HOFS,
// queued/direct identity, and register-shadow comparison. Normal samples retain
// the final-pixel row hash; a no-BG1-write sample substitutes the DMA grant
// blocker's actual accepted ARM9 membus state, age, and address. The
// observational heartbeat does not alter rendering, DMA, framebuffer
// publication, or display handshakes.
`ifdef NDS_SEAM_DIAGNOSTIC
// Sound bring-up diagnostic: Beta 78 proved the H3D transport, return plane,
// and framebuffer were live while the console emitted empty frames. Publish
// the existing architectural ARM9 PC tap so the next board run identifies the
// exact upstream boot wait without changing any emulation behavior.
wire [31:0] h3d_diagnostic_heartbeat = {4'h9, dbg_pc9_diag[27:0]};
`else
wire [31:0] h3d_diagnostic_heartbeat = fb_runtime_heartbeat;
`endif

// Slowly rotating, tagged public crash telemetry. The control block retains
// each selection across 8192 complete header sweeps, allowing the HPS's low-
// overhead 100 ms recorder to collect full CPU/subsystem context over time.
// PC/address values use their architecturally meaningful low 28 bits. CPSR
// keeps NZCV plus bits 23:0; ARMv5 bits 27:24 are unused/reserved here.
logic [31:0] h3d_public_crash_telemetry;
always_comb begin
    case (h3d_telemetry_index)
        3'd0: h3d_public_crash_telemetry =
            {4'h1, dbg_pc7_diag[27:0]};
        3'd1: h3d_public_crash_telemetry =
            {4'h2, dbg_r0_diag[27:0]};
        3'd2: h3d_public_crash_telemetry =
            {4'h3, dbg_lr_diag[27:0]};
        3'd3: h3d_public_crash_telemetry =
            {4'h4, dbg_cpsr_diag[31:28], dbg_cpsr_diag[23:0]};
        3'd4: h3d_public_crash_telemetry = {
            4'h5, h3d_gx_fifo_full, h3d_gx_fifo_level,
            dbg_hwstat_diag
        };
        3'd5: h3d_public_crash_telemetry = {
            4'h6, 9'd0,
            boundary_fault, h3d_fabric_protocol_error,
            h3d_fabric_epoch_quiescent, h3d_control_fault,
            h3d_control_release, h3d_record_source_active,
            h3d_record_source_fault, h3d_record_ddr_active,
            h3d_record_ddr_fault, h3d_packet_active,
            h3d_packet_full, h3d_packet_fault,
            h3d_plane_busy_state, h3d_plane_descriptor_busy,
            h3d_plane_line_fetch_busy, h3d_plane_descriptor_valid,
            h3d_pixel_descriptor_pending, h3d_diagnostic_hold_ddr,
            cart_loaded_ddr
        };
        3'd6: h3d_public_crash_telemetry =
            {4'h7, h3d_fabric_debug[27:0]};
        default: h3d_public_crash_telemetry = {
            4'h8, h3d_line_drop_count_ddr,
            h3d_plane_deadline_count_ddr, h3d_plane_miss_count_ddr,
            h3d_record_ddr_fault_reason
        };
    endcase
end
// The return plane is derived display data and may complete after its source
// frame has advanced.  Once a current-session descriptor crosses, keep its
// complete plane visible until a newer descriptor replaces it; the reader's
// sequence/session/bank/Y tags still reject every stale or torn line bundle.
wire [31:0] h3d_plane_display_frame = h3d_pixel_descriptor_valid
    ? h3d_pixel_descriptor_frame : h3d_current_frame;

// Only loss or corruption of the authoritative ordered input stream is fatal.
// The HPS return plane is derived display data: a late/missing plane line or a
// dropped 2D render line is already represented by a transparent/old pixel
// and can recover on a later line or frame.  Resetting both CPUs for such a
// display miss turns recoverable backpressure into a permanent boot failure.
(* async_reg = "true" *) logic [1:0] h3d_source_fault_sync_ddr;
always_ff @(posedge ddr_clk or posedge bridge_reset_ddr) begin
    if (bridge_reset_ddr) begin
        h3d_source_fault_sync_ddr <= 2'b00;
        h3d_external_fault_bits <= 32'd0;
    end else begin
        h3d_source_fault_sync_ddr <= {
            h3d_source_fault_sync_ddr[0], h3d_console_source_fault
        };
        if (cart_loaded_ddr && !h3d_cart_ready_d) begin
            h3d_external_fault_bits <= 32'd0;
        end else begin
            h3d_external_fault_bits <= h3d_external_fault_bits |
                (h3d_source_fault_sync_ddr[1] ? 32'h00000100 : 32'd0) |
                (h3d_record_ddr_fault ?
                    (32'h00000200 |
                     {16'd0, h3d_record_ddr_fault_reason, 12'd0}) : 32'd0) |
                (h3d_packet_fault ?
                    (32'h00000400 |
                     {11'd0, h3d_packet_fault_reason, 16'd0}) : 32'd0) |
                (h3d_fabric_protocol_error ? 32'h00000800 : 32'd0);
        end
    end
end

wire h3d_core_line_request;
wire [7:0] h3d_core_line_y;
wire h3d_core_line_start, h3d_core_line_end;
wire [7:0] h3d_core_merge_x, h3d_core_merge_y;
// Descriptor publication is asynchronous to scanout.  Promote a completed
// replacement only after the last visible line has finished, not on an edge
// of the queued architectural-boundary valid signal: that valid may remain
// asserted across several queued VBlanks and therefore has no per-frame edge.
wire h3d_scanout_frame_boundary = h3d_core_line_end &&
    h3d_core_merge_y == 8'd191;
logic h3d_descriptor_request;
logic [11:0] h3d_descriptor_retry;
logic h3d_line_pending;
logic [31:0] h3d_line_pending_frame;
logic [7:0] h3d_line_pending_y;
logic [31:0] h3d_line_seed_sequence;
logic [1:0] h3d_line_seed_remaining;
// The proven 2D renderer reports the line it has just accepted.  Translate
// that observational tap here, outside the renderer, into a two-line-ahead
// H3D prefetch.  With three line banks this gives DDR one complete intervening
// scanline to absorb arbitration jitter; 190/191 seed lines 0/1 of the next
// visible frame.
wire [7:0] h3d_line_prefetch_y = h3d_core_line_y == 8'd190 ? 8'd0 :
    h3d_core_line_y == 8'd191 ? 8'd1 : h3d_core_line_y + 8'd2;
(* async_reg = "true" *) logic [31:0] h3d_session_meta_1x;
(* async_reg = "true" *) logic [31:0] h3d_session_sync_1x;
`endif

// Count the 3D frames that truly reach the merge pixel domain.  The HPS
// publication sequence may advance asynchronously and the 2D framebuffer
// continues at the DS raster cadence, so neither is by itself an honest 3D
// FPS source.  A local toggle per newly activated descriptor gives scanout a
// tiny CDC-safe event stream without adding counters to the hot HPS path.
`ifdef NDS_HYBRID_3D
logic [31:0] effective_3d_sequence_seen;
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        effective_3d_sequence_seen <= 32'd0;
        effective_3d_frame_toggle <= 1'b0;
    end else if (h3d_pixel_descriptor_valid &&
                 h3d_pixel_descriptor_sequence !=
                    effective_3d_sequence_seen) begin
        effective_3d_sequence_seen <= h3d_pixel_descriptor_sequence;
        effective_3d_frame_toggle <= ~effective_3d_frame_toggle;
    end
end
`else
always_comb effective_3d_frame_toggle = fb_published_frame_toggle;
`endif

nds_nitro_fb_ddr3 #(
    .FB_HW_BASE(FB_HW_BASE), .FB_BURST(FB_BURST),
    // Keep the large per-pixel content-hash telemetry cone out of this nearly
    // full device; the two compact counters above are the live diagnostic.
    .RUNTIME_TELEMETRY(1'b0)
) framebuffer (
    .clk_sys(ddr_clk), .CLK_VIDEO(clk_video),
`ifdef NDS_BOOT_DIAGNOSTIC
    .reset_sys(bridge_reset_ddr),
`else
    .reset_sys(console_reset_ddr), .reset_video(video_output_reset),
`endif
`ifdef NDS_BOOT_DIAGNOSTIC
    .reset_video(video_output_reset),
`endif
    .pix_x(fb_pix_x), .pix_y(fb_pix_y), .pix_d(fb_pix_d), .pix_we(fb_pix_we),
    .pixb_x(fb_pixb_x), .pixb_y(fb_pixb_y),
    .pixb_d(fb_pixb_d), .pixb_we(fb_pixb_we),
    .source_fault(1'b0),
    .telemetry_session(32'd0),
    // Keep timing-sensitive 2D/BG/HDMA scanout in the FPGA. HPS publishes
    // only the completed 3D plane through the registered merge seam below.
    .external_frame_mode(1'b0), .external_frame_publish(1'b0),
    .external_frame_bank(2'd0), .external_frame_adopted(),
`ifdef NDS_BOOT_DIAGNOSTIC
    .dbg0(18'h2d15a),.dbg1(diag_heartbeat),.dbg2(diag_lifecycle),
    .dbg3(diag_hwstat_ddr),
    .dbg4(diag_pc9_ddr[17:0]),.dbg5({4'h9,diag_pc9_ddr[31:18]}),
    .dbg6(diag_pc7_ddr[17:0]),.dbg7({4'h7,diag_pc7_ddr[31:18]}),
    .dbg8(diag_r0_ddr[17:0]),.dbg9({4'h0,diag_r0_ddr[31:18]}),
    .dbg10(diag_lr_ddr[17:0]),.dbg11({4'he,diag_lr_ddr[31:18]}),
`else
    .dbg0(18'd0),.dbg1(18'd0),.dbg2(18'd0),.dbg3(18'd0),
    .dbg4(18'd0),.dbg5(18'd0),.dbg6(18'd0),.dbg7(18'd0),
    .dbg8(18'd0),.dbg9(18'd0),.dbg10(18'd0),.dbg11(18'd0),
`endif
    .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,
    .published_frame_toggle(fb_published_frame_toggle),
    .published_frame_bank(fb_published_frame_bank),
    .scanout_late_count(h3d_scanout_late_count),
    .runtime_fault_flags(h3d_fb_fault_flags),
    .bank_diagnostic(h3d_fb_bank_diagnostic),
    .lb_raddr,.lb_q,
    .fb5_addr,.fb5_din,.fb5_req,.fb5_next,.fb5_ready,
    .fb6_addr,.fb6_req,.fb6_dout,.fb6_valid,.fb6_ready
);
nds_nitro_video_scanout scanout (
    .clk_video,.reset(video_output_reset),.pf_tgl,.pf_scr,.pf_line,.pf_bank,
    .pf_frame_bank,
    .layout_select(video_layout_select),
    .screen_order_select(video_screen_order_select),
    .gap_select(video_gap_select),.fps_select(video_fps_select),
    .touch_pressed(joystick_sync[12]),.touch_x,.touch_y,
    .layout_active(video_layout_active),
    .screen_order_active(video_screen_order_active),
    .gap_active(video_gap_active),.fps_active(video_fps_active),
    .published_frame_toggle(fb_published_frame_toggle),
    .published_frame_bank(fb_published_frame_bank),
    .effective_3d_frame_toggle,
    .lb_raddr,.lb_q,.ce_pixel(video_ce),.de(video_de),
    .hsync(video_hs),.vsync(video_vs),
    .red(video_r),.green(video_g),.blue(video_b)
);

`ifdef NDS_HYBRID_3D
// -------------------------------------------------------------------------
// Hybrid 3D session, ordered event stream, and clock-safe return plane.
// -------------------------------------------------------------------------
nds_h3d_control_init #(
    .BASE_WORD(H3D_CONTROL_WORD), .ENTRY_COUNT(16384),
    .PACKET_MODE(1'b1)
) h3d_control (
    .clk(ddr_clk), .reset(bridge_reset_ddr),
    .requested_session(h3d_session_trigger),
    .external_fault_bits(h3d_external_fault_bits),
    .fpga_heartbeat_value(h3d_diagnostic_heartbeat),
    .fpga_telemetry_value(h3d_public_crash_telemetry),
    .telemetry_index(h3d_telemetry_index),
    .diagnostic_hold(h3d_diagnostic_hold_ddr),
    .active(h3d_control_active),
    .initialized(h3d_control_initialized),
    .console_release(h3d_control_release),
    .active_session(h3d_active_session),
    .fault(h3d_control_fault), .fault_bits(h3d_control_fault_bits),
    .ddram_read(h3d_control_read), .ddram_write(h3d_control_write),
    .ddram_burst_count(h3d_control_burst),
    .ddram_address(h3d_control_addr),
    .ddram_write_data(h3d_control_din),
    .ddram_byte_enable(h3d_control_be),
    .ddram_busy(h3d_control_busy),
    .ddram_command_accepted(h3d_control_command_accepted),
    .ddram_read_data(h3d_control_dout),
    .ddram_read_data_ready(h3d_control_dout_ready)
);

// Normalize the held clk1x GPU/VRAM streams, retain their architectural
// order, and cross complete frame records and boundary tokens into DDR.
nds_h3d_frame_record_cdc #(
    .ASYNC_LGDEPTH(4)
) h3d_record_cdc (
    .source_clk(clk1x), .ddr_clk(ddr_clk),
    .reset(bridge_reset_ddr), .session_flush(~h3d_control_release),
    .gpu_valid(h3d_gpu_write_valid), .gpu_ready(h3d_gpu_write_ready),
    .gpu_address(h3d_gpu_write_address),
    .gpu_access(h3d_gpu_write_access),
    .gpu_byte_enable(h3d_gpu_write_byte_enable),
    .gpu_data(h3d_gpu_write_data),
    .gpu_timestamp(h3d_gpu_write_timestamp),
    .arm9_vram_valid(h3d_vram9_write_valid),
    .arm9_vram_ready(h3d_vram9_write_ready),
    .arm9_vram_address(h3d_vram9_write_address[27:0]),
    .arm9_vram_access(h3d_vram9_write_access),
    .arm9_vram_byte_enable(h3d_vram9_write_byte_enable),
    .arm9_vram_data(h3d_vram9_write_data),
    .arm9_vram_timestamp(h3d_vram9_write_timestamp),
    .arm7_vram_valid(h3d_vram7_write_valid),
    .arm7_vram_ready(h3d_vram7_write_ready),
    .arm7_vram_address(h3d_vram7_write_address[27:0]),
    .arm7_vram_access(h3d_vram7_write_access),
    .arm7_vram_byte_enable(h3d_vram7_write_byte_enable),
    .arm7_vram_data(h3d_vram7_write_data),
    .arm7_vram_timestamp(h3d_vram7_write_timestamp),
    // The released hybrid keeps both timing-sensitive 2D engines in FPGA
    // logic and publishes only the 3D plane from HPS.  HBlank records were
    // required by the retired full-ARM-video shadow, but production consumed
    // them only as continuity markers.  A complex NSMB map scene proved that
    // their 263-per-frame queue can overflow during a transient packet stall
    // and fail-stop the otherwise healthy console.  Retire every marker at
    // its source and omit it from the HPS stream; native FPGA HDMA timing is
    // unchanged, while the redundant 512-entry MLAB queue synthesizes away.
    .hblank_valid(1'b0),
    .hblank_ready(h3d_hblank_ready_unused),
    .hblank_line(h3d_hblank_line),
    .hblank_frame(h3d_hblank_frame),
    .hblank_timestamp(h3d_hblank_timestamp),
    .frame_valid(h3d_frame_valid), .frame_ready(h3d_frame_ready),
    .frame_number(h3d_frame_number),
    .frame_timestamp(h3d_frame_timestamp),
    .source_active(h3d_record_source_active),
    .ddr_active(h3d_record_ddr_active),
    .source_fault(h3d_record_source_fault),
    .source_fault_reason(h3d_record_source_fault_reason),
    .ddr_fault(h3d_record_ddr_fault),
    .ddr_fault_reason(h3d_record_ddr_fault_reason),
    .fifo_level(h3d_gx_fifo_level),
    .fifo_empty(h3d_gx_fifo_empty),
    .fifo_below_half(h3d_gx_fifo_below_half),
    .fifo_full(h3d_gx_fifo_full),
    .record_valid(h3d_record_valid), .record_ready(h3d_record_ready),
    .record(h3d_record), .record_frame(h3d_record_frame),
    .record_frame_end(h3d_record_frame_end),
    .boundary_valid(h3d_boundary_valid),
    .boundary_ready(h3d_boundary_ready),
    .boundary_frame(h3d_boundary_frame)
);

assign h3d_hblank_ready = 1'b1;

nds_h3d_frame_packet_writer #(
    .CONTROL_BASE_WORD(H3D_CONTROL_WORD),
    .SLOT_BASE_WORD(H3D_SLOT_WORD)
) h3d_packet_writer (
    .clk(ddr_clk), .reset(bridge_reset_ddr),
    .session_flush(~h3d_control_release),
    .session(h3d_active_session),
    .record_valid(h3d_record_valid), .record_ready(h3d_record_ready),
    .record(h3d_record), .record_frame(h3d_record_frame),
    .record_frame_end(h3d_record_frame_end),
    .boundary_valid(h3d_boundary_valid),
    .boundary_ready(h3d_boundary_ready),
    .boundary_frame(h3d_boundary_frame),
    .active(h3d_packet_active), .full(h3d_packet_full),
    .packet_done(h3d_packet_done),
    .producer_sequence(h3d_producer_sequence),
    .acknowledged_sequence(h3d_consumer_sequence),
    .fault(h3d_packet_fault),
    .fault_reason(h3d_packet_fault_reason),
    .ddram_read(h3d_packet_read), .ddram_write(h3d_packet_write),
    .ddram_burst_count(h3d_packet_burst),
    .ddram_address(h3d_packet_addr),
    .ddram_write_data(h3d_packet_din),
    .ddram_byte_enable(h3d_packet_be),
    .ddram_busy(h3d_packet_busy),
    .ddram_command_accepted(h3d_packet_command_accepted),
    .ddram_read_data(h3d_packet_dout),
    .ddram_read_data_ready(h3d_packet_dout_ready)
);

// The active session is bundled stable while console_reset is asserted.  It
// is synchronized before the first post-release drawline can reach the reader.
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        h3d_session_meta_1x <= 32'd0;
        h3d_session_sync_1x <= 32'd0;
    end else begin
        h3d_session_meta_1x <= h3d_active_session;
        h3d_session_sync_1x <= h3d_session_meta_1x;
    end
end

// HPS publication follows the architectural VBlank that started the ARM
// renderer, so a descriptor read issued only on that same boundary normally
// observes the old sequence and adds a whole frame of latency. Poll the
// tear-free descriptor at a low fixed cadence instead. Stop immediately once
// a replacement has crossed into the pixel domain; it remains staged until
// the existing scanout-frame boundary commits it. A request is held until the
// request FIFO accepts it, preserving ordinary ready/valid semantics.
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        h3d_descriptor_request <= 1'b0;
        h3d_descriptor_retry <= 12'd0;
    end else begin
        if (h3d_pixel_descriptor_pending) begin
            h3d_descriptor_request <= 1'b0;
            h3d_descriptor_retry <= 12'hfff;
        end else if (h3d_descriptor_request) begin
            if (h3d_plane_descriptor_request_ready) begin
                h3d_descriptor_request <= 1'b0;
                h3d_descriptor_retry <= 12'hfff;
            end
        end else if (h3d_descriptor_retry != 0) begin
            h3d_descriptor_retry <= h3d_descriptor_retry - 1'b1;
        end else begin
            h3d_descriptor_request <= 1'b1;
        end
    end
end

// A line request is observational: never stall the proven 2D renderer. Hold
// the newest request until the asynchronous FIFO accepts it. A descriptor is
// activated after line 191, so the ordinary requests issued by lines 190/191
// still carry the previous descriptor. Re-seed lines 0/1 with the new frame
// during VBlank; measured per-frame telemetry otherwise reports exactly two
// wrong-Y misses despite 190/192 successful line deadlines and zero empty
// banks. If a complete scanline elapses while the FIFO is full, the older held
// request has already missed its display deadline; replace it with the new
// line instead of preserving obsolete work and eventually overflowing the
// source.
always_ff @(posedge clk1x or posedge console_reset_1x) begin
    if (console_reset_1x) begin
        h3d_line_pending <= 1'b0;
        h3d_line_pending_frame <= 32'd0;
        h3d_line_pending_y <= 8'd0;
        h3d_line_seed_sequence <= 32'd0;
        h3d_line_seed_remaining <= 2'd0;
    end else begin
        if (h3d_line_pending && h3d_plane_line_request_ready)
            h3d_line_pending <= 1'b0;

        if (!h3d_pixel_descriptor_valid) begin
            h3d_line_seed_remaining <= 2'd0;
        end else if (h3d_pixel_descriptor_sequence !=
                     h3d_line_seed_sequence) begin
            h3d_line_seed_sequence <= h3d_pixel_descriptor_sequence;
            if (!h3d_line_pending || h3d_plane_line_request_ready) begin
                h3d_line_pending <= 1'b1;
                h3d_line_pending_frame <= h3d_pixel_descriptor_frame;
                h3d_line_pending_y <= 8'd0;
                h3d_line_seed_remaining <= 2'd1;
            end else begin
                h3d_line_seed_remaining <= 2'd2;
            end
        end else if (h3d_line_seed_remaining != 0 &&
                     (!h3d_line_pending ||
                      h3d_plane_line_request_ready)) begin
            h3d_line_pending <= 1'b1;
            h3d_line_pending_frame <= h3d_pixel_descriptor_frame;
            h3d_line_pending_y <= h3d_line_seed_remaining == 2'd2
                ? 8'd0 : 8'd1;
            h3d_line_seed_remaining <= h3d_line_seed_remaining - 1'b1;
        end else if (h3d_core_line_request) begin
            if (!h3d_line_pending || h3d_plane_line_request_ready) begin
                h3d_line_pending <= 1'b1;
                h3d_line_pending_frame <= h3d_plane_display_frame;
                h3d_line_pending_y <= h3d_line_prefetch_y;
            end else begin
                h3d_line_pending_frame <= h3d_plane_display_frame;
                h3d_line_pending_y <= h3d_line_prefetch_y;
            end
        end
    end
end

nds_h3d_plane_reader #(
    .CONTROL_BASE_WORD(H3D_CONTROL_WORD),
    .BANK0_BASE_WORD(H3D_BANK0_WORD), .BANK1_BASE_WORD(H3D_BANK1_WORD)
) h3d_plane_reader (
    .ddr_clk(ddr_clk), .ddr_reset(h3d_path_reset),
    .pixel_clk(clk1x), .pixel_reset(console_reset_1x),
    .ddr_session(h3d_active_session),
    .pixel_session(h3d_session_sync_1x),
    .descriptor_request(h3d_descriptor_request),
    .descriptor_request_ready(h3d_plane_descriptor_request_ready),
    .line_request(h3d_line_pending),
    .line_request_ready(h3d_plane_line_request_ready),
    .line_frame(h3d_line_pending_frame), .line_y(h3d_line_pending_y),
    .frame_boundary(h3d_scanout_frame_boundary),
    .scanline_tick(h3d_core_line_request),
    .scanline_y(h3d_core_line_y),
    .line_start(h3d_core_line_start), .line_end(h3d_core_line_end),
    .merge_frame(h3d_plane_display_frame), .merge_y(h3d_core_merge_y),
    .pixel_x(h3d_core_merge_x),
    .line_valid(h3d_plane_line_valid), .line_bank(h3d_plane_line_bank),
    .pixel_packed(h3d_plane_pixel_packed),
    .pixel_valid(h3d_plane_pixel_valid),
    .pixel_line_missed(h3d_plane_pixel_line_missed),
    .pixel_frame_diagnostic(h3d_plane_frame_diagnostic),
    .busy(h3d_plane_busy_state),
    .descriptor_busy(h3d_plane_descriptor_busy),
    .line_fetch_busy(h3d_plane_line_fetch_busy),
    .descriptor_accepted(h3d_plane_descriptor_accepted),
    .descriptor_rejected(h3d_plane_descriptor_rejected),
    .line_loaded(h3d_plane_line_loaded), .line_missed(h3d_plane_line_missed),
    .active_descriptor_valid(h3d_plane_descriptor_valid),
    .active_descriptor_sequence(h3d_plane_descriptor_sequence),
    .active_descriptor_frame(h3d_plane_descriptor_frame),
    .active_descriptor_bank(h3d_plane_descriptor_bank),
    .pixel_descriptor_valid(h3d_pixel_descriptor_valid),
    .pixel_descriptor_pending(h3d_pixel_descriptor_pending),
    .pixel_descriptor_sequence(h3d_pixel_descriptor_sequence),
    .pixel_descriptor_frame(h3d_pixel_descriptor_frame),
    .pixel_descriptor_bank(h3d_pixel_descriptor_bank),
    .full_frame_publish(h3d_full_frame_publish),
    .full_frame_bank(h3d_full_frame_bank),
    .full_frame_adopted(h3d_full_frame_adopted),
    .ddram_active(h3d_plane_ddr_active),
    .ddram_read(h3d_plane_read), .ddram_write(h3d_plane_write),
    .ddram_burst_count(h3d_plane_burst), .ddram_address(h3d_plane_addr),
    .ddram_write_data(h3d_plane_din), .ddram_byte_enable(h3d_plane_be),
    .ddram_busy(h3d_plane_busy),
    .ddram_command_accepted(h3d_plane_command_accepted),
    .ddram_read_data(h3d_plane_dout),
    .ddram_read_data_ready(h3d_plane_dout_ready)
);
`endif

wire DDRAM_CLK = ddr_clk;
`ifdef NDS_HYBRID_3D
wire DDRAM_BUSY = h3d_legacy_busy;
wire [63:0] DDRAM_DOUT = h3d_legacy_dout;
wire DDRAM_DOUT_READY = h3d_legacy_dout_ready;
`else
wire DDRAM_BUSY = island_ddr_busy;
wire [63:0] DDRAM_DOUT = island_ddr_dout;
wire DDRAM_DOUT_READY = island_ddr_dout_ready;
`endif
wire [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire [7:0] DDRAM_BE;
wire DDRAM_WE;
always_comb begin
`ifdef NDS_HYBRID_3D
    island_ddr_burst = h3d_physical_burst;
    island_ddr_addr = h3d_physical_addr;
    island_ddr_read = h3d_physical_read;
    island_ddr_din = h3d_physical_din;
    island_ddr_be = h3d_physical_be;
    island_ddr_write = h3d_physical_write;
`else
    island_ddr_burst = DDRAM_BURSTCNT;
    island_ddr_addr = DDRAM_ADDR;
    island_ddr_read = DDRAM_RD;
    island_ddr_din = DDRAM_DIN;
    island_ddr_be = DDRAM_BE;
    island_ddr_write = DDRAM_WE;
`endif
end

ddram island_ddram (
    .*,
    .ch1_addr(27'd0),.ch1_dout(),.ch1_din(16'd0),
    .ch1_req(1'b0),.ch1_rnw(1'b1),.ch1_ready(),
    .ch2_addr({1'b0,cd_addr,1'b0}),.ch2_dout(cd_dout),.ch2_din(32'd0),
    .ch2_req(cd_req),.ch2_rnw(1'b1),.ch2_ready(cd_ready),
    .ch3_addr(27'd0),.ch3_dout(),.ch3_din(64'd0),.ch3_req(1'b0),
    .ch3_rnw(1'b1),.ch3_be(8'd0),.ch3_ready(),
    .ch4_addr(27'd0),.ch4_dout(),.ch4_din(64'd0),.ch4_req(1'b0),
    .ch4_rnw(1'b1),.ch4_be(8'd0),.ch4_ready(),
    .ch5_addr(fb5_addr),.ch5_din(fb5_din),.ch5_req(fb5_req),
    .ch5_burst(FB_BURST),.ch5_next(fb5_next),.ch5_ready(fb5_ready),
    .ch6_addr(fb6_addr),.ch6_burst(FB_BURST),.ch6_req(fb6_req),
    .ch6_dout(fb6_dout),.ch6_valid(fb6_valid),.ch6_ready(fb6_ready)
);

`ifdef NDS_HYBRID_3D
nds_h3d_ddr_fabric h3d_ddr_fabric (
    .clk(ddr_clk), .reset(h3d_fabric_reset),
    .legacy_read(DDRAM_RD), .legacy_write(DDRAM_WE),
    .legacy_burst_count(DDRAM_BURSTCNT), .legacy_address(DDRAM_ADDR),
    .legacy_write_data(DDRAM_DIN), .legacy_byte_enable(DDRAM_BE),
    .legacy_busy(h3d_legacy_busy),
    .legacy_command_accepted(h3d_legacy_command_accepted),
    .legacy_read_data(h3d_legacy_dout),
    .legacy_read_data_ready(h3d_legacy_dout_ready),
    .plane_read(h3d_plane_read), .plane_write(h3d_plane_write),
    .plane_burst_count(h3d_plane_burst), .plane_address(h3d_plane_addr),
    .plane_write_data(h3d_plane_din), .plane_byte_enable(h3d_plane_be),
    .plane_busy(h3d_plane_busy),
    .plane_command_accepted(h3d_plane_command_accepted),
    .plane_read_data(h3d_plane_dout),
    .plane_read_data_ready(h3d_plane_dout_ready),
    .event_read(h3d_packet_read), .event_write(h3d_packet_write),
    .event_burst_count(h3d_packet_burst),
    .event_address(h3d_packet_addr),
    .event_write_data(h3d_packet_din),
    .event_byte_enable(h3d_packet_be),
    .event_busy(h3d_packet_busy),
    .event_command_accepted(h3d_packet_command_accepted),
    .event_read_data(h3d_packet_dout),
    .event_read_data_ready(h3d_packet_dout_ready),
    .control_read(h3d_control_read), .control_write(h3d_control_write),
    .control_burst_count(h3d_control_burst),
    .control_address(h3d_control_addr),
    .control_write_data(h3d_control_din),
    .control_byte_enable(h3d_control_be),
    .control_busy(h3d_control_busy),
    .control_command_accepted(h3d_control_command_accepted),
    .control_read_data(h3d_control_dout),
    .control_read_data_ready(h3d_control_dout_ready),
    .ddram_read(h3d_physical_read), .ddram_write(h3d_physical_write),
    .ddram_burst_count(h3d_physical_burst),
    .ddram_address(h3d_physical_addr),
    .ddram_write_data(h3d_physical_din),
    .ddram_byte_enable(h3d_physical_be),
    .ddram_busy(island_ddr_busy), .ddram_read_data(island_ddr_dout),
    .ddram_read_data_ready(island_ddr_dout_ready),
    .epoch_quiescent(h3d_fabric_epoch_quiescent),
    .protocol_error(h3d_fabric_protocol_error),
    .debug_state(h3d_fabric_debug)
);
`endif


wire [15:0] sound_left, sound_right;
assign audio_left = sound_left;
assign audio_right = sound_right;
wire [31:0] math_address;
wire [31:0] math_write_data;
wire [31:0] math_read_data;
wire [1:0] math_access;
wire math_request, math_rnw, math_selected;
wire math_done_unused, div_busy_unused, sqrt_busy_unused;

nds_nitro_arm9_math_unit #(.COMBINATIONAL_READ(1'b1)) arm9_math (
    .clk(clk2x),.reset(console_reset_2x),
    .cycle_advance(8'd1),.cycle_advance_valid(1'b1),
    .request(math_request),.address(math_address),
    .read_not_write(math_rnw),.access(math_access),
    .write_data(math_write_data),.selected(math_selected),
    .read_data(math_read_data),.done(math_done_unused),
    .div_busy(div_busy_unused),.sqrt_busy(sqrt_busy_unused)
);

nds_nitro_console_wrap #(
    .CLKMEM_RATIO(CLKMEM_RATIO)
) console (
    .clk1x(clk1x),.clk2x(clk2x),.clkMem(clk_mem),
    .clkMemIndex(clkMemIndex),
    .reset(console_reset_1x),.nds_on(nds_on),
    .direct_boot(1'b1),.fw_boot(1'b0),
    .KeyA(joystick_sync[4]),.KeyB(joystick_sync[5]),
    .KeySelect(joystick_sync[10]),.KeyStart(joystick_sync[11]),
    .KeyRight(joystick_sync[0]),.KeyLeft(joystick_sync[1]),
    .KeyUp(joystick_sync[3]),.KeyDown(joystick_sync[2]),
    .KeyR(joystick_sync[9]),.KeyL(joystick_sync[8]),
    .KeyX(joystick_sync[6]),.KeyY(joystick_sync[7]),.lid_closed(1'b0),
    .touch_active(joystick_sync[12]),
    .touch_x(touch_x),.touch_y(touch_y),
    .boot_done(boot_done),.boot_error(boot_error),
    .card_ena(card_ena),.card_addr(card_addr),
    .card_din(card_din),.card_done(card_done),
    .backup_addr(backup_addr),
    .backup_write_data(backup_write_data),
    .backup_write_enable(backup_write_enable),
    .backup_read_data(backup_read_data),
    .backup_write_toggle(backup_write_toggle),
    .backup_is_64k(backup_is_64k),
    .backup_save_type(backup_save_type),
    .backup_profile_valid(backup_profile_valid),
    .backup_access_active(backup_access_active),
    .backup_cache_ready(backup_cache_ready_sync_1x),
    .backup_run_ready(save_run_ready_sync_1x),
    .fw_addr(fw_addr_unused),.fw_req(fw_req),
    .fw_done(fw_done),.fw_data(fw_data),
    .bios7_load_addr(12'd0),.bios7_load_data(32'd0),
    .bios7_load_be(4'd0),.bios7_load_we(1'b0),.bios7_load_done(1'b0),
    .bios9_load_addr(10'd0),.bios9_load_data(32'd0),
    .bios9_load_be(4'd0),.bios9_load_we(1'b0),.bios9_load_done(1'b0),
    .mainram_allow(mainram_allow),.mainram_active(mainram_active),
    .mainram_busy(mainram_busy),
    .sdram_ena(mr_ena),.sdram_rnw(mr_rnw),.sdram_Adr(mr_adr),
    .sdram_Din(mr_din),.sdram_be(mr_be),
    .sdram_Dout(sd_ch2_dout),.sdram_done32(mr_done32),
    .sdram_Dout_hi(sd_ch2_dout_hi),.sdram_done64(mr_done64),
    .vsrv_req(vsrv_req_c),.vsrv_rnw(vsrv_rnw_c),
    .vsrv_bank(vsrv_bank_c),.vsrv_addr(vsrv_addr_c),
    .vsrv_be(vsrv_be_c),.vsrv_din(vsrv_din_c),
    .vsrv_dout(vsrv_dout_r),.vsrv_done(vsrv_done_r),
    .vrsrv_req(vrsrv_req_c),.vrsrv_bank(vrsrv_bank_c),
    .vrsrv_addr(vrsrv_addr_c),.vrsrv_dout(vrsrv_dout_r),
    .vrsrv_done(vrsrv_done_r),.vrsrv_ready(vrsrv_ready_c),
    .math_request(math_request),.math_address(math_address),
    .math_rnw(math_rnw),.math_access(math_access),
    .math_write_data(math_write_data),.math_read_data(math_read_data),
    .math_selected(math_selected),
    .pixel_out_x(pix_x),.pixel_out_y(pix_y),
    .pixel_out_data(pix_d),.pixel_out_we(pix_we),
    .pixelb_out_x(pixb_x),.pixelb_out_y(pixb_y),
    .pixelb_out_data(pixb_d),.pixelb_out_we(pixb_we),.vblank_out(),
    .sound_out_left(sound_left),.sound_out_right(sound_right),
`ifdef NDS_HYBRID_3D
    .h3d_pixel_valid(h3d_plane_pixel_valid),
    .h3d_pixel_data(h3d_plane_pixel_packed[22:0]),
    .h3d_line_request(h3d_core_line_request),
    .h3d_line_request_y(h3d_core_line_y),
    .h3d_merge_line_start(h3d_core_line_start),
    .h3d_merge_line_end(h3d_core_line_end),
    .h3d_merge_pixel_x(h3d_core_merge_x),
    .h3d_merge_pixel_y(h3d_core_merge_y),
    .h3d_line_drop(h3d_core_line_drop),
    .h3d_bg1_scroll_triplet(h3d_bg1_scroll_triplet),
    .h3d_service_ready(h3d_console_release),
    .h3d_gx_fifo_level(h3d_gx_fifo_level),
    .h3d_timestamp(h3d_timestamp_live),
    .h3d_current_frame(h3d_current_frame),
    .h3d_source_fault(h3d_console_source_fault),
    .h3d_gpu_write_valid(h3d_gpu_write_valid),
    .h3d_gpu_write_ready(h3d_gpu_write_ready),
    .h3d_gpu_write_address(h3d_gpu_write_address),
    .h3d_gpu_write_access(h3d_gpu_write_access),
    .h3d_gpu_write_byte_enable(h3d_gpu_write_byte_enable),
    .h3d_gpu_write_data(h3d_gpu_write_data),
    .h3d_gpu_write_frame(h3d_gpu_write_frame),
    .h3d_gpu_write_timestamp(h3d_gpu_write_timestamp),
    .h3d_vram9_write_valid(h3d_vram9_write_valid),
    .h3d_vram9_write_ready(h3d_vram9_write_ready),
    .h3d_vram9_write_address(h3d_vram9_write_address),
    .h3d_vram9_write_access(h3d_vram9_write_access),
    .h3d_vram9_write_byte_enable(h3d_vram9_write_byte_enable),
    .h3d_vram9_write_data(h3d_vram9_write_data),
    .h3d_vram9_write_frame(h3d_vram9_write_frame),
    .h3d_vram9_write_timestamp(h3d_vram9_write_timestamp),
    .h3d_vram7_write_valid(h3d_vram7_write_valid),
    .h3d_vram7_write_ready(h3d_vram7_write_ready),
    .h3d_vram7_write_address(h3d_vram7_write_address),
    .h3d_vram7_write_access(h3d_vram7_write_access),
    .h3d_vram7_write_byte_enable(h3d_vram7_write_byte_enable),
    .h3d_vram7_write_data(h3d_vram7_write_data),
    .h3d_vram7_write_frame(h3d_vram7_write_frame),
    .h3d_vram7_write_timestamp(h3d_vram7_write_timestamp),
    .h3d_hblank_valid(h3d_hblank_valid),
    .h3d_hblank_ready(h3d_hblank_ready),
    .h3d_hblank_line(h3d_hblank_line),
    .h3d_hblank_frame(h3d_hblank_frame),
    .h3d_hblank_timestamp(h3d_hblank_timestamp),
    .h3d_frame_valid(h3d_frame_valid),
    .h3d_frame_ready(h3d_frame_ready),
    .h3d_frame_number(h3d_frame_number),
    .h3d_frame_timestamp(h3d_frame_timestamp),
`endif
    .dbg_pc9(dbg_pc9_diag),.dbg_pc7(dbg_pc7_diag),
    .dbg_r0_9(dbg_r0_diag),.dbg_lr9(dbg_lr_diag),
    .dbg_cpsr9(dbg_cpsr_diag),.dbg_vfy_bad(dbg_vfy_bad_unused),
    .diagnostic_hold9(h3d_hold_sync_2x[1]),
    .diagnostic_hold7(h3d_hold_sync_1x[1]),
    .diagnostic_release9(h3d_diagnostic_release_2x),
    .diagnostic_release7(h3d_diagnostic_release_1x),
    .dbg_vfy_addr(dbg_vfy_addr_unused),
    .dbg_cmd_stb(1'b0),.dbg_cmd_op(8'd0),.dbg_cmd_arg(32'd0),
    .dbg_rsp_data(dbg_rsp_unused),.dbg_rsp_stb(dbg_rsp_stb_unused),
    .dbg_hwstat(dbg_hwstat_diag)
);
endmodule
