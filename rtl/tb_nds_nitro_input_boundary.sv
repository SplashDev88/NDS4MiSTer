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
    wire [1:0] video_layout_active;
    wire video_screen_order_active;
    wire [1:0] video_gap_active;
    wire video_fps_active;
    logic [31:0] joystick = '0;
    logic [15:0] joystick_analog = '0;
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
        joystick_analog = 16'hA355;
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
        joystick_analog = 16'h127F;
        clk1x_fall();
        if (dut.joystick_sync === joystick || dut.analog_sync === joystick_analog)
            $fatal(1, "controller update bypassed the second synchronizer stage");
        clk1x_fall();
        if (dut.joystick_sync !== joystick || dut.analog_sync !== joystick_analog)
            $fatal(1, "second controller report did not cross intact");
        if (dut.touch_x !== 8'hFF || dut.touch_y !== 8'h6D)
            $fatal(1, "second analog conversion mismatch x=%h y=%h",
                   dut.touch_x, dut.touch_y);

        // A replacement ROM/reset epoch must clear held input immediately and
        // must not leak the old report when the new epoch eventually releases.
        force dut.console_reset_request = 1'b1;
        #1;
        if (dut.joystick_sync !== 32'd0 || dut.analog_sync !== 16'd0)
            $fatal(1, "cartridge epoch did not clear held controller state");

        $display("PASS: Nitro controller CDC, epoch reset, and touch conversion");
        $finish;
    end
endmodule
