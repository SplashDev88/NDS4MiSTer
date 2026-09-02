`timescale 1ns/1ps
`default_nettype none

module tb_nds_r211_audio_path_diagnostic;
    logic clk = 1'b0;
    logic reset = 1'b1;

    logic register_bus_ena = 1'b0;
    logic [27:0] register_bus_address = 28'd0;
    logic [31:0] register_bus_write_data = 32'd0;
    logic [3:0] register_bus_byte_enable = 4'd0;
    logic engine_cycles_valid = 1'b0;
    logic [7:0] engine_cycles = 8'd0;
    logic signed [15:0] raw_audio_left = 16'sd0;
    logic signed [15:0] raw_audio_right = 16'sd0;
    logic signed [15:0] post_audio_left = 16'sd0;
    logic signed [15:0] post_audio_right = 16'sd0;
    logic signed [15:0] final_audio_left = 16'sd0;
    logic signed [15:0] final_audio_right = 16'sd0;
    logic final_audio_takeover = 1'b0;
    logic engine_sample_request = 1'b0;
    logic sample_ddram_command_accepted = 1'b0;
    logic [63:0] sample_ddram_read_data = 64'd0;
    logic sample_ddram_read_data_ready = 1'b0;
    logic [11:0] joystick = 12'd0;

    logic ch8_keyon_pulse;
    logic ch9_keyon_pulse;
    logic cause_frozen;
    logic witness_captured;
    logic [31:0] cause_word;
    logic [31:0] raw_witness_word;
    logic [31:0] post_witness_word;
    logic [31:0] final_witness_word;
    logic [31:0] activity_summary_word;
    logic [1:0] diagnostic_phase;
    logic [2:0] diagnostic_page;
    logic [7:0] diagnostic_marker;
    logic [31:0] diagnostic_snapshot;
    logic diagnostic_snapshot_strobe;
    logic [31:0] diagnostic_word;

    logic serializer_reset = 1'b1;
    logic serializer_takeover = 1'b0;
    logic [11:0] serializer_joystick = 12'd0;
    logic [31:0] serializer_page_0 = 32'd0;
    logic [31:0] serializer_page_1 = 32'd0;
    logic [31:0] serializer_page_2 = 32'd0;
    logic [31:0] serializer_page_3 = 32'd0;
    logic [31:0] serializer_page_4 = 32'd0;
    logic [1:0] serializer_phase;
    logic [2:0] serializer_page;
    logic [7:0] serializer_marker;
    logic [31:0] serializer_snapshot;
    logic serializer_snapshot_strobe;
    logic [31:0] serializer_word;

    integer iteration;
    integer capture_index;

    always #5 clk = ~clk;

    nds_r211_audio_path_diagnostic #(
        .PHASE_DIVIDER_WIDTH(2)
    ) dut (
        .*
    );

    nds_r211_audio_path_serializer #(
        .PHASE_DIVIDER_WIDTH(1)
    ) serializer_dut (
        .clk,
        .reset(serializer_reset),
        .final_audio_takeover(serializer_takeover),
        .joystick(serializer_joystick),
        .page_0_cause(serializer_page_0),
        .page_1_raw(serializer_page_1),
        .page_2_post(serializer_page_2),
        .page_3_final(serializer_page_3),
        .page_4_activity(serializer_page_4),
        .diagnostic_phase(serializer_phase),
        .diagnostic_page(serializer_page),
        .diagnostic_marker(serializer_marker),
        .diagnostic_snapshot(serializer_snapshot),
        .diagnostic_snapshot_strobe(serializer_snapshot_strobe),
        .diagnostic_word(serializer_word)
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
        end
    endtask

    task automatic reset_observer;
        begin
            reset = 1'b1;
            register_bus_ena = 1'b0;
            register_bus_address = 28'd0;
            register_bus_write_data = 32'd0;
            register_bus_byte_enable = 4'd0;
            engine_cycles_valid = 1'b0;
            engine_cycles = 8'd0;
            raw_audio_left = 16'sd0;
            raw_audio_right = 16'sd0;
            post_audio_left = 16'sd0;
            post_audio_right = 16'sd0;
            final_audio_left = 16'sd0;
            final_audio_right = 16'sd0;
            final_audio_takeover = 1'b0;
            engine_sample_request = 1'b0;
            sample_ddram_command_accepted = 1'b0;
            sample_ddram_read_data = 64'd0;
            sample_ddram_read_data_ready = 1'b0;
            joystick = 12'h000;
            tick();
            tick();
            reset = 1'b0;
            tick();
        end
    endtask

    task automatic seam_cycle (
        input logic [27:0] address,
        input logic [31:0] write_data,
        input logic [3:0] byte_enable
    );
        begin
            register_bus_ena = 1'b1;
            register_bus_address = address;
            register_bus_write_data = write_data;
            register_bus_byte_enable = byte_enable;
            #1;
            require(
                ch8_keyon_pulse ===
                    (address == 28'h480 &&
                     byte_enable == 4'b1000 &&
                     write_data[31:24] == 8'he3),
                "ch8 exact seam pulse mismatch");
            require(
                ch9_keyon_pulse ===
                    (address == 28'h490 &&
                     byte_enable == 4'b1000 &&
                     write_data[31:24] == 8'he3),
                "ch9 exact seam pulse mismatch");
            tick();
            register_bus_ena = 1'b0;
            register_bus_address = 28'd0;
            register_bus_write_data = 32'd0;
            register_bus_byte_enable = 4'd0;
        end
    endtask

    task automatic engine_beat(input logic [7:0] credits);
        begin
            engine_cycles = credits;
            engine_cycles_valid = 1'b1;
            tick();
            engine_cycles_valid = 1'b0;
            engine_cycles = 8'd0;
        end
    endtask

    task automatic request_pulse;
        begin
            engine_sample_request = 1'b1;
            tick();
            engine_sample_request = 1'b0;
            tick();
        end
    endtask

    task automatic return_beat(input logic [63:0] data);
        begin
            sample_ddram_read_data = data;
            sample_ddram_read_data_ready = 1'b1;
            tick();
            sample_ddram_read_data_ready = 1'b0;
            sample_ddram_read_data = 64'd0;
        end
    endtask

    task automatic wait_serializer_snapshot(input logic [2:0] wanted_page);
        integer clocks;
        begin
            // Always advance at least one clock so an already asserted strobe
            // cannot satisfy a second wait.
            tick();
            clocks = 1;
            while (!(serializer_snapshot_strobe &&
                     serializer_page == wanted_page) &&
                   clocks < 100) begin
                tick();
                clocks = clocks + 1;
            end
            require(
                serializer_snapshot_strobe &&
                serializer_page == wanted_page,
                "serializer did not reach requested page");
        end
    endtask

    task automatic wait_serializer_phase(input logic [1:0] wanted_phase);
        integer clocks;
        begin
            clocks = 0;
            while (serializer_phase != wanted_phase && clocks < 20) begin
                tick();
                clocks = clocks + 1;
            end
            require(serializer_phase == wanted_phase,
                "serializer did not reach requested phase");
        end
    endtask

    task automatic check_serializer_rotation (
        input logic [2:0] wanted_page,
        input logic [7:0] wanted_marker,
        input logic [31:0] wanted_snapshot
    );
        logic [7:0] wanted_byte;
        integer phase_index;
        begin
            require(serializer_page == wanted_page,
                "serializer page changed at snapshot");
            require(serializer_marker == wanted_marker,
                "serializer marker mismatch");
            require(serializer_snapshot == wanted_snapshot,
                "serializer payload mismatch");
            for (phase_index = 0; phase_index < 4;
                 phase_index = phase_index + 1) begin
                wait_serializer_phase(phase_index[1:0]);
                case (phase_index)
                    0: serializer_joystick = 12'h321;
                    1: serializer_joystick = 12'h230;
                    2: serializer_joystick = 12'h103;
                    default: serializer_joystick = 12'h012;
                endcase
                #1;
                case (phase_index)
                    0: wanted_byte = wanted_snapshot[7:0];
                    1: wanted_byte = wanted_snapshot[15:8];
                    2: wanted_byte = wanted_snapshot[23:16];
                    default: wanted_byte = wanted_snapshot[31:24];
                endcase
                require(serializer_word[31:24] == wanted_marker,
                    "marker was not held for full rotation");
                require(serializer_word[23] == 1'b0 &&
                        serializer_word[20] == 1'b0,
                    "reserved framing bits changed");
                require(serializer_word[22:21] == phase_index[1:0],
                    "serialized phase mismatch");
                require(serializer_word[19:12] == wanted_byte,
                    "serialized byte mismatch");
                require(serializer_word[11:0] == serializer_joystick,
                    "physical joystick bits were not preserved");
                require(serializer_page == wanted_page &&
                        serializer_snapshot == wanted_snapshot,
                    "snapshot tore during a rotation");
                if (phase_index != 3) begin
                    tick();
                    wait_serializer_phase(
                        phase_index[1:0] + 2'd1);
                end
            end
        end
    endtask

    task automatic emit_serializer_rotation;
        integer phase_index;
        begin
            for (phase_index = 0; phase_index < 4;
                 phase_index = phase_index + 1) begin
                wait_serializer_phase(phase_index[1:0]);
                #1;
                $display(
                    "R211_AUDIO_DIAG_SAMPLE index=%0d word=0x%08X",
                    capture_index, serializer_word);
                capture_index = capture_index + 1;
                if (phase_index != 3) begin
                    tick();
                    wait_serializer_phase(
                        phase_index[1:0] + 2'd1);
                end
            end
        end
    endtask

    initial begin
        // The independent serializer remains in reset while observer behavior
        // is exercised, keeping its checks deterministic.
        serializer_reset = 1'b1;
        reset_observer();
        require(cause_word == 32'd0 && !cause_frozen,
            "observer reset did not clear causal evidence");
        joystick = 12'ha5a;
        #1;
        require(diagnostic_word[11:0] == joystick &&
                diagnostic_word[23] == 1'b0 &&
                diagnostic_word[20] == 1'b0 &&
                diagnostic_phase == 2'd0 &&
                diagnostic_page == 3'd0 &&
                diagnostic_marker == 8'hf6 &&
                diagnostic_snapshot == 32'd0 &&
                !diagnostic_snapshot_strobe,
            "wrapper serializer reset/framing did not preserve joystick");
        require(!witness_captured &&
                raw_witness_word == 32'd0 &&
                post_witness_word == 32'd0 &&
                final_witness_word == 32'd0,
            "observer reset did not clear stage witnesses");

        // Full-word writes and neighboring values are not the exact E3
        // high-byte writes that reach the channel register seam.
        seam_cycle(28'h480, 32'he300_0000, 4'b1111);
        seam_cycle(28'h480, 32'hd300_0000, 4'b1000);
        seam_cycle(28'h481, 32'he300_0000, 4'b1000);
        seam_cycle(28'h490, 32'he300_0000, 4'b0100);
        require(cause_word == 32'd0,
            "nearby register writes manufactured key-on evidence");

        // Cycles before either key-on, after only ch8, and on the same clock as
        // the second key-on are all excluded from the post-start witness.
        engine_beat(8'd5);
        require(cause_word[15:0] == 16'd0,
            "pre-key-on cycle was counted");

        engine_cycles_valid = 1'b1;
        engine_cycles = 8'd6;
        seam_cycle(28'h480, 32'he300_0000, 4'b1000);
        engine_cycles_valid = 1'b0;
        engine_cycles = 8'd0;
        require(cause_word[23:16] == 8'd1 &&
                cause_word[15:0] == 16'd0,
            "ch8 key-on or single-key-on exclusion failed");

        engine_cycles_valid = 1'b1;
        engine_cycles = 8'd9;
        seam_cycle(28'h490, 32'he300_0000, 4'b1000);
        engine_cycles_valid = 1'b0;
        engine_cycles = 8'd0;
        require(cause_word[31:16] == 16'h0101 &&
                cause_word[15:0] == 16'd0,
            "ch9 key-on edge was not excluded from later cycles");

        engine_beat(8'd7);
        require(cause_word == 32'h0101_0701,
            "first unambiguous post-key-on beat/sum was wrong");

        // The first known, nonzero raw sample after causal activity captures
        // raw, adapter, and final stages atomically.
        raw_audio_left = -16'sd2048;
        raw_audio_right = 16'sd2047;
        post_audio_left = -16'sd32768;
        post_audio_right = 16'sd32752;
        final_audio_left = -16'sd32768;
        final_audio_right = 16'sd32752;
        final_audio_takeover = 1'b1;
        tick();
        require(witness_captured,
            "known post-start raw sample did not capture");
        require(raw_witness_word == 32'hf800_07ff,
            "raw stereo witness was not captured atomically");
        require(post_witness_word == 32'h8000_7ff0,
            "post-adapter stereo witness was wrong");
        require(final_witness_word == 32'h8000_7ff0,
            "final stereo witness was wrong");
        require(activity_summary_word[7:0] == 8'd0,
            "takeover entry was counted as an audio transition");

        raw_audio_left = 16'sd1;
        raw_audio_right = -16'sd1;
        post_audio_left = 16'sd16;
        post_audio_right = -16'sd16;
        final_audio_left = 16'sd16;
        final_audio_right = -16'sd16;
        tick();
        require(raw_witness_word == 32'hf800_07ff &&
                post_witness_word == 32'h8000_7ff0 &&
                final_witness_word == 32'h8000_7ff0,
            "one-shot stage witness changed after capture");
        require(activity_summary_word[7:0] == 8'd1,
            "real final stereo change was not counted");
        require(activity_summary_word[29:28] == 2'b11,
            "per-lane final nonzero witnesses were not set");

        // Saturate, then prove that further pair changes cannot wrap.
        for (iteration = 0; iteration < 254;
             iteration = iteration + 1) begin
            if (iteration[0]) begin
                final_audio_left = 16'sd31;
                final_audio_right = -16'sd47;
            end else begin
                final_audio_left = -16'sd23;
                final_audio_right = 16'sd59;
            end
            tick();
        end
        require(activity_summary_word[7:0] == 8'hff &&
                activity_summary_word[30] == 1'b1,
            "final transition count did not saturate");
        final_audio_left = 16'sd99;
        final_audio_right = -16'sd101;
        tick();
        require(activity_summary_word[7:0] == 8'hff,
            "final transition count wrapped after saturation");

        // Loss of exact takeover clears stale continuous-interval activity.
        final_audio_takeover = 1'b0;
        tick();
        require(activity_summary_word[7:0] == 8'd0 &&
                activity_summary_word[30:28] == 3'b000,
            "fallback retained stale final-activity evidence");
        final_audio_takeover = 1'b1;
        tick();
        require(activity_summary_word[7:0] == 8'd0,
            "takeover re-entry was counted as a transition");
        final_audio_left = -16'sd111;
        tick();
        require(activity_summary_word[7:0] == 8'd1,
            "re-armed takeover did not count its first real change");

        // Request counting is edge-based; held request levels cannot overcount.
        request_pulse();
        engine_sample_request = 1'b1;
        tick();
        tick();
        require(activity_summary_word[15:8] == 8'd2,
            "request rising-edge count or held-level rejection failed");
        engine_sample_request = 1'b0;
        tick();

        sample_ddram_command_accepted = 1'b1;
        tick();
        sample_ddram_command_accepted = 1'b0;
        return_beat(64'd0);
        return_beat(64'h0000_0000_0000_0042);
        require(activity_summary_word[27:24] == 4'b1111,
            "sample request/accept/return/nonzero flags were incomplete");
        require(activity_summary_word[23:16] == 8'd2,
            "sample return beats were not counted");

        // Saturate both sample counters without wrapping.
        for (iteration = 0; iteration < 253;
             iteration = iteration + 1)
            request_pulse();
        sample_ddram_read_data = 64'h1;
        sample_ddram_read_data_ready = 1'b1;
        for (iteration = 0; iteration < 253;
             iteration = iteration + 1)
            tick();
        sample_ddram_read_data_ready = 1'b0;
        sample_ddram_read_data = 64'd0;
        require(activity_summary_word[23:8] == 16'hffff,
            "sample request/return counters did not saturate");
        require(activity_summary_word[31] == 1'b0,
            "activity summary reserved bit changed");
        request_pulse();
        return_beat(64'h2);
        require(activity_summary_word[23:8] == 16'hffff,
            "sample request/return counters wrapped");

        // Saturate both exact key-on counts before freezing the causal page.
        for (iteration = 0; iteration < 254;
             iteration = iteration + 1)
            seam_cycle(28'h480, 32'he300_0000, 4'b1000);
        for (iteration = 0; iteration < 254;
             iteration = iteration + 1)
            seam_cycle(28'h490, 32'he300_0000, 4'b1000);
        require(cause_word[31:16] == 16'hffff,
            "exact key-on counters did not saturate");

        for (iteration = 0; iteration < 254;
             iteration = iteration + 1)
            engine_beat(8'h80);
        require(cause_frozen && cause_word == 32'hffff_ffff,
            "post-key-on beat/sum page did not saturate and freeze");
        seam_cycle(28'h480, 32'he300_0000, 4'b1000);
        engine_beat(8'h01);
        require(cause_word == 32'hffff_ffff,
            "frozen causal page changed after later events");

`ifndef VERILATOR
        // Four-state-only checks.  Verilator's two-state engine compiles the
        // same fail-closed logic but cannot inject genuine X values.
        reset_observer();
        register_bus_ena = 1'bx;
        register_bus_address = 28'h480;
        register_bus_write_data = 32'he300_0000;
        register_bus_byte_enable = 4'b1000;
        #1;
        require(!ch8_keyon_pulse && !ch9_keyon_pulse,
            "unknown bus enable manufactured a key-on");
        tick();
        register_bus_ena = 1'b0;
        require(cause_word == 32'd0,
            "unknown register seam changed causal evidence");

        seam_cycle(28'h480, 32'he300_0000, 4'b1000);
        seam_cycle(28'h490, 32'he300_0000, 4'b1000);
        engine_cycles_valid = 1'b1;
        engine_cycles = 8'hxx;
        tick();
        engine_cycles_valid = 1'b0;
        require(cause_word[15:0] == 16'd0,
            "unknown engine credit manufactured a beat");
        engine_beat(8'd3);

        raw_audio_left = 16'shx;
        raw_audio_right = 16'sd1;
        post_audio_left = 16'sd0;
        post_audio_right = 16'sd16;
        final_audio_left = 16'sd0;
        final_audio_right = 16'sd16;
        final_audio_takeover = 1'b1;
        tick();
        require(!witness_captured,
            "unknown raw sample manufactured a stage witness");
        raw_audio_left = 16'sd1;
        final_audio_takeover = 1'bx;
        tick();
        require(!witness_captured &&
                activity_summary_word[7:0] == 8'd0,
            "unknown takeover claimed capture or activity");

        engine_sample_request = 1'bx;
        tick();
        require(activity_summary_word[15:8] == 8'd0 &&
                activity_summary_word[24] == 1'b0,
            "unknown sample request manufactured activity");
        engine_sample_request = 1'b1;
        tick();
        require(activity_summary_word[15:8] == 8'd0 &&
                activity_summary_word[24] == 1'b1,
            "X-to-one request was misreported as a known rising edge");
        engine_sample_request = 1'b0;

        sample_ddram_read_data = 64'hxxxx_xxxx_xxxx_xxxx;
        sample_ddram_read_data_ready = 1'b1;
        tick();
        sample_ddram_read_data_ready = 1'b0;
        require(activity_summary_word[26] == 1'b1 &&
                activity_summary_word[27] == 1'b0,
            "unknown DDR data manufactured a nonzero return");
`endif

        // A valid raw witness must still latch downstream zeros.  Those zeros
        // are diagnostic evidence of adapter/final loss, not "no capture."
        reset_observer();
        seam_cycle(28'h480, 32'he300_0000, 4'b1000);
        seam_cycle(28'h490, 32'he300_0000, 4'b1000);
        engine_beat(8'd4);
        raw_audio_left = 16'sd2;
        raw_audio_right = -16'sd2;
        post_audio_left = 16'sd0;
        post_audio_right = 16'sd0;
        final_audio_left = 16'sd0;
        final_audio_right = 16'sd0;
        final_audio_takeover = 1'b1;
        tick();
        require(witness_captured &&
                raw_witness_word == 32'h0002_fffe &&
                post_witness_word == 32'd0 &&
                final_witness_word == 32'd0,
            "raw-good/post-zero localization witness was not retained");

        // Exercise the serializer independently with programmable page words.
        serializer_page_0 = 32'h4433_2211;
        serializer_page_1 = 32'h8877_6655;
        serializer_page_2 = 32'hccbb_aa99;
        serializer_page_3 = 32'h0f0e_0d0c;
        serializer_page_4 = 32'h8070_6050;
        serializer_takeover = 1'b1;
        serializer_joystick = 12'ha55;
        serializer_reset = 1'b1;
        tick();
        tick();
        serializer_reset = 1'b0;

        for (iteration = 0; iteration < 4096;
             iteration = iteration + 1) begin
            serializer_joystick = iteration[11:0];
            #1;
            require(serializer_word[11:0] == iteration[11:0],
                "one of 4096 physical joystick patterns was changed");
        end

        wait_serializer_snapshot(3'd0);
        // Mutating the live page after capture must not mix later bytes.
        serializer_page_0 = 32'hdead_beef;
        check_serializer_rotation(3'd0, 8'hf7, 32'h4433_2211);

        wait_serializer_snapshot(3'd1);
        check_serializer_rotation(3'd1, 8'hf9, 32'h8877_6655);
        wait_serializer_snapshot(3'd2);
        check_serializer_rotation(3'd2, 8'hfb, 32'hccbb_aa99);
        wait_serializer_snapshot(3'd3);
        check_serializer_rotation(3'd3, 8'hfd, 32'h0f0e_0d0c);
        wait_serializer_snapshot(3'd4);
        check_serializer_rotation(3'd4, 8'hff, 32'h8070_6050);
        wait_serializer_snapshot(3'd0);
        require(serializer_marker == 8'hf7 &&
                serializer_snapshot == 32'hdead_beef,
            "updated live page was not captured on its next atomic rotation");

        // Marker ownership is snapshotted too; a mid-rotation change cannot
        // relabel the already-held payload.
        serializer_takeover = 1'b0;
        #1;
        require(serializer_marker == 8'hf7,
            "live takeover tore the held page marker");
        wait_serializer_snapshot(3'd1);
        require(serializer_marker == 8'hf8,
            "known fallback did not select the even page marker");

`ifndef VERILATOR
        serializer_takeover = 1'bx;
        wait_serializer_snapshot(3'd2);
        require(serializer_marker == 8'hfa,
            "unknown takeover did not fail closed to even marker");
`endif

        // Emit a real serializer capture that the shell regression feeds into
        // the independent host decoder.  Two complete sets of every odd page
        // bind the RTL framing/endianness to the decoder contract.
        serializer_page_0 = 32'h0101_ffff;
        serializer_page_1 = 32'hf800_07ff;
        serializer_page_2 = 32'h8000_7ff0;
        serializer_page_3 = 32'h8000_7ff0;
        serializer_page_4 = 32'h3000_0003;
        serializer_takeover = 1'b1;
        capture_index = 0;
        for (iteration = 0; iteration < 2;
             iteration = iteration + 1) begin
            wait_serializer_snapshot(3'd0);
            emit_serializer_rotation();
            wait_serializer_snapshot(3'd1);
            emit_serializer_rotation();
            wait_serializer_snapshot(3'd2);
            emit_serializer_rotation();
            wait_serializer_snapshot(3'd3);
            emit_serializer_rotation();
            wait_serializer_snapshot(3'd4);
            emit_serializer_rotation();
        end
        require(capture_index == 40,
            "serializer did not emit exactly two complete five-page sets");

        $display(
            "PASS: r211 observer proves key-ons/cycles/stages/activity/DDR and atomically serializes five joystick-safe pages");
        $finish;
    end
endmodule

`default_nettype wire
