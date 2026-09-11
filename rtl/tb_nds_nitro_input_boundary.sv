// SPDX-License-Identifier: GPL-3.0-or-later
// Product-level controller CDC/reset/touch proof for the r355 console island.
`timescale 1ns/1ps

module tb_nds_nitro_input_boundary;
    logic clk1x = 1'b0;
    logic clk2x = 1'b0;
    logic clk_mem = 1'b0;
    logic clk_video = 1'b0;
    logic ddr_clk = 1'b0;
    always #15 clk1x = ~clk1x;
    always #7.5 clk2x = ~clk2x;
    always #5 clk_mem = ~clk_mem;
    always #10 clk_video = ~clk_video;
    always #10 ddr_clk = ~ddr_clk;

    logic island_locked = 1'b1;
    logic shell_reset = 1'b0;
    logic media_reset = 1'b1;
    logic enable = 1'b1;
    logic [1:0] video_layout_select = 2'd0;
    logic video_screen_order_select = 1'b0;
    logic [1:0] video_gap_select = 2'd0;
    logic video_fps_select = 1'b0;
    logic engine_b_select = 1'b0;
    wire [1:0] video_layout_active;
    wire video_screen_order_active;
    wire [1:0] video_gap_active;
    wire video_fps_active;
    logic [31:0] joystick = '0;
    logic [15:0] joystick_analog_direct = '0;
    logic use_touch_arbiter = 1'b0;
    logic touch_input_reset = 1'b1;
    logic controller_pressed = 1'b0;
    logic [15:0] controller_analog = '0;
    logic [24:0] ps2_mouse = '0;
    wire touch_pressed;
    wire [15:0] touch_analog;
    wire [15:0] joystick_analog = use_touch_arbiter
        ? touch_analog : joystick_analog_direct;
    logic ioctl_download = 1'b0;
    logic [15:0] ioctl_index = '0;
    wire ioctl_wait;
    logic save_img_mounted = 1'b0;
    logic save_img_readonly = 1'b0;
    logic [63:0] save_img_size = 64'd0;
    wire [31:0] save_sd_lba;
    wire save_sd_rd, save_sd_wr;
    logic save_sd_ack = 1'b0;
    logic [12:0] save_sd_buff_addr = 13'd0;
    logic [15:0] save_sd_buff_dout = 16'd0;
    wire [15:0] save_sd_buff_din;
    logic save_sd_buff_wr = 1'b0;
    wire boot_done, boot_error, cart_loaded;
    wire video_ce, video_de, video_hs, video_vs;
    wire [7:0] video_r, video_g, video_b;
    wire boundary_fault;
    wire [15:0] audio_left, audio_right;
    wire [7:0] island_ddr_burst;
    wire [28:0] island_ddr_addr;
    logic [63:0] island_ddr_dout = '0;
    // Complete the two cartridge-cache displacement probes immediately; this
    // boundary test is concerned with the verified-ready epoch, not DDR data.
    logic island_ddr_dout_ready = 1'b1;
    wire island_ddr_read;
    wire [63:0] island_ddr_din;
    wire [7:0] island_ddr_be;
    wire island_ddr_write;
    logic island_ddr_busy = 1'b0;
    wire SDRAM_CLK, SDRAM_CKE;
    wire [12:0] SDRAM_A;
    wire [1:0] SDRAM_BA;
    tri [15:0] SDRAM_DQ;
    wire SDRAM_DQML, SDRAM_DQMH;
    wire SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE;
    integer axis_value;
    integer previous_touch_x;
    integer expected_touch_x;

    nds_nitro_touch_input touch_input (
        .clk(clk1x),.reset(touch_input_reset),
        .controller_pressed,.controller_analog,.ps2_mouse,
        .touch_pressed,.touch_analog
    );
    nds_nitro_console_island dut (.*);

    task automatic clk1x_fall;
        @(negedge clk1x);
    endtask

    initial begin
        // MiSTer can publish its one-cycle mount notice while the island is
        // still held in power/media reset.  The product boundary must queue
        // and replay it after reset rather than leaving the save bridge in
        // ST_WAIT_MOUNT on the first ROM load.
        repeat (3) @(posedge clk_video);
        @(negedge clk_video);
        ioctl_index = 16'h0003;
        ioctl_download = 1'b1;
        @(negedge clk_video);
        save_img_size = 64'd8192;
        save_img_mounted = 1'b1;
        @(negedge clk_video);
        save_img_mounted = 1'b0;
        ioctl_download = 1'b0;
        repeat (2) @(posedge clk_video);
        if (dut.save_ready)
            $fatal(1, "save mount escaped while media reset was asserted");
        if (!dut.save_mount_queued)
            $fatal(1, "direct-load save mount was not queued during reset");
        if (dut.save_cart_event_seen || dut.save_cart_event_pulse)
            $fatal(1, "cartridge event escaped while media reset was asserted");
        @(negedge clk_video);
        media_reset = 1'b0;
        repeat (200) @(posedge clk_video);
        if (!dut.save_ready)
            $fatal(1,
                "verified cartridge-ready fallback failed cart_state=%0d cart_loaded=%b ready_sync=%b event=%b/%b",
                dut.cart_state, dut.cart_loaded_ddr,
                dut.save_cart_ready_sync_video,
                dut.save_cart_event_seen, dut.save_cart_event_pulse);

        // A mounted save is media state, not CPU state. Prove an OSD-style
        // shell reset retains it while a real media reset still clears it.
        @(negedge clk_video);
        shell_reset = 1'b1;
        repeat (3) @(posedge clk_video);
        if (!dut.save_ready)
            $fatal(1, "console soft reset discarded mounted save state");
        @(negedge clk_video);
        shell_reset = 1'b0;

        // Once the bridge is live, a normal raw replacement edge must still
        // arrive immediately so an outgoing dirty cache can flush before the
        // next sidecar is mounted. The verified-ready edge is fallback only.
        ioctl_download = 1'b1;
        @(negedge clk_video);
        if (!dut.save_cart_event_pulse)
            $fatal(1, "live cartridge download edge did not reach save bridge");
        ioctl_download = 1'b0;

        media_reset = 1'b1;
        repeat (2) @(posedge clk_video);
        if (dut.save_ready)
            $fatal(1, "media reset retained stale mounted save state");
        media_reset = 1'b0;

        // Isolate the input boundary from the cartridge state machine.  The
        // force models the same asynchronous reset request and local release
        // that a real cartridge epoch drives in the product.
        force dut.console_reset_request = 1'b1;
        repeat (3) clk1x_fall();
        if (dut.joystick_sync !== 32'd0 || dut.analog_sync !== 16'd0)
            $fatal(1, "input state was not cleared during console reset");

        joystick = 32'h0000_1491; // right, A, Y, Select, Touch
        joystick_analog_direct = 16'hA355;
        force dut.console_reset_request = 1'b0;

        // Reset deasserts through two flops, then the controller level crosses
        // through its own two flops.  It must not appear at the console early.
        repeat (3) clk1x_fall();
        if (dut.joystick_sync !== 32'd0 || dut.analog_sync !== 16'd0)
            $fatal(1, "controller escaped the synchronizer too early");
        repeat (2) clk1x_fall();
        if (dut.joystick_sync !== joystick || dut.analog_sync !== joystick_analog)
            $fatal(1, "controller did not cross intact sync=%h/%h expected=%h/%h",
                   dut.joystick_sync, dut.analog_sync, joystick, joystick_analog);
        if (dut.touch_x !== 8'hD5 || dut.touch_y !== 8'h1A)
            $fatal(1, "analog conversion mismatch x=%h y=%h", dut.touch_x, dut.touch_y);

        // A changed report must take two destination edges: no metastable
        // first-stage value may become architectural input on the first edge.
        joystick = 32'h0000_0B6E; // left/down, B, X, L/R, Start
        joystick_analog_direct = 16'h127F;
        clk1x_fall();
        if (dut.joystick_sync === joystick || dut.analog_sync === joystick_analog)
            $fatal(1, "controller update bypassed the second synchronizer stage");
        clk1x_fall();
        if (dut.joystick_sync !== joystick || dut.analog_sync !== joystick_analog)
            $fatal(1, "second controller report did not cross intact");
        if (dut.touch_x !== 8'hFF || dut.touch_y !== 8'h6D)
            $fatal(1, "second analog conversion mismatch x=%h y=%h",
                   dut.touch_x, dut.touch_y);

        // Prove the complete right-stick path, rather than just the shell
        // arbiter or the island conversion in isolation. hps_io publishes
        // signed -127..+127 values; full deflection must reach every native
        // DS edge after arbitration, CDC, and coordinate conversion.
        touch_input_reset = 1'b0;
        use_touch_arbiter = 1'b1;
        controller_analog = 16'h8181;
        repeat (2) clk1x_fall();
        if (dut.touch_x !== 8'd0 || dut.touch_y !== 8'd0)
            $fatal(1, "negative controller edge missed DS origin x=%0d y=%0d analog=%h",
                   dut.touch_x,dut.touch_y,touch_analog);
        controller_analog = 16'h0000;
        repeat (2) clk1x_fall();
        if (dut.touch_x !== 8'd128 || dut.touch_y !== 8'd96)
            $fatal(1, "controller center changed x=%0d y=%0d",
                   dut.touch_x,dut.touch_y);
        controller_analog = 16'h7F7F;
        repeat (2) clk1x_fall();
        if (dut.touch_x !== 8'd255 || dut.touch_y !== 8'd191)
            $fatal(1, "positive controller edge missed DS far corner x=%0d y=%0d",
                   dut.touch_x,dut.touch_y);

        previous_touch_x = 0;
        for (axis_value = -127; axis_value <= 127; axis_value = axis_value + 1) begin
            controller_analog = {8'h00,axis_value[7:0]};
            repeat (2) clk1x_fall();
            expected_touch_x = axis_value + 128;
            if (expected_touch_x == 1)
                expected_touch_x = 0;
            if (dut.touch_x !== expected_touch_x[7:0])
                $fatal(1, "DS-visible X mismatch raw=%0d got=%0d expected=%0d",
                       axis_value,dut.touch_x,expected_touch_x);
            if (dut.touch_x < previous_touch_x)
                $fatal(1, "DS-visible X is not monotonic raw=%0d got=%0d previous=%0d",
                       axis_value,dut.touch_x,previous_touch_x);
            previous_touch_x = dut.touch_x;
        end

        // The shared one-bit endpoint decode deliberately coalesces mouse
        // native X=1 into X=0 as well. Cursor and ADC coordinates use this
        // same value, X=2 and every later pixel remain exact, and clamping is
        // still owned by the mouse arbiter.
        ps2_mouse = {~ps2_mouse[24],8'h00,8'h81,8'h00}; // 128 - 127 = 1
        repeat (3) clk1x_fall();
        if (touch_analog[7:0] !== 8'h81 || dut.touch_x_raw !== 8'd1 ||
            dut.touch_x !== 8'd0)
            $fatal(1, "mouse X=1 endpoint coalescing mismatch analog=%h raw=%0d visible=%0d",
                   touch_analog[7:0],dut.touch_x_raw,dut.touch_x);
        ps2_mouse = {~ps2_mouse[24],8'h00,8'h01,8'h00}; // 1 + 1 = 2
        repeat (3) clk1x_fall();
        if (dut.touch_x_raw !== 8'd2 || dut.touch_x !== 8'd2)
            $fatal(1, "mouse X=2 must remain exact raw=%0d visible=%0d",
                   dut.touch_x_raw,dut.touch_x);

        // A replacement ROM/reset epoch must clear held input immediately and
        // must not leak the old report when the new epoch eventually releases.
        force dut.console_reset_request = 1'b1;
        #1;
        if (dut.joystick_sync !== 32'd0 || dut.analog_sync !== 16'd0)
            $fatal(1, "cartridge epoch did not clear held controller state");

        $display("PASS: Nitro controller CDC, epoch reset, and full-range touch conversion");
        $finish;
    end
endmodule
