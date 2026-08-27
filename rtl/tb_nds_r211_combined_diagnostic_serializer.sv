`timescale 1ns/1ps
`default_nettype none

module tb_nds_r211_combined_diagnostic_serializer;
    logic clk = 1'b0;
    logic reset = 1'b1;

    logic input_completed_valid = 1'b0;
    logic [31:0] input_status_payload = 32'd0;
    logic [31:0] input_first_retire_pc = 32'd0;
    logic [31:0] input_later_retire_pc = 32'd0;

    logic final_audio_takeover = 1'b0;
    logic [31:0] audio_page_cause = 32'd0;
    logic [31:0] audio_page_raw = 32'd0;
    logic [31:0] audio_page_post = 32'd0;
    logic [31:0] audio_page_final = 32'd0;
    logic [31:0] audio_page_activity = 32'd0;
    logic [11:0] joystick = 12'd0;

    logic [1:0] diagnostic_phase;
    logic [2:0] diagnostic_page;
    logic [7:0] diagnostic_marker;
    logic [31:0] diagnostic_snapshot;
    logic diagnostic_snapshot_strobe;
    logic [31:0] diagnostic_word;

    logic monitor_armed = 1'b0;
    logic [2:0] previous_page = 3'd0;
    logic [7:0] previous_marker = 8'hf0;
    logic [31:0] previous_snapshot = 32'd0;
    integer tick_count = 0;
    integer page_index;
    integer other_page_index;

    always #5 clk = ~clk;

    nds_r211_combined_diagnostic_serializer #(
        .PHASE_DIVIDER_WIDTH(1)
    ) dut (
        .*
    );

    task automatic require (
        input logic condition,
        input string message
    );
        begin
            if (condition !== 1'b1)
                $fatal(1, "%s", message);
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
            tick_count = tick_count + 1;
        end
    endtask

    function automatic logic [7:0] expected_marker (
        input logic [2:0] page,
        input logic valid
    );
        begin
            expected_marker =
                8'hf0 | {4'd0, page, 1'b0} | {7'd0, valid};
        end
    endfunction

    function automatic logic [31:0] current_payload (
        input logic [2:0] page
    );
        begin
            case (page)
                3'd0: current_payload = input_status_payload;
                3'd1: current_payload = input_first_retire_pc;
                3'd2: current_payload = input_later_retire_pc;
                3'd3: current_payload = audio_page_cause;
                3'd4: current_payload = audio_page_raw;
                3'd5: current_payload = audio_page_post;
                3'd6: current_payload = audio_page_final;
                3'd7: current_payload = audio_page_activity;
                default: current_payload = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [7:0] payload_byte (
        input logic [31:0] payload,
        input logic [1:0] phase
    );
        begin
            case (phase)
                2'd0: payload_byte = payload[7:0];
                2'd1: payload_byte = payload[15:8];
                2'd2: payload_byte = payload[23:16];
                2'd3: payload_byte = payload[31:24];
                default: payload_byte = 8'd0;
            endcase
        end
    endfunction

    task automatic reset_dut;
        begin
            reset = 1'b1;
            input_completed_valid = 1'b0;
            input_status_payload = 32'd0;
            input_first_retire_pc = 32'd0;
            input_later_retire_pc = 32'd0;
            final_audio_takeover = 1'b0;
            audio_page_cause = 32'd0;
            audio_page_raw = 32'd0;
            audio_page_post = 32'd0;
            audio_page_final = 32'd0;
            audio_page_activity = 32'd0;
            joystick = 12'd0;
            tick();
            tick();
            reset = 1'b0;
            tick();
        end
    endtask

    task automatic load_primary_pages;
        begin
            input_status_payload = 32'hc70a_03fe;
            input_first_retire_pc = 32'h0204_4668;
            input_later_retire_pc = 32'h0201_05fc;
            audio_page_cause = 32'h1122_3344;
            audio_page_raw = 32'h8192_7e6d;
            audio_page_post = 32'ha5b6_c7d8;
            audio_page_final = 32'h0f1e_2d3c;
            audio_page_activity = 32'hdead_beef;
            input_completed_valid = 1'b1;
            final_audio_takeover = 1'b1;
        end
    endtask

    task automatic load_sparse_pages;
        begin
            input_status_payload = 32'h81c3_03fd;
            input_first_retire_pc = 32'h1357_9bdf;
            input_later_retire_pc = 32'h2468_ace0;
            audio_page_cause = 32'h1020_3040;
            audio_page_raw = 32'h5162_7384;
            audio_page_post = 32'h95a6_b7c8;
            audio_page_final = 32'hd9ea_fb0c;
            audio_page_activity = 32'h1d2e_3f40;
            input_completed_valid = 1'b1;
            final_audio_takeover = 1'b1;
        end
    endtask

    task automatic wait_capture (
        input logic [2:0] wanted_page
    );
        integer clocks;
        begin
            clocks = 0;
            if (diagnostic_snapshot_strobe)
                tick();
            while (!(diagnostic_snapshot_strobe &&
                     diagnostic_page == wanted_page) &&
                   clocks < 1000) begin
                tick();
                clocks = clocks + 1;
            end
            require(diagnostic_snapshot_strobe &&
                    diagnostic_page == wanted_page,
                "timed out waiting for requested page boundary");
            require(diagnostic_phase == 2'd0,
                "page capture did not start at phase zero");
        end
    endtask

    task automatic wait_state (
        input logic [2:0] wanted_page,
        input logic [1:0] wanted_phase
    );
        integer clocks;
        begin
            clocks = 0;
            while (!(diagnostic_page == wanted_page &&
                     diagnostic_phase == wanted_phase) &&
                   clocks < 1000) begin
                tick();
                clocks = clocks + 1;
            end
            require(diagnostic_page == wanted_page &&
                    diagnostic_phase == wanted_phase,
                "timed out waiting for requested page/phase");
        end
    endtask

    task automatic check_current_word (
        input logic [2:0] wanted_page,
        input logic [7:0] wanted_marker,
        input logic [31:0] wanted_payload
    );
        begin
            #1;
            require(diagnostic_page == wanted_page,
                "diagnostic page changed unexpectedly");
            if (diagnostic_marker !== wanted_marker)
                $fatal(
                    1,
                    "diagnostic marker mismatch page=%0d phase=%0d expected=%02x actual=%02x snapshot=%08x",
                    wanted_page,
                    diagnostic_phase,
                    wanted_marker,
                    diagnostic_marker,
                    diagnostic_snapshot);
            require(diagnostic_snapshot == wanted_payload,
                "diagnostic snapshot mismatch");
            require(diagnostic_word[31:24] == wanted_marker,
                "transport marker does not match captured marker");
            require(diagnostic_word[23] == 1'b0 &&
                    diagnostic_word[20] == 1'b0,
                "reserved framing bits changed");
            require(diagnostic_word[22:21] == diagnostic_phase,
                "transport phase does not match serializer phase");
            require(diagnostic_word[19:12] ==
                    payload_byte(wanted_payload, diagnostic_phase),
                "transport payload byte mismatch");
            require(diagnostic_word[11:0] === joystick,
                "live joystick bits were masked or substituted");
            require(diagnostic_marker[7:4] == 4'hf &&
                    diagnostic_marker[3:1] == wanted_page,
                "marker collided with a different diagnostic page");
        end
    endtask

    task automatic check_rotation (
        input logic [2:0] wanted_page,
        input logic [7:0] wanted_marker,
        input logic [31:0] wanted_payload
    );
        integer phase_index;
        begin
            for (phase_index = 0; phase_index < 4;
                 phase_index = phase_index + 1) begin
                wait_state(wanted_page, phase_index[1:0]);
                joystick =
                    12'h300 + {7'd0, wanted_page, phase_index[1:0]};
                check_current_word(
                    wanted_page, wanted_marker, wanted_payload);
            end
        end
    endtask

    task automatic sparse_reconstruct (
        input logic [2:0] wanted_page,
        input logic [31:0] wanted_payload
    );
        logic [31:0] reconstructed;
        logic [1:0] wanted_phase;
        integer sample_index;
        integer clocks;
        integer previous_sample_tick;
        begin
            reconstructed = 32'd0;
            previous_sample_tick = -1000;

            // Deliberately nonsequential: phase 2, then a later rotation's
            // phase 0, then phase 3, then a still later rotation's phase 1.
            for (sample_index = 0; sample_index < 4;
                 sample_index = sample_index + 1) begin
                case (sample_index)
                    0: wanted_phase = 2'd2;
                    1: wanted_phase = 2'd0;
                    2: wanted_phase = 2'd3;
                    default: wanted_phase = 2'd1;
                endcase

                clocks = 0;
                while (!(diagnostic_page == wanted_page &&
                         diagnostic_phase == wanted_phase) &&
                       clocks < 4000) begin
                    tick();
                    clocks = clocks + 1;
                end
                require(diagnostic_page == wanted_page &&
                        diagnostic_phase == wanted_phase,
                    "sparse sampler timed out");
                require(tick_count - previous_sample_tick > 1,
                    "sparse sampler accidentally used consecutive clocks");

                joystick =
                    12'h600 + {7'd0, wanted_page, wanted_phase};
                check_current_word(
                    wanted_page,
                    expected_marker(wanted_page, 1'b1),
                    wanted_payload);
                case (wanted_phase)
                    2'd0:
                        reconstructed[7:0] =
                            diagnostic_word[19:12];
                    2'd1:
                        reconstructed[15:8] =
                            diagnostic_word[19:12];
                    2'd2:
                        reconstructed[23:16] =
                            diagnostic_word[19:12];
                    2'd3:
                        reconstructed[31:24] =
                            diagnostic_word[19:12];
                    default: reconstructed = 32'd0;
                endcase
                previous_sample_tick = tick_count;
                tick();
            end

            require(reconstructed == wanted_payload,
                "sparse nonconsecutive samples did not reconstruct page");
        end
    endtask

    // Independent transport invariants: marker/page/payload fields may change
    // only on a page-boundary strobe, while low joystick bits remain live.
    always @(negedge clk) begin
        if (reset) begin
            monitor_armed = 1'b0;
        end else begin
            require((^diagnostic_marker !== 1'bx) &&
                    diagnostic_marker[7:4] == 4'hf,
                "serializer emitted an unknown/non-F marker");
            require(diagnostic_marker[3:1] == diagnostic_page,
                "marker-to-page mapping collided");
            require(diagnostic_word[31:24] == diagnostic_marker &&
                    diagnostic_word[22:21] == diagnostic_phase,
                "serialized header is not live from captured state");
            require(diagnostic_word[11:0] === joystick,
                "background monitor saw non-live joystick bits");
            if (diagnostic_snapshot_strobe)
                require(diagnostic_phase == 2'd0,
                    "snapshot strobe occurred away from page boundary");

            if (monitor_armed &&
                (diagnostic_page !== previous_page ||
                 diagnostic_marker !== previous_marker ||
                 diagnostic_snapshot !== previous_snapshot))
                require(diagnostic_snapshot_strobe,
                    "page, marker, or payload changed off boundary");

            previous_page = diagnostic_page;
            previous_marker = diagnostic_marker;
            previous_snapshot = diagnostic_snapshot;
            monitor_armed = 1'b1;
        end
    end

    initial begin
        reset_dut();

        joystick = 12'ha5a;
        #1;
        require(diagnostic_page == 3'd0 &&
                diagnostic_phase == 2'd0 &&
                diagnostic_marker == 8'hf0 &&
                diagnostic_snapshot == 32'd0,
            "reset transport state was not fail closed");
        require(diagnostic_word[11:0] == 12'ha5a,
            "joystick was not live in reset transport state");

        // Prove the complete F0..FF allocation is one-to-one.  An even or odd
        // marker for one page must never name any other page.
        for (page_index = 0; page_index < 8;
             page_index = page_index + 1) begin
            require(expected_marker(page_index[2:0], 1'b0) !=
                    expected_marker(page_index[2:0], 1'b1),
                "one page's valid and fallback markers collided");
            for (other_page_index = 0; other_page_index < 8;
                 other_page_index = other_page_index + 1) begin
                if (page_index != other_page_index) begin
                    require(
                        expected_marker(page_index[2:0], 1'b0) !=
                        expected_marker(
                            other_page_index[2:0], 1'b0) &&
                        expected_marker(page_index[2:0], 1'b0) !=
                        expected_marker(
                            other_page_index[2:0], 1'b1) &&
                        expected_marker(page_index[2:0], 1'b1) !=
                        expected_marker(
                            other_page_index[2:0], 1'b0) &&
                        expected_marker(page_index[2:0], 1'b1) !=
                        expected_marker(
                            other_page_index[2:0], 1'b1),
                        "marker allocation collided across pages");
                end
            end
        end

        // A normal released KEYINPUT completion must not consume the one-shot
        // input bundle. Pages F0/F2/F4 stay invalid and zero until a completed,
        // fully known non-released response arrives.
        load_primary_pages();
        input_status_payload = 32'hc70a_03ff;
        tick();
        for (page_index = 0; page_index < 3;
             page_index = page_index + 1) begin
            wait_capture(page_index[2:0]);
            check_rotation(
                page_index[2:0],
                expected_marker(page_index[2:0], 1'b0),
                32'd0);
        end

        // A non-released low ten bits with reserved response bits set is not
        // a valid KEYINPUT value and must not consume the one-shot capture.
        input_status_payload = 32'hc70a_83fe;
        tick();
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf0 &&
                diagnostic_snapshot == 32'd0,
            "reserved KEYINPUT response bits froze an input bundle");

        // The later held-A witness (03FE) is the first eligible bundle and
        // becomes the immutable three-page input generation.
        input_status_payload = 32'hc70a_03fe;
        input_first_retire_pc = 32'h0204_4668;
        input_later_retire_pc = 32'h0201_05fc;
        tick();

        // Every valid page must appear once, in order, with four immutable
        // little-endian byte phases and continuously live joystick bits.
        for (page_index = 0; page_index < 8;
             page_index = page_index + 1) begin
            wait_capture(page_index[2:0]);
            require(diagnostic_marker ==
                    expected_marker(page_index[2:0], 1'b1),
                "valid rotation selected the wrong odd marker");
            check_rotation(
                page_index[2:0],
                expected_marker(page_index[2:0], 1'b1),
                current_payload(page_index[2:0]));
        end

        // Reconstruct every page from deliberately sparse, nonconsecutive,
        // out-of-order phase observations separated by other pages/rotations.
        // Reset first so this scenario freezes its own pressed input bundle.
        reset_dut();
        load_sparse_pages();
        tick();
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf1 &&
                diagnostic_snapshot == 32'h81c3_03fd,
            "sparse setup did not capture pressed input generation");
        for (page_index = 0; page_index < 8;
             page_index = page_index + 1)
            sparse_reconstruct(
                page_index[2:0], current_payload(page_index[2:0]));

        // Replace all three live completed fields with a later released
        // witness halfway through page 0. The active page remains atomic, and
        // pages 1/2 plus the next page 0 must still be the original pressed
        // generation. This is the adversarial sparse-generation tear case.
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf1 &&
                diagnostic_snapshot == 32'h81c3_03fd,
            "pressed input generation was not frozen");
        wait_state(3'd0, 2'd1);
        input_status_payload = 32'h91d4_03ff;
        input_first_retire_pc = 32'h0300_1000;
        input_later_retire_pc = 32'h0300_2000;
        joystick = 12'h711;
        check_current_word(3'd0, 8'hf1, 32'h81c3_03fd);
        wait_state(3'd0, 2'd3);
        check_current_word(3'd0, 8'hf1, 32'h81c3_03fd);
        wait_capture(3'd1);
        require(diagnostic_marker == 8'hf3 &&
                diagnostic_snapshot == 32'h1357_9bdf,
            "later release tore the frozen first retirement PC");
        wait_capture(3'd2);
        require(diagnostic_marker == 8'hf5 &&
                diagnostic_snapshot == 32'h2468_ace0,
            "later release tore the frozen later retirement PC");
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf1 &&
                diagnostic_snapshot == 32'h81c3_03fd,
            "later release replaced the frozen pressed status");

        // A later observer invalidation changes parity only at the next page
        // boundary; it cannot modify the already frozen payload generation.
        wait_state(3'd0, 2'd1);
        input_completed_valid = 1'b0;
        check_current_word(3'd0, 8'hf1, 32'h81c3_03fd);
        wait_capture(3'd1);
        require(diagnostic_marker == 8'hf2 &&
                diagnostic_snapshot == 32'h1357_9bdf,
            "observer invalidation tore frozen input evidence");
        input_completed_valid = 1'b1;
        #1;
        require(diagnostic_marker == 8'hf2 &&
                diagnostic_snapshot == 32'h1357_9bdf,
            "input validity changed an active rotation");

        // Apply a separate mid-rotation stress to the first audio page.
        reset_dut();
        load_sparse_pages();
        tick();
        audio_page_cause = 32'h7654_3210;
        final_audio_takeover = 1'b1;
        wait_capture(3'd3);
        require(diagnostic_marker == 8'hf7 &&
                diagnostic_snapshot == 32'h7654_3210,
            "audio page did not capture the pre-update pair");
        wait_state(3'd3, 2'd2);
        audio_page_cause = 32'h89ab_cdef;
        final_audio_takeover = 1'b0;
        joystick = 12'h732;
        check_current_word(3'd3, 8'hf7, 32'h7654_3210);
        wait_state(3'd3, 2'd3);
        check_current_word(3'd3, 8'hf7, 32'h7654_3210);
        wait_capture(3'd3);
        require(diagnostic_marker == 8'hf6 &&
                diagnostic_snapshot == 32'h89ab_cdef,
            "audio marker/payload did not update atomically");
        final_audio_takeover = 1'b1;
        #1;
        require(diagnostic_marker == 8'hf6 &&
                diagnostic_snapshot == 32'h89ab_cdef,
            "audio takeover changed an active rotation");

        // Known false qualifiers select all eight unique even markers. Before
        // a pressed input capture, the three input pages remain zero; known
        // audio evidence remains available under its even fallback markers.
        reset_dut();
        load_sparse_pages();
        input_completed_valid = 1'b0;
        final_audio_takeover = 1'b0;
        tick();
        for (page_index = 0; page_index < 8;
             page_index = page_index + 1) begin
            wait_capture(page_index[2:0]);
            require(diagnostic_marker ==
                    expected_marker(page_index[2:0], 1'b0),
                "fallback rotation marker mismatch");
            if (page_index < 3)
                require(diagnostic_snapshot == 32'd0,
                    "uncaptured input page exposed live evidence");
            else
                require(diagnostic_snapshot ==
                        current_payload(page_index[2:0]),
                    "fallback audio payload mismatch");
        end

`ifndef VERILATOR
        // Four-state-only injection. Verilator compiles the same logic but
        // its two-state runtime cannot create genuine X values. Start with a
        // valid pressed bundle so all X cases exercise an existing frozen
        // generation as well as fail-closed marker selection.
        reset_dut();
        load_primary_pages();
        tick();
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf1,
            "four-state setup did not freeze pressed input");

        input_completed_valid = 1'bx;
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf0 &&
                diagnostic_snapshot == 32'hc70a_03fe,
            "unknown completion validity did not fail closed");

        input_completed_valid = 1'b1;
        input_status_payload = 32'hxxxx_xxxx;
        wait_capture(3'd0);
        require(diagnostic_marker == 8'hf0 &&
                diagnostic_snapshot == 32'hc70a_03fe,
            "unknown input status escaped fail-closed transport");
        input_status_payload = 32'h1234_03ff;

        input_first_retire_pc = 32'hxxxx_xxxx;
        wait_capture(3'd1);
        require(diagnostic_marker == 8'hf2 &&
                diagnostic_snapshot == 32'h0204_4668,
            "unknown first retirement PC escaped fail closed");
        input_first_retire_pc = 32'h0204_4668;

        input_later_retire_pc = 32'hxxxx_xxxx;
        wait_capture(3'd2);
        require(diagnostic_marker == 8'hf4 &&
                diagnostic_snapshot == 32'h0201_05fc,
            "unknown later retirement PC escaped fail closed");
        input_later_retire_pc = 32'h0201_05fc;

        final_audio_takeover = 1'bx;
        wait_capture(3'd3);
        require(diagnostic_marker == 8'hf6 &&
                diagnostic_snapshot == audio_page_cause,
            "unknown audio takeover did not select even marker");

        final_audio_takeover = 1'b1;
        audio_page_cause = 32'hxxxx_xxxx;
        wait_capture(3'd3);
        require(diagnostic_marker == 8'hf6 &&
                diagnostic_snapshot == 32'd0,
            "unknown audio payload escaped fail-closed transport");
        audio_page_cause = 32'h89ab_cdef;

        joystick = 12'b1010_x101_0011;
        #1;
        require(diagnostic_word[11:0] === joystick,
            "unknown joystick bit was not passed through live");
        joystick = 12'h753;
`endif

        $display("PASS: r211 combined serializer atomically rotates F0..FF, preserves live joystick bits, reconstructs sparse captures, and fails closed on X");
        $finish;
    end
endmodule

`default_nettype wire
