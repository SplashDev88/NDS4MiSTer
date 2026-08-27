`timescale 1ps/1ps

module tb_nds_h3d_plane_reader;
    localparam logic [28:0] CONTROL_BASE = 29'h00360000;
    localparam logic [28:0] BANK0_BASE = 29'h00400000;
    localparam logic [28:0] BANK1_BASE = 29'h00408000;
    localparam logic [28:0] PUB_WORD = CONTROL_BASE + 29'd6;
    localparam logic [28:0] ACK_WORD = CONTROL_BASE + 29'd7;
    localparam logic [28:0] DESC_WORD = CONTROL_BASE + 29'd8;

    // 60.0024 MHz and 33.5166 MHz, with unrelated initial phase.
    logic ddr_clk = 1'b0;
    logic pixel_clk = 1'b0;
    initial begin
        #1703;
        forever #8333 ddr_clk = ~ddr_clk;
    end
    initial begin
        #5111;
        forever #14918 pixel_clk = ~pixel_clk;
    end

    logic ddr_reset = 1'b1;
    logic pixel_reset = 1'b1;
    logic [31:0] ddr_session = 32'h51a70001;
    logic [31:0] pixel_session = 32'h51a70001;

    logic descriptor_request = 1'b0;
    logic descriptor_request_ready;
    logic line_request = 1'b0;
    logic line_request_ready;
    logic [31:0] line_frame = 32'd0;
    logic [7:0] line_y = 8'd0;
    logic frame_boundary = 1'b0;
    logic line_start = 1'b0;
    logic line_end = 1'b0;
    logic [31:0] merge_frame = 32'd0;
    logic [7:0] merge_y = 8'd0;
    logic [7:0] pixel_x = 8'd0;
    logic line_valid;
    logic [1:0] line_bank;
    logic [31:0] pixel_packed;
    logic pixel_valid;
    logic pixel_line_missed;
    logic [27:0] pixel_frame_diagnostic;

    logic busy;
    logic descriptor_busy;
    logic line_fetch_busy;
    logic descriptor_accepted;
    logic descriptor_rejected;
    logic line_loaded;
    logic line_missed;
    logic active_descriptor_valid;
    logic [31:0] active_descriptor_sequence;
    logic [31:0] active_descriptor_frame;
    logic active_descriptor_bank;
    logic pixel_descriptor_valid;
    logic pixel_descriptor_pending;
    logic [31:0] pixel_descriptor_sequence;
    logic [31:0] pixel_descriptor_frame;
    logic pixel_descriptor_bank;
    logic full_frame_publish;
    logic [1:0] full_frame_bank;
    logic full_frame_adopted = 1'b0;
    logic [31:0] console_logical_frame = 32'd0;
    logic scanline_tick = 1'b0;
    logic [7:0] scanline_y = 8'd0;
    wire [31:0] latest_complete_frame = pixel_descriptor_valid
        ? pixel_descriptor_frame : console_logical_frame;

    logic ddram_active;
    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy;
    logic ddram_command_accepted = 1'b0;
    logic [63:0] ddram_read_data = 64'd0;
    logic ddram_read_data_ready = 1'b0;

    nds_h3d_plane_reader #(
        .CONTROL_BASE_WORD(CONTROL_BASE),
        .BANK0_BASE_WORD(BANK0_BASE),
        .BANK1_BASE_WORD(BANK1_BASE)
    ) dut (
        .*
    );

    // ------------------------------------------------------------------
    // HPS descriptor and plane contents.
    // ------------------------------------------------------------------
    logic [31:0] publish_sequence = 32'd0;
    logic [31:0] descriptor_sequence = 32'd0;
    logic [31:0] descriptor_session = 32'd0;
    logic [31:0] descriptor_frame = 32'd0;
    logic [31:0] descriptor_bank = 32'd0;
    logic [31:0] descriptor_format = 32'd1;
    logic [31:0] descriptor_width_height = 32'h00c00100;
    logic [31:0] descriptor_stride = 32'd1024;
    logic tear_sequence = 1'b0;
    integer sequence_read_count = 0;

    function automatic logic [31:0] plane_pixel(
        input logic bank,
        input logic [7:0] y,
        input logic [7:0] x
    );
        logic [5:0] red;
        logic [5:0] green;
        logic [5:0] blue;
        logic [4:0] alpha;
        begin
            red = x[5:0] ^ {5'd0, bank};
            green = (x + y + (bank ? 8'd11 : 8'd3)) & 8'h3f;
            blue = (x * 3 + y * 5 + (bank ? 8'd19 : 8'd7)) &
                8'h3f;
            alpha = ((x + y + (bank ? 8'd9 : 8'd1)) % 31) + 1;
            plane_pixel = {9'd0, alpha, blue, green, red};
        end
    endfunction

    function automatic logic [63:0] descriptor_beat(
        input logic [1:0] index
    );
        begin
            case (index)
                2'd0: descriptor_beat = {32'd0, descriptor_sequence};
                2'd1: descriptor_beat = {
                    descriptor_frame, descriptor_session
                };
                2'd2: descriptor_beat = {
                    descriptor_format, descriptor_bank
                };
                default: descriptor_beat = {
                    descriptor_stride, descriptor_width_height
                };
            endcase
        end
    endfunction

    function automatic logic [63:0] response_word(
        input logic [28:0] address,
        input logic [7:0] index,
        input logic [63:0] saved_publish
    );
        logic bank;
        logic [28:0] relative_address;
        logic [7:0] y;
        logic [7:0] x0;
        begin
            response_word = 64'd0;
            if (address == PUB_WORD) begin
                response_word = saved_publish;
            end else if (address == DESC_WORD) begin
                response_word = descriptor_beat(index[1:0]);
            end else begin
                bank = address >= BANK1_BASE;
                relative_address = bank
                    ? address - BANK1_BASE : address - BANK0_BASE;
                y = relative_address[14:7];
                x0 = {index[6:0], 1'b0};
                response_word = {
                    plane_pixel(bank, y, x0 + 1'b1),
                    plane_pixel(bank, y, x0)
                };
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Randomized DDR model.  Command acceptance and each response beat have
    // independent delays.  A zero response_gap_override is used for the
    // deterministic "completion in the middle of a scan line" test.
    // ------------------------------------------------------------------
    logic command_queued = 1'b0;
    logic queued_read = 1'b0;
    logic queued_write = 1'b0;
    logic [7:0] queued_burst = 8'd0;
    logic [28:0] queued_address = 29'd0;
    logic [63:0] queued_write_data = 64'd0;
    logic [7:0] queued_byte_enable = 8'd0;
    logic [63:0] queued_publish_value = 64'd0;
    integer accept_delay = 0;
    logic read_inflight = 1'b0;
    logic [7:0] response_remaining = 8'd0;
    logic [7:0] response_index = 8'd0;
    integer response_delay = 0;
    integer response_gap_override = -1;
    logic [15:0] lfsr = 16'h3a7d;

    integer accepted_commands = 0;
    integer accepted_line_reads = 0;
    integer accepted_writes = 0;
    integer busy_stall_cycles = 0;
    integer response_gap_cycles = 0;
    integer delivered_this_line = 0;
    integer completed_line_beats = 0;
    integer ack_writes = 0;
    logic [31:0] last_ack = 32'd0;
    logic [7:0] last_ack_be = 8'd0;
    integer full_frame_publish_count = 0;
    logic [1:0] last_full_frame_bank = 0;

    always @(posedge ddr_clk) begin
        if (!ddr_reset && full_frame_publish) begin
            full_frame_publish_count <= full_frame_publish_count + 1;
            last_full_frame_bank <= full_frame_bank;
        end
    end

    wire random_idle_stall = !command_queued && !read_inflight &&
        (lfsr[2:0] == 3'b000 || lfsr[6:4] == 3'b111);
    assign ddram_busy = command_queued || read_inflight ||
        random_idle_stall;

    always @(posedge ddr_clk) begin
        if (ddr_reset) begin
            ddram_command_accepted <= 1'b0;
            ddram_read_data_ready <= 1'b0;
            ddram_read_data <= 64'd0;
            command_queued <= 1'b0;
            queued_read <= 1'b0;
            queued_write <= 1'b0;
            queued_burst <= 8'd0;
            queued_address <= 29'd0;
            queued_write_data <= 64'd0;
            queued_byte_enable <= 8'd0;
            queued_publish_value <= 64'd0;
            accept_delay <= 0;
            read_inflight <= 1'b0;
            response_remaining <= 8'd0;
            response_index <= 8'd0;
            response_delay <= 0;
            delivered_this_line <= 0;
            lfsr <= 16'h3a7d;
        end else begin
            lfsr <= {lfsr[14:0],
                lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            ddram_command_accepted <= 1'b0;
            ddram_read_data_ready <= 1'b0;

            if (ddram_active && ddram_busy)
                busy_stall_cycles <= busy_stall_cycles + 1;

            if (!command_queued && !read_inflight &&
                !ddram_command_accepted && !ddram_busy &&
                (ddram_read || ddram_write)) begin
                command_queued <= 1'b1;
                queued_read <= ddram_read;
                queued_write <= ddram_write && !ddram_read;
                queued_burst <= ddram_burst_count == 0
                    ? 8'd1 : ddram_burst_count;
                queued_address <= ddram_address;
                queued_write_data <= ddram_write_data;
                queued_byte_enable <= ddram_byte_enable;
                accept_delay <= 1 + lfsr[1:0];
                if (ddram_read && ddram_address == PUB_WORD) begin
                    if (tear_sequence && sequence_read_count != 0)
                        queued_publish_value <= {
                            32'd0, publish_sequence + 32'd2
                        };
                    else
                        queued_publish_value <= {
                            32'd0, publish_sequence
                        };
                    sequence_read_count <= sequence_read_count + 1;
                end
            end

            if (command_queued) begin
                if (accept_delay > 0) begin
                    accept_delay <= accept_delay - 1;
                end else begin
                    ddram_command_accepted <= 1'b1;
                    command_queued <= 1'b0;
                    accepted_commands <= accepted_commands + 1;
                    if (queued_read) begin
                        read_inflight <= 1'b1;
                        response_remaining <= queued_burst;
                        response_index <= 8'd0;
                        response_delay <= 1 + lfsr[3:2];
                        if (queued_burst == 8'd128) begin
                            accepted_line_reads <=
                                accepted_line_reads + 1;
                            delivered_this_line <= 0;
                        end
                    end else if (queued_write) begin
                        accepted_writes <= accepted_writes + 1;
                        if (queued_address == ACK_WORD) begin
                            ack_writes <= ack_writes + 1;
                            last_ack <= queued_write_data[31:0];
                            last_ack_be <= queued_byte_enable;
                        end
                    end
                end
            end

            if (read_inflight) begin
                if (response_delay > 0) begin
                    response_delay <= response_delay - 1;
                    response_gap_cycles <= response_gap_cycles + 1;
                end else begin
                    ddram_read_data_ready <= 1'b1;
                    ddram_read_data <= response_word(
                        queued_address,
                        response_index,
                        queued_publish_value
                    );
                    response_index <= response_index + 1'b1;
                    response_remaining <= response_remaining - 1'b1;
                    if (queued_burst == 8'd128)
                        delivered_this_line <= delivered_this_line + 1;
                    if (response_remaining <= 1) begin
                        if (queued_burst == 8'd128)
                            completed_line_beats <=
                                delivered_this_line + 1;
                        read_inflight <= 1'b0;
                        response_delay <= 0;
                    end else if (response_gap_override >= 0) begin
                        response_delay <= response_gap_override;
                    end else begin
                        response_delay <=
                            (lfsr[5] && lfsr[8]) ? 2 :
                            (lfsr[4] ? 1 : 0);
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Scoreboards for publication completeness, tag immutability and bank
    // ownership.  These checks observe the exact handshake state rather than
    // relying only on the final pixel comparisons.
    // ------------------------------------------------------------------
    integer descriptor_accept_count = 0;
    integer descriptor_reject_count = 0;
    integer line_loaded_count = 0;
    integer line_missed_count = 0;
    integer ready_publish_count = 0;
    logic [1:0] previous_ready_toggle = 2'b00;
    logic [1:0] tag_owned = 2'b00;
    logic [31:0] held_sequence [0:1];
    logic [31:0] held_session [0:1];
    logic [31:0] held_frame [0:1];
    logic held_source [0:1];
    logic [7:0] held_y [0:1];
    integer monitor_bank;

    always @(posedge ddr_clk) begin
        #1;
        if (ddr_reset) begin
            previous_ready_toggle = dut.bank_ready_toggle_ddr;
            tag_owned = 2'b00;
        end else begin
            if (descriptor_accepted)
                descriptor_accept_count = descriptor_accept_count + 1;
            if (descriptor_rejected)
                descriptor_reject_count = descriptor_reject_count + 1;
            if (line_loaded)
                line_loaded_count = line_loaded_count + 1;
            if (line_missed)
                line_missed_count = line_missed_count + 1;

            for (monitor_bank = 0; monitor_bank < 2;
                monitor_bank = monitor_bank + 1) begin
                if (dut.bank_ready_toggle_ddr[monitor_bank] !=
                    previous_ready_toggle[monitor_bank]) begin
                    if (completed_line_beats != 128)
                        $fatal(1,
                            "bank %0d published after %0d beats, not 128",
                            monitor_bank, completed_line_beats);
                    ready_publish_count = ready_publish_count + 1;
                    tag_owned[monitor_bank] = 1'b1;
                    held_sequence[monitor_bank] =
                        dut.bank_tag_sequence_ddr[monitor_bank];
                    held_session[monitor_bank] =
                        dut.bank_tag_session_ddr[monitor_bank];
                    held_frame[monitor_bank] =
                        dut.bank_tag_frame_ddr[monitor_bank];
                    held_source[monitor_bank] =
                        dut.bank_tag_source_ddr[monitor_bank];
                    held_y[monitor_bank] =
                        dut.bank_tag_y_ddr[monitor_bank];
                end else if (tag_owned[monitor_bank]) begin
                    if (held_sequence[monitor_bank] !==
                            dut.bank_tag_sequence_ddr[monitor_bank] ||
                        held_session[monitor_bank] !==
                            dut.bank_tag_session_ddr[monitor_bank] ||
                        held_frame[monitor_bank] !==
                            dut.bank_tag_frame_ddr[monitor_bank] ||
                        held_source[monitor_bank] !==
                            dut.bank_tag_source_ddr[monitor_bank] ||
                        held_y[monitor_bank] !==
                            dut.bank_tag_y_ddr[monitor_bank])
                        $fatal(1,
                            "bank %0d tag changed before acknowledge",
                            monitor_bank);
                end

                if (tag_owned[monitor_bank] &&
                    dut.bank_ack_sync_ddr[monitor_bank] ==
                        dut.bank_ready_toggle_ddr[monitor_bank])
                    tag_owned[monitor_bank] = 1'b0;
            end
            previous_ready_toggle = dut.bank_ready_toggle_ddr;
        end
    end

    // ------------------------------------------------------------------
    // Pixel-domain and cross-domain transaction helpers.
    // ------------------------------------------------------------------
    task automatic enqueue_descriptor;
        begin
            sequence_read_count = 0;
            @(negedge pixel_clk);
            descriptor_request = 1'b1;
            while (!descriptor_request_ready)
                @(negedge pixel_clk);
            @(negedge pixel_clk);
            descriptor_request = 1'b0;
        end
    endtask

    task automatic tick_scanline(input logic [7:0] y);
        begin
            @(negedge pixel_clk);
            scanline_y = y;
            scanline_tick = 1'b1;
            @(negedge pixel_clk);
            scanline_tick = 1'b0;
        end
    endtask

    task automatic descriptor_transaction(
        input logic expect_accept
    );
        integer before_accept;
        integer before_reject;
        integer timeout;
        begin
            before_accept = descriptor_accept_count;
            before_reject = descriptor_reject_count;
            enqueue_descriptor();
            timeout = 0;
            while (descriptor_accept_count == before_accept &&
                descriptor_reject_count == before_reject &&
                timeout < 10000) begin
                @(posedge ddr_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 10000)
                $fatal(1, "descriptor transaction timed out");
            if (expect_accept &&
                descriptor_accept_count != before_accept + 1)
                $fatal(1, "valid descriptor was rejected");
            if (!expect_accept &&
                descriptor_reject_count != before_reject + 1)
                $fatal(1, "invalid descriptor was accepted");
        end
    endtask

    task automatic wait_pixel_descriptor(
        input logic [31:0] expected_sequence,
        input logic [31:0] expected_frame,
        input logic expected_bank
    );
        integer timeout;
        begin
            timeout = 0;
            while ((!pixel_descriptor_valid ||
                pixel_descriptor_sequence != expected_sequence ||
                pixel_descriptor_frame != expected_frame ||
                pixel_descriptor_bank != expected_bank) &&
                timeout < 2000) begin
                @(posedge pixel_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000)
                $fatal(1,
                    "descriptor did not cross: pending=%0b requested=%0b ready=%0b ack=%0b ack_sync=%0b active=%0b active_sync=%0b seen=%0b ddr_pending=%0b ddr_sequence=%0d pixel_sequence=%0d",
                    dut.pending_descriptor_valid_pixel,
                    dut.descriptor_activation_requested_pixel,
                    dut.descriptor_ready_toggle_ddr,
                    dut.descriptor_ack_toggle_pixel,
                    dut.descriptor_ack_sync_ddr,
                    dut.descriptor_active_toggle_ddr,
                    dut.descriptor_active_sync_pixel,
                    dut.descriptor_active_seen_pixel,
                    dut.descriptor_activation_pending_ddr,
                    dut.active_descriptor_sequence,
                    pixel_descriptor_sequence);
        end
    endtask

    task automatic activate_pending_descriptor;
        integer timeout;
        begin
            timeout = 0;
            while (!dut.pending_descriptor_valid_pixel && timeout < 2000) begin
                @(posedge pixel_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000)
                $fatal(1, "pending descriptor did not reach pixel domain");
            @(negedge pixel_clk);
            frame_boundary = 1'b1;
            @(negedge pixel_clk);
            frame_boundary = 1'b0;
        end
    endtask

    task automatic wait_descriptor_ack(input logic [31:0] expected_sequence);
        integer timeout;
        begin
            timeout = 0;
            while (last_ack != expected_sequence && timeout < 2000) begin
                @(posedge ddr_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000)
                $fatal(1, "descriptor ownership ack timed out");
        end
    endtask

    task automatic enqueue_line(
        input logic [31:0] frame,
        input logic [7:0] y
    );
        begin
            @(negedge pixel_clk);
            line_frame = frame;
            line_y = y;
            line_request = 1'b1;
            while (!line_request_ready)
                @(negedge pixel_clk);
            @(negedge pixel_clk);
            line_request = 1'b0;
        end
    endtask

    task automatic line_transaction(
        input logic [31:0] frame,
        input logic [7:0] y,
        input logic expect_loaded
    );
        integer before_loaded;
        integer before_missed;
        integer timeout;
        begin
            before_loaded = line_loaded_count;
            before_missed = line_missed_count;
            enqueue_line(frame, y);
            timeout = 0;
            while (line_loaded_count == before_loaded &&
                line_missed_count == before_missed &&
                timeout < 20000) begin
                @(posedge ddr_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 20000)
                $fatal(1, "line transaction timed out y=%0d", y);
            if (expect_loaded &&
                line_loaded_count != before_loaded + 1)
                $fatal(1, "valid line missed y=%0d", y);
            if (!expect_loaded &&
                line_missed_count != before_missed + 1)
                $fatal(1, "invalid/no-space line loaded y=%0d", y);
        end
    endtask

    task automatic wait_line_available(
        input logic [31:0] frame,
        input logic [7:0] y
    );
        integer timeout;
        logic found;
        begin
            timeout = 0;
            found = 1'b0;
            while (!found && timeout < 2000) begin
                @(posedge pixel_clk);
                #1;
                found =
                    (dut.bank_available_pixel[0] &&
                        dut.bank_tag_session_pixel[0] == pixel_session &&
                        dut.bank_tag_frame_pixel[0] == frame &&
                        dut.bank_tag_y_pixel[0] == y) ||
                    (dut.bank_available_pixel[1] &&
                        dut.bank_tag_session_pixel[1] == pixel_session &&
                        dut.bank_tag_frame_pixel[1] == frame &&
                        dut.bank_tag_y_pixel[1] == y) ||
                    (dut.bank_available_pixel[2] &&
                        dut.bank_tag_session_pixel[2] == pixel_session &&
                        dut.bank_tag_frame_pixel[2] == frame &&
                        dut.bank_tag_y_pixel[2] == y);
                timeout = timeout + 1;
            end
            if (!found)
                $fatal(1,
                    "completed line did not cross to pixel domain y=%0d",
                    y);
        end
    endtask

    task automatic wait_banks_free;
        integer timeout;
        begin
            timeout = 0;
            while ((!dut.bank0_free || !dut.bank1_free ||
                    !dut.bank2_free) &&
                timeout < 2000) begin
                @(posedge ddr_clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2000)
                $fatal(1, "pixel ownership did not return both banks");
        end
    endtask

    task automatic scan_line(
        input logic [31:0] frame,
        input logic [7:0] y,
        input logic expected_valid,
        input logic source_bank
    );
        integer x;
            logic [1:0] held_selected_bank;
        logic held_selected_valid;
        logic [31:0] expected;
        begin
            held_selected_bank = 2'd0;
            held_selected_valid = 1'b0;
            for (x = 0; x < 256; x = x + 1) begin
                @(negedge pixel_clk);
                merge_frame = frame;
                merge_y = y;
                pixel_x = x;
                line_start = (x == 0);
                line_end = (x == 255);
                @(posedge pixel_clk);
                #1;
                expected = expected_valid
                    ? plane_pixel(source_bank, y, x) : 32'd0;
                if (pixel_valid !== expected_valid)
                    $fatal(1,
                        "pixel_valid changed within line y=%0d x=%0d got=%0b expected=%0b",
                        y, x, pixel_valid, expected_valid);
                if (pixel_packed !== expected)
                    $fatal(1,
                        "pixel mismatch y=%0d x=%0d got=%08x expected=%08x",
                        y, x, pixel_packed, expected);
                if (x == 0) begin
                    held_selected_bank = dut.selected_line_bank;
                    held_selected_valid = dut.selected_line_valid;
                    if (held_selected_valid !== expected_valid)
                        $fatal(1,
                            "line selection validity wrong at deadline");
                end else if (x < 255) begin
                    if (dut.selected_line_bank !== held_selected_bank ||
                        dut.selected_line_valid !== held_selected_valid)
                        $fatal(1,
                            "selected bank/valid changed during scan line");
                end
                if (x < 255 && line_valid !== expected_valid)
                    $fatal(1, "line_valid was not held for line y=%0d", y);
            end
            @(negedge pixel_clk);
            line_start = 1'b0;
            line_end = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Directed-random integration sequence.
    // ------------------------------------------------------------------
    integer before_line_reads;
    integer before_publish;
    integer before_loaded;
    integer before_missed;
    integer timeout;
    logic [31:0] next_session;
    logic [31:0] stale_colored_pixel;

    initial begin
        // Staggered deassertion proves neither domain assumes a phase or a
        // common reset-release edge.
        repeat (6) @(posedge ddr_clk);
        @(negedge ddr_clk);
        ddr_reset = 1'b0;
        repeat (4) @(posedge pixel_clk);
        @(negedge pixel_clk);
        pixel_reset = 1'b0;
        repeat (4) @(posedge pixel_clk);

        // No descriptor means a complete merge line is transparent.
        scan_line(32'd100, 8'd0, 1'b0, 1'b0);

        // Bad-session and torn descriptors cannot become active or be acked.
        publish_sequence = 32'd2;
        descriptor_sequence = 32'd2;
        descriptor_session = ddr_session ^ 32'd1;
        descriptor_frame = 32'd100;
        descriptor_bank = 32'd0;
        descriptor_transaction(1'b0);
        if (active_descriptor_valid || ack_writes != 0)
            $fatal(1, "bad-session descriptor changed active state");

        publish_sequence = 32'd4;
        descriptor_sequence = 32'd4;
        descriptor_session = ddr_session;
        tear_sequence = 1'b1;
        descriptor_transaction(1'b0);
        tear_sequence = 1'b0;

        // Stable descriptor crosses with a separate acknowledged bundle.
        publish_sequence = 32'd6;
        descriptor_sequence = 32'd6;
        descriptor_session = ddr_session;
        descriptor_frame = 32'd100;
        descriptor_bank = 32'd0;
        descriptor_transaction(1'b1);
        if (active_descriptor_valid || pixel_descriptor_valid ||
            ack_writes != 0)
            $fatal(1, "descriptor activated before frame boundary");
        activate_pending_descriptor();
        wait_pixel_descriptor(32'd6, 32'd100, 1'b0);
        wait_descriptor_ack(32'd6);
        if (last_ack != 32'd6 || last_ack_be != 8'h0f)
            $fatal(1, "descriptor ack was not a low-32-bit DDR write");

        // Polling an unchanged publication must not tear down or republish
        // the latest complete plane. A malformed refresh likewise leaves the
        // previously verified descriptor usable.
        descriptor_transaction(1'b1);
        if (!active_descriptor_valid ||
            active_descriptor_sequence != 32'd6 ||
            !pixel_descriptor_valid ||
            pixel_descriptor_sequence != 32'd6 ||
            last_ack != 32'd6)
            $fatal(1, "unchanged descriptor refresh blanked stable plane");
        publish_sequence = 32'd8;
        descriptor_sequence = 32'd8;
        descriptor_session = ddr_session ^ 32'd1;
        descriptor_transaction(1'b0);
        if (!active_descriptor_valid ||
            active_descriptor_sequence != 32'd6 ||
            !pixel_descriptor_valid ||
            pixel_descriptor_sequence != 32'd6)
            $fatal(1, "invalid descriptor refresh blanked stable plane");
        publish_sequence = 32'd6;
        descriptor_sequence = 32'd6;
        descriptor_session = ddr_session;

        // Random stalls/gaps cannot alter any of the 256 registered pixels.
        line_transaction(32'd100, 8'd5, 1'b1);
        wait_line_available(32'd100, 8'd5);
        scan_line(32'd100, 8'd5, 1'b1, 1'b0);

        // Product requests y+2 while the current and next scanline banks may
        // both still be owned.  The third bank must let that request start
        // and complete immediately rather than waiting for line_end and
        // reducing the intended two-line prefetch to one line of slack.
        wait_banks_free();
        before_loaded = line_loaded_count;
        line_transaction(32'd100, 8'd20, 1'b1);
        wait_line_available(32'd100, 8'd20);
        line_transaction(32'd100, 8'd21, 1'b1);
        wait_line_available(32'd100, 8'd21);
        line_transaction(32'd100, 8'd22, 1'b1);
        wait_line_available(32'd100, 8'd22);
        if (line_loaded_count != before_loaded + 3)
            $fatal(1, "third prefetch bank did not absorb y+2 request");
        scan_line(32'd100, 8'd20, 1'b1, 1'b0);
        scan_line(32'd100, 8'd21, 1'b1, 1'b0);
        scan_line(32'd100, 8'd22, 1'b1, 1'b0);
        wait_banks_free();

        // Start a merge line after the fetch begins but before it completes.
        // Publication occurs around the first third of the 256-pixel scan;
        // the selected invalid state must nevertheless remain transparent.
        response_gap_override = 0;
        before_publish = ready_publish_count;
        enqueue_line(32'd100, 8'd6);
        timeout = 0;
        while (!line_fetch_busy && timeout < 2000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000)
            $fatal(1, "late-line fetch never started");
        scan_line(32'd100, 8'd6, 1'b0, 1'b0);
        if (ready_publish_count != before_publish + 1)
            $fatal(1,
                "late-line test did not publish during the transparent scan");
        wait_line_available(32'd100, 8'd6);
        scan_line(32'd100, 8'd6, 1'b1, 1'b0);
        response_gap_override = -1;

        // While the first fetch owns the DDR state machine, queue four more
        // requests to fill every FIFO entry.  A sixth request must see real
        // backpressure until an entry is consumed.  The queued lines must
        // then remain ordered and wait for bank ownership rather than being
        // converted into transparent misses.
        wait_banks_free();
        before_line_reads = accepted_line_reads;
        before_loaded = line_loaded_count;
        before_missed = line_missed_count;
        enqueue_line(32'd100, 8'd40);
        timeout = 0;
        while (!line_fetch_busy && timeout < 2000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000)
            $fatal(1, "FIFO-fill test did not start first line");
        enqueue_line(32'd100, 8'd41);
        enqueue_line(32'd100, 8'd42);
        enqueue_line(32'd100, 8'd43);
        enqueue_line(32'd100, 8'd44);
        if (line_loaded_count != before_loaded)
            $fatal(1, "request FIFO did not hold four queued entries");
        @(negedge pixel_clk);
        line_frame = 32'd100;
        line_y = 8'd45;
        line_request = 1'b1;
        if (line_request_ready)
            $fatal(1, "full four-entry request FIFO did not backpressure");
        while (!line_request_ready)
            @(negedge pixel_clk);
        @(negedge pixel_clk);
        line_request = 1'b0;

        for (int queued_y = 40; queued_y <= 45; queued_y++) begin
            wait_line_available(32'd100, queued_y[7:0]);
            scan_line(32'd100, queued_y[7:0], 1'b1, 1'b0);
        end
        if (line_loaded_count != before_loaded + 6 ||
            line_missed_count != before_missed)
            $fatal(1, "bank-backpressured lines were lost or duplicated");
        if (accepted_line_reads != before_line_reads + 6)
            $fatal(1, "bank-backpressured line DDR burst count changed");
        wait_banks_free();

        // Model the two-line product prefetch directly: hold one 128-beat
        // fetch while four later raster requests queue. Once the raster has
        // advanced to line 64, generations 61 and 62 have missed their
        // two-line deadline and must be discarded without a DDR burst. Line
        // 63 is only one generation old and still has one full scanline of
        // designed slack, so it must survive alongside current line 64.
        // Treating any generation mismatch as stale discards line 63 here and
        // turns modest DDR arbitration delay into a transparent 3D stripe.
        before_line_reads = accepted_line_reads;
        before_loaded = line_loaded_count;
        before_missed = line_missed_count;
        response_gap_override = 20;
        tick_scanline(8'd60);
        enqueue_line(32'd100, 8'd60);
        timeout = 0;
        while (!line_fetch_busy && timeout < 2000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000)
            $fatal(1, "stale-generation test did not start first line");
        tick_scanline(8'd61);
        enqueue_line(32'd100, 8'd61);
        tick_scanline(8'd62);
        enqueue_line(32'd100, 8'd62);
        tick_scanline(8'd63);
        enqueue_line(32'd100, 8'd63);
        tick_scanline(8'd64);
        enqueue_line(32'd100, 8'd64);
        response_gap_override = -1;
        wait_line_available(32'd100, 8'd60);
        scan_line(32'd100, 8'd60, 1'b1, 1'b0);
        wait_line_available(32'd100, 8'd63);
        scan_line(32'd100, 8'd63, 1'b1, 1'b0);
        wait_line_available(32'd100, 8'd64);
        scan_line(32'd100, 8'd64, 1'b1, 1'b0);
        if (line_loaded_count != before_loaded + 3)
            $fatal(1,
                "scanline-age requests did not drain: loaded=%0d",
                line_loaded_count - before_loaded);
        if (accepted_line_reads != before_line_reads + 3)
            $fatal(1,
                "obsolete queued lines consumed DDR bursts: delta=%0d",
                accepted_line_reads - before_line_reads);
        if (line_missed_count != before_missed)
            $fatal(1, "obsolete queued lines asserted fatal line_missed");
        tick_scanline(8'd65);
        wait_banks_free();

        // A prefetched line whose 2D drawline is dropped never receives a
        // merge line_start. Prove that two such completed lines no longer
        // retain both banks forever: the next raw scanline expires them.
        line_transaction(32'd100, 8'd50, 1'b1);
        wait_line_available(32'd100, 8'd50);
        line_transaction(32'd100, 8'd51, 1'b1);
        wait_line_available(32'd100, 8'd51);
        tick_scanline(8'd52);
        wait_banks_free();

        // Modular expiry must release line 191 after wrap at line 0 while
        // retaining a future line 1 prefetch.
        line_transaction(32'd100, 8'd191, 1'b1);
        wait_line_available(32'd100, 8'd191);
        line_transaction(32'd100, 8'd1, 1'b1);
        wait_line_available(32'd100, 8'd1);
        tick_scanline(8'd0);
        repeat (8) @(posedge pixel_clk);
        scan_line(32'd100, 8'd1, 1'b1, 1'b0);
        wait_banks_free();

        // A verified replacement remains pending for the rest of the current
        // scanout frame. The old descriptor and its owned line stay usable
        // until the explicit architectural frame boundary, then become stale.
        line_transaction(32'd100, 8'd12, 1'b1);
        wait_line_available(32'd100, 8'd12);
        publish_sequence = 32'd8;
        descriptor_sequence = 32'd8;
        descriptor_frame = 32'd101;
        descriptor_bank = 32'd1;
        descriptor_transaction(1'b1);
        if (active_descriptor_sequence != 32'd6 ||
            pixel_descriptor_sequence != 32'd6 || last_ack != 32'd6)
            $fatal(1, "replacement descriptor activated mid-frame");
        timeout = 0;
        while (!pixel_descriptor_pending && timeout < 2000) begin
            @(posedge pixel_clk);
            timeout = timeout + 1;
        end
        if (!pixel_descriptor_pending)
            $fatal(1, "staged replacement did not suppress descriptor polling");
        scan_line(32'd100, 8'd12, 1'b1, 1'b0);
        // Verification is asynchronous to display VBlank.  A pending new
        // descriptor must not stop new fetches from the old active plane for
        // the remainder of the current scanout frame.
        line_transaction(32'd100, 8'd13, 1'b1);
        wait_line_available(32'd100, 8'd13);
        scan_line(32'd100, 8'd13, 1'b1, 1'b0);
        wait_banks_free();
        line_transaction(32'd100, 8'd12, 1'b1);
        wait_line_available(32'd100, 8'd12);
        response_gap_override = 12;
        enqueue_line(32'd100, 8'd14);
        timeout = 0;
        while (!line_fetch_busy && timeout < 2000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000)
            $fatal(1, "handoff test did not hold DDR reader busy");
        activate_pending_descriptor();
        // The VBlank pulse requests DDR activation; it must not expose the
        // replacement immediately.  The old complete line remains valid
        // while that request and confirmation cross the two clock domains.
        if (!pixel_descriptor_valid || pixel_descriptor_sequence != 32'd6 ||
                pixel_descriptor_frame != 32'd100)
            $fatal(1, "replacement exposed before DDR activation confirmation");
        scan_line(32'd100, 8'd12, 1'b1, 1'b0);
        if (!pixel_descriptor_valid || pixel_descriptor_sequence != 32'd6)
            $fatal(1, "old descriptor was not held through busy DDR handoff");
        response_gap_override = -1;
        wait_pixel_descriptor(32'd8, 32'd101, 1'b1);
        if (pixel_descriptor_pending)
            $fatal(1, "descriptor pending remained set after activation");
        scan_line(32'd100, 8'd12, 1'b0, 1'b0);
        wait_banks_free();
        line_transaction(32'd101, 8'd12, 1'b1);
        wait_line_available(32'd101, 8'd12);
        scan_line(32'd101, 8'd12, 1'b1, 1'b1);
        wait_banks_free();

        // Change the epoch after several response beats.  The burst may
        // finish writing unused RAM, but its ready toggle must not publish.
        response_gap_override = 1;
        before_publish = ready_publish_count;
        before_missed = line_missed_count;
        enqueue_line(32'd101, 8'd20);
        timeout = 0;
        while ((!line_fetch_busy || dut.fetch_beat_count < 8'd9) &&
            timeout < 5000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 5000)
            $fatal(1, "session-change fetch did not return initial beats");
        next_session = ddr_session + 32'd1;
        @(negedge ddr_clk);
        ddr_session = next_session;
        @(negedge pixel_clk);
        pixel_session = next_session;
        timeout = 0;
        while (line_missed_count == before_missed && timeout < 5000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 5000 || ready_publish_count != before_publish)
            $fatal(1, "stale mid-fetch session published a line");
        scan_line(32'd101, 8'd20, 1'b0, 1'b1);
        response_gap_override = -1;

        // Re-establish a descriptor in the new session and prove recovery.
        descriptor_session = next_session;
        publish_sequence = 32'd10;
        descriptor_sequence = 32'd10;
        descriptor_frame = 32'd102;
        descriptor_bank = 32'd0;
        descriptor_transaction(1'b1);
        activate_pending_descriptor();
        wait_pixel_descriptor(32'd10, 32'd102, 1'b0);
        line_transaction(32'd102, 8'd21, 1'b1);
        wait_line_available(32'd102, 8'd21);
        scan_line(32'd102, 8'd21, 1'b1, 1'b0);
        wait_banks_free();

        // Assert both resets in the middle of another burst, increment the
        // session, then release the two clocks at unrelated edges.  Stale RAM
        // contents and old toggle phases must remain invisible.
        enqueue_line(32'd102, 8'd30);
        timeout = 0;
        while ((!line_fetch_busy || dut.fetch_beat_count < 8'd9) &&
            timeout < 5000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 5000)
            $fatal(1, "reset test fetch did not return initial beats");
        next_session = ddr_session + 32'd1;
        @(negedge ddr_clk);
        ddr_reset = 1'b1;
        pixel_reset = 1'b1;
        ddr_session = next_session;
        pixel_session = next_session;
        repeat (5) @(posedge ddr_clk);
        @(negedge ddr_clk);
        ddr_reset = 1'b0;
        repeat (4) @(posedge pixel_clk);
        @(negedge pixel_clk);
        pixel_reset = 1'b0;
        repeat (5) @(posedge pixel_clk);
        scan_line(32'd102, 8'd30, 1'b0, 1'b0);

        descriptor_session = next_session;
        publish_sequence = 32'd12;
        descriptor_sequence = 32'd12;
        descriptor_frame = 32'd103;
        descriptor_bank = 32'd1;
        descriptor_transaction(1'b1);
        activate_pending_descriptor();
        wait_pixel_descriptor(32'd12, 32'd103, 1'b1);
        // A synchronous console can already be two logical frames beyond a
        // completed HPS plane.  Product wiring deliberately tags both the
        // request and merge deadline with the accepted descriptor frame, not
        // the newer console counter, so the latest complete plane remains
        // visible.  x=21 on this line is an opaque, colored (not white) pixel;
        // scan_line proves that exact A31:B6:G6:R6 value reaches the reader.
        console_logical_frame = 32'd105;
        if (latest_complete_frame != 32'd103 ||
            console_logical_frame - latest_complete_frame != 32'd2)
            $fatal(1, "latest-complete frame tag did not retain stale-by-2 descriptor");
        stale_colored_pixel = plane_pixel(1'b1, 8'd31, 8'd21);
        if (stale_colored_pixel[22:18] != 5'd31 ||
            stale_colored_pixel[17:0] == 18'h3ffff)
            $fatal(1, "stale-by-2 proof pixel is not opaque colored A31");
        line_transaction(latest_complete_frame, 8'd31, 1'b1);
        wait_line_available(latest_complete_frame, 8'd31);
        scan_line(latest_complete_frame, 8'd31, 1'b1, 1'b1);
        wait_banks_free();

        // Format 2 publishes a complete ARM-rendered framebuffer bank. It
        // activates at the same frame boundary but must not become a 3D plane
        // descriptor, and ownership ACK waits for scanout adoption.
        publish_sequence = 32'd14;
        descriptor_sequence = 32'd14;
        descriptor_frame = 32'd104;
        descriptor_bank = 32'd3;
        descriptor_format = 32'd2;
        descriptor_transaction(1'b1);
        activate_pending_descriptor();
        timeout = 0;
        while (full_frame_publish_count == 0 && timeout < 2000) begin
            @(posedge ddr_clk);
            timeout = timeout + 1;
        end
        while ((pixel_descriptor_pending || pixel_descriptor_valid) &&
                timeout < 4000) begin
            @(posedge pixel_clk);
            timeout = timeout + 1;
        end
        if (timeout >= 4000 || last_full_frame_bank != 2'd3 ||
            pixel_descriptor_valid || last_ack != 32'd12)
            $fatal(1, "full framebuffer descriptor activated or ACKed incorrectly");
        @(negedge ddr_clk);
        full_frame_adopted = 1'b1;
        @(negedge ddr_clk);
        full_frame_adopted = 1'b0;
        wait_descriptor_ack(32'd14);

        if (accepted_commands < 20 || accepted_line_reads < 10 ||
            busy_stall_cycles < 20 || response_gap_cycles < 100 ||
            ready_publish_count < 8)
            $fatal(1,
                "randomized test coverage too weak: commands=%0d lines=%0d busy=%0d gaps=%0d publishes=%0d",
                accepted_commands, accepted_line_reads,
                busy_stall_cycles, response_gap_cycles,
                ready_publish_count);

        $display(
            "PASS: dual-clock H3D bridge accepted %0d commands and %0d line bursts across unrelated clocks; %0d complete lines published only after 128 beats, tags stayed immutable until ack, no owned bank was overwritten, late/stale/reset lines stayed transparent, and every valid 256-pixel line matched",
            accepted_commands, accepted_line_reads, ready_publish_count
        );
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "dual-clock H3D plane reader test timeout");
    end
endmodule
