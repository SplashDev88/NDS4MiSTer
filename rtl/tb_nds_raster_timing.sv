module tb_nds_raster_timing;
    logic clk = 0;
    logic reset = 1;
    logic [28:0] control_addr = 0;
    logic [31:0] joystick = 0;
    logic ddram_busy = 0;
    logic [63:0] ddram_dout = 0;
    logic ddram_dout_ready = 0;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic ddram_rd, ddram_we;
    logic [63:0] ddram_din;
    logic ce_pixel, de, hblank, vblank, hsync, vsync;
    logic [7:0] red, green, blue;
    logic ready, format_error;
    logic [3:0] debug_progress;
    logic signed [15:0] audio_l, audio_r;

    integer pixels_in_line = 0;
    integer low_hsync_pixels = 0;
    integer lines_in_frame = 0;
    integer low_vsync_lines = 0;
    integer frames = 0;
    integer expected_phase = 0;
    integer expected_extra = 0;
    integer next_phase;
    logic line_started = 0;
    logic frame_started = 0;

    // Reuse this raster test for the local DS LCD owner and its LW queue.
    // The queue is deliberately only four records deep so the test proves
    // that renderer backpressure drops records without stopping LCD time.
    logic [63:0] lcd_shared_timestamp = 0;
    logic lcd_selected, lcd_done;
    logic [31:0] lcd_read_data;
    logic [8:0] lcd_vcount;
    logic [15:0] lcd_dispstat9, lcd_dispstat7;
    logic [31:0] lcd_irq9, lcd_irq7;
    logic lcd_dma9_hblank, lcd_dma9_vblank, lcd_dma7_vblank;
    logic lcd_dma9_display, lcd_dma9_display_stop;
    logic lcd_event_valid;
    logic [31:0] lcd_event_sequence;
    logic [63:0] lcd_event_timestamp;
    logic [1:0] lcd_event_kind;
    logic [8:0] lcd_event_line, lcd_event_vcount;
    logic [15:0] lcd_event_dispstat9, lcd_event_dispstat7;
    logic [31:0] lcd_event_frame;
    logic lcd_caught_up, lcd_protocol_error;
    logic lcd_mirror_valid = 0;
    logic lcd_mirror_cpu = 1;
    logic [31:0] lcd_mirror_address = 32'h04000004;
    logic [1:0] lcd_mirror_access = 2'b01;
    logic [31:0] lcd_mirror_data = 0;

    logic [18:0] lcd_q_raddr = 0, lcd_q_waddr = 0;
    logic [31:0] lcd_q_rdata, lcd_q_wdata = 0;
    logic [3:0] lcd_q_be = 0;
    logic lcd_q_write = 0, lcd_q_read_select, lcd_q_write_select;
    logic lcd_q_irq, lcd_q_accepted, lcd_q_dropped;
    logic lcd_q_enable = 0;
    logic [2:0] lcd_q_level;
    logic [31:0] lcd_q_producer, lcd_q_consumer, lcd_q_dropped_count;
    logic lcd_q_protocol_error;
    logic lcd_queue_test_done = 0;
    logic lcd_tests_done = 0;
    integer lcd_expected_sequence = 1;
    integer lcd_expected_kind = 0;
    integer lcd_expected_line = 0;
    logic [63:0] lcd_expected_timestamp = 0;
    integer lcd_scanline_events = 0;
    integer lcd_hblank_events = 0;
    integer lcd_frame_wrap_events = 0;
    integer lcd_display_events = 0;
    integer lcd_display_stop_events = 0;
    integer lcd_last_scan_vcount = 0;
    integer lcd_natural_vcount = 0;
    logic lcd_vcount_override_written = 0;

    always #5 clk = ~clk;

    nds_compact_ddr_video #(
        .H_ACTIVE(8), .H_FRONT(2), .H_SYNC(3), .H_TOTAL(16),
        .V_ACTIVE(192), .V_FRONT(3), .V_SYNC(6), .V_TOTAL(261),
        .V_EXTRA_STEP(11379), .PIXEL_DIVIDE(2),
        .FRAME_WORDS(4), .FETCH_BURST_WORDS(2)
    ) dut (.*);

    nds_local_lcd_control #(.ENABLED(1'b1)) lcd_owner (
        .clk, .reset, .enable(1'b1), .time_valid(!reset),
        .shared_timestamp(lcd_shared_timestamp),
        .request(1'b0), .cpu_is_arm9(1'b1), .address(32'd0),
        .read_not_write(1'b1), .access(2'b10), .write_data(32'd0),
        .selected(lcd_selected), .read_data(lcd_read_data), .done(lcd_done),
        .mirror_write_valid(lcd_mirror_valid),
        .mirror_write_cpu_arm9(lcd_mirror_cpu),
        .mirror_write_address(lcd_mirror_address),
        .mirror_write_access(lcd_mirror_access),
        .mirror_write_data(lcd_mirror_data),
        .vcount(lcd_vcount), .dispstat9(lcd_dispstat9),
        .dispstat7(lcd_dispstat7),
        .irq9_set_mask(lcd_irq9), .irq7_set_mask(lcd_irq7),
        .dma9_hblank_trigger(lcd_dma9_hblank),
        .dma9_vblank_trigger(lcd_dma9_vblank),
        .dma9_display_trigger(lcd_dma9_display),
        .dma9_display_stop(lcd_dma9_display_stop),
        .dma7_vblank_trigger(lcd_dma7_vblank),
        .event_valid(lcd_event_valid),
        .event_sequence(lcd_event_sequence),
        .event_timestamp(lcd_event_timestamp),
        .event_kind(lcd_event_kind), .event_line(lcd_event_line),
        .event_vcount(lcd_event_vcount),
        .event_dispstat9(lcd_event_dispstat9),
        .event_dispstat7(lcd_event_dispstat7),
        .event_frame_sequence(lcd_event_frame),
        .caught_up(lcd_caught_up),
        .protocol_error(lcd_protocol_error));

    nds_lcd_event_queue #(.ENABLED(1'b1), .DEPTH(4)) lcd_queue (
        .clk, .reset, .enable(lcd_q_enable),
        .push_valid(lcd_event_valid),
        .push_sequence(lcd_event_sequence),
        .push_timestamp(lcd_event_timestamp),
        .push_kind(lcd_event_kind), .push_line(lcd_event_line),
        .push_vcount(lcd_event_vcount),
        .push_dispstat9(lcd_event_dispstat9),
        .push_dispstat7(lcd_event_dispstat7),
        .push_frame_sequence(lcd_event_frame),
        .push_accepted(lcd_q_accepted), .push_dropped(lcd_q_dropped),
        .reg_raddr(lcd_q_raddr), .reg_rdata(lcd_q_rdata),
        .reg_read_select(lcd_q_read_select),
        .reg_waddr(lcd_q_waddr), .reg_wdata(lcd_q_wdata),
        .reg_be(lcd_q_be), .reg_write(lcd_q_write),
        .reg_write_select(lcd_q_write_select),
        .work_pending_irq(lcd_q_irq), .queue_level(lcd_q_level),
        .producer_sequence(lcd_q_producer),
        .consumer_sequence(lcd_q_consumer),
        .dropped_count(lcd_q_dropped_count),
        .protocol_error(lcd_q_protocol_error));

    always @(posedge clk) begin
        if (reset)
            lcd_shared_timestamp <= 0;
        else
            lcd_shared_timestamp <= lcd_shared_timestamp + 1'b1;
    end

    always @(posedge clk) begin
        #1;
        if (!reset && lcd_event_valid) begin
            if (lcd_event_sequence != lcd_expected_sequence ||
                lcd_event_timestamp != lcd_expected_timestamp ||
                lcd_event_kind != lcd_expected_kind ||
                lcd_event_line != lcd_expected_line)
                $fatal(1,
                    "LCD event mismatch seq=%0d/%0d ts=%0d/%0d kind=%0d/%0d line=%0d/%0d",
                    lcd_event_sequence, lcd_expected_sequence,
                    lcd_event_timestamp, lcd_expected_timestamp,
                    lcd_event_kind, lcd_expected_kind,
                    lcd_event_line, lcd_expected_line);
            if (lcd_event_kind == 1) begin
                if (!lcd_event_dispstat9[1] || !lcd_event_dispstat7[1])
                    $fatal(1, "LCD HBlank descriptor omitted status flags");
                lcd_hblank_events = lcd_hblank_events + 1;
                lcd_expected_timestamp = lcd_expected_timestamp + 546;
                if (lcd_expected_line == 262) begin
                    lcd_expected_kind = 2;
                    lcd_expected_line = 0;
                end else begin
                    lcd_expected_kind = 0;
                    lcd_expected_line = lcd_expected_line + 1;
                end
            end else begin
                if (lcd_event_dispstat9[1] || lcd_event_dispstat7[1])
                    $fatal(1, "LCD scanline descriptor retained HBlank");
                if (lcd_event_line < 192 &&
                    lcd_event_vcount != lcd_event_line)
                    $fatal(1, "LCD VCOUNT %0d did not follow line %0d",
                        lcd_event_vcount, lcd_event_line);
                if (lcd_event_line >= 192 &&
                    lcd_event_vcount != lcd_event_line - 187)
                    $fatal(1,
                        "delayed VCOUNT override was not retained: %0d line %0d",
                        lcd_event_vcount, lcd_event_line);
                if (lcd_event_kind == 2) begin
                    lcd_frame_wrap_events = lcd_frame_wrap_events + 1;
                    if (lcd_event_frame != 1)
                        $fatal(1, "first LCD frame sequence was %0d",
                            lcd_event_frame);
                end else begin
                    lcd_scanline_events = lcd_scanline_events + 1;
                end
                lcd_expected_kind = 1;
                lcd_expected_timestamp = lcd_expected_timestamp + 1584;
            end
            lcd_expected_sequence = lcd_expected_sequence + 1;

            if (lcd_event_kind == 1 && lcd_event_vcount < 192 &&
                !lcd_dma9_hblank)
                $fatal(1, "live visible VCOUNT did not trigger HBlank DMA9");
            if (lcd_event_kind == 1 && lcd_event_vcount >= 192 &&
                lcd_dma9_hblank)
                $fatal(1, "live VBlank VCOUNT triggered HBlank DMA9");
            if (lcd_event_kind != 1 && lcd_event_line == 192 &&
                (!lcd_dma9_vblank || !lcd_dma7_vblank))
                $fatal(1,
                    "natural VCOUNT did not trigger both VBlank DMA owners");
            if (lcd_event_kind != 1 && lcd_event_line == 192 &&
                (!lcd_event_dispstat9[2] || lcd_event_vcount != 5 ||
                 lcd_irq9[2:0] != 3'b101))
                $fatal(1,
                    "overridden VCOUNT did not drive VMatch after VBlank");

            if (lcd_event_kind != 1) begin
                // Natural timing is the physical raster line. The deliberate
                // VCOUNT override below must not move display-DMA cadence.
                lcd_natural_vcount = lcd_event_line;
                if (lcd_natural_vcount >= 2 &&
                    lcd_natural_vcount <= 193) begin
                    if (!lcd_dma9_display || lcd_dma9_display_stop)
                        $fatal(1,
                            "display DMA phase was bad at VCOUNT %0d",
                            lcd_natural_vcount);
                    lcd_display_events = lcd_display_events + 1;
                end else if (lcd_dma9_display) begin
                    $fatal(1, "display DMA fired outside VCOUNT 2..193");
                end
                if (lcd_natural_vcount == 194) begin
                    if (!lcd_dma9_display_stop)
                        $fatal(1, "display DMA did not stop at VCOUNT 194");
                    lcd_display_stop_events =
                        lcd_display_stop_events + 1;
                end else if (lcd_dma9_display_stop) begin
                    $fatal(1, "display DMA stop fired outside VCOUNT 194");
                end
                lcd_last_scan_vcount = lcd_event_vcount;
            end

            if (lcd_event_sequence == 527) begin
                if (lcd_event_kind != 2 || lcd_event_timestamp != 560190 ||
                    lcd_scanline_events != 263 ||
                    lcd_hblank_events != 263 ||
                    lcd_frame_wrap_events != 1 ||
                    lcd_display_events != 192 ||
                    lcd_display_stop_events != 1)
                    $fatal(1,
                        "LCD frame counts scan=%0d hblank=%0d wrap=%0d display=%0d stop=%0d",
                        lcd_scanline_events, lcd_hblank_events,
                        lcd_frame_wrap_events, lcd_display_events,
                        lcd_display_stop_events);
                if (!lcd_queue_test_done || lcd_q_dropped_count == 0 ||
                    lcd_protocol_error || lcd_q_protocol_error)
                    $fatal(1, "LCD queue/control completion state was bad");
                lcd_tests_done = 1;
            end
        end
        if (!reset &&
            lcd_caught_up !==
            (lcd_shared_timestamp < lcd_expected_timestamp &&
             !lcd_event_valid && lcd_irq9 == 0 && lcd_irq7 == 0 &&
             !lcd_dma9_hblank && !lcd_dma9_vblank &&
             !lcd_dma9_display && !lcd_dma9_display_stop &&
             !lcd_dma7_vblank))
            $fatal(1, "LCD caught_up does not match the next due phase");
    end

    always @(posedge clk) begin
        #1;
        if (!reset && ce_pixel && de !== ((dut.x < 8) && (dut.y < 192)))
            $fatal(1, "DE did not describe the active raster before ready");
        if (!reset && !ready && (red !== 0 || green !== 0 || blue !== 0))
            $fatal(1, "RGB was not black before the first frame was ready");
        if (!reset && ce_pixel) begin
            pixels_in_line = pixels_in_line + 1;
            if (!hsync) low_hsync_pixels = low_hsync_pixels + 1;

            if (dut.x == 0) begin
                if (line_started && pixels_in_line != 16)
                    $fatal(1, "line had %0d pixels", pixels_in_line);
                if (line_started && low_hsync_pixels != 3)
                    $fatal(1, "line had %0d low-hsync pixels", low_hsync_pixels);
                line_started = 1;
                pixels_in_line = 0;
                low_hsync_pixels = 0;
                lines_in_frame = lines_in_frame + 1;
                if (!vsync) low_vsync_lines = low_vsync_lines + 1;

                if (dut.y == 0) begin
                    if (frame_started && lines_in_frame != 261 + expected_extra)
                        $fatal(1, "frame %0d had %0d lines, expected %0d",
                            frames, lines_in_frame, 261 + expected_extra);
                    if (frame_started && low_vsync_lines != 6)
                        $fatal(1, "frame %0d had %0d low-vsync lines",
                            frames, low_vsync_lines);
                    if (frame_started) begin
                        frames = frames + 1;
                        next_phase = expected_phase + 11379;
                        if (next_phase >= 65536) begin
                            expected_phase = next_phase - 65536;
                            expected_extra = 1;
                        end else begin
                            expected_phase = next_phase;
                            expected_extra = 0;
                        end
                    end else begin
                        // The first observed x/y==0 can be the reset-release
                        // sample.  Synchronize to the DUT at the first full
                        // frame boundary instead of assuming it consumed a
                        // phase step.
                        expected_phase = dut.frame_phase;
                        expected_extra = dut.frame_extra;
                    end
                    frame_started = 1;
                    lines_in_frame = 0;
                    low_vsync_lines = 0;
                    if (frames == 100) begin
                        if (!lcd_tests_done)
                            $fatal(1, "local LCD/queue test did not finish");
                        $display("NDS raster timing: 100 frames passed with 16-pixel lines, 3-pixel HSYNC, 6-line VSYNC, and exact 261/262 cadence");
                        $display("NDS local LCD: initial phase plus 526 frame phases passed; full renderer queue dropped records without stopping cadence");
                        $finish;
                    end
                end
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk) reset = 0;
        // With no DDR response, the core must still generate a stable black
        // raster so MiSTer's scaler and the attached display can lock.
        wait (frames == 2);
        if (ready)
            $fatal(1, "core unexpectedly became ready without a DDR frame");
        force dut.ready = 1'b1;
        repeat (1000000) @(posedge clk);
        $fatal(1, "timeout after %0d frames", frames);
    end

    initial begin : lcd_register_and_queue_test
        logic [31:0] head_sequence;
        wait (!reset);
        // The compiled queue must identify itself while disarmed, but it must
        // expose only clean reset state and reject ACK writes until enable.
        lcd_q_raddr = 63;
        #1;
        if (!lcd_q_read_select || lcd_q_rdata != 32'h4c434451)
            $fatal(1, "disarmed LCD queue identity was not visible");
        lcd_q_raddr = 64;
        #1;
        if (lcd_q_rdata != 32'h00010000 || lcd_q_level != 0 ||
            lcd_q_producer != 0 || lcd_q_consumer != 0 ||
            lcd_q_dropped_count != 0 || lcd_q_protocol_error)
            $fatal(1, "disarmed LCD queue reset state was not clean");
        lcd_q_waddr = 73;
        lcd_q_wdata = 32'd1;
        lcd_q_be = 4'hf;
        lcd_q_write = 1'b1;
        #1;
        if (lcd_q_write_select)
            $fatal(1, "disarmed LCD queue selected an ACK write");
        lcd_q_write = 1'b0;
        lcd_q_enable = 1'b1;

        // Enable all ARM9 LCD IRQ sources and select VCOUNT 2. The local
        // controller applies this completed-write mirror after phase zero.
        @(negedge clk);
        lcd_mirror_cpu = 1'b1;
        lcd_mirror_data = 32'h00000238;
        lcd_mirror_valid = 1'b1;
        @(negedge clk);
        lcd_mirror_valid = 1'b0;

        wait (lcd_q_level == 4);
        wait (lcd_q_producer >= 6);
        #1;
        if (lcd_q_dropped_count < 2 || !lcd_q_irq)
            $fatal(1, "full LCD queue did not report dropped records");

        lcd_q_raddr = 63;
        #1;
        if (!lcd_q_read_select || lcd_q_rdata != 32'h4c434451)
            $fatal(1, "LCD queue LW magic mismatch %h", lcd_q_rdata);
        lcd_q_raddr = 66;
        #1;
        head_sequence = lcd_q_rdata;
        if (head_sequence != 1)
            $fatal(1, "LCD queue head sequence was %0d", head_sequence);

        @(negedge clk);
        lcd_q_waddr = 73;
        lcd_q_wdata = head_sequence;
        lcd_q_be = 4'hf;
        lcd_q_write = 1'b1;
        @(negedge clk);
        lcd_q_write = 1'b0;
        @(negedge clk);
        lcd_q_waddr = 74;
        lcd_q_wdata = 32'h4c41434b;
        lcd_q_write = 1'b1;
        @(negedge clk);
        lcd_q_write = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (lcd_q_consumer != head_sequence || lcd_q_level != 3 ||
            lcd_q_protocol_error)
            $fatal(1,
                "LCD queue commit failed consumer=%0d level=%0d fault=%b",
                lcd_q_consumer, lcd_q_level, lcd_q_protocol_error);
        if (lcd_q_rdata != 2)
            $fatal(1, "LCD queue head did not advance: %0d", lcd_q_rdata);
        // The queue retired one record after it had already dropped later
        // phases. The local controller continued throughout that condition.
        lcd_queue_test_done = 1;

        // Before physical line 192, write VCOUNT 5 and compare against 5.
        // VBlank must use the natural increment to 192. VMatch and the next
        // HBlank DMA decision must use the overridden live VCOUNT.
        wait (lcd_event_valid && lcd_event_kind == 1 &&
              lcd_event_line == 191);
        @(negedge clk);
        lcd_mirror_address = 32'h04000004;
        lcd_mirror_access = 2'b10;
        lcd_mirror_data = 32'h00050538;
        lcd_mirror_valid = 1'b1;
        @(negedge clk);
        lcd_mirror_valid = 1'b0;
        lcd_vcount_override_written = 1'b1;
    end
endmodule
