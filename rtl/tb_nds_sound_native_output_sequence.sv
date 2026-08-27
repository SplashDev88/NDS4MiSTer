`timescale 1ns/1ps
`default_nettype none

// Directed integration regression for the exact NSMB output-control sequence
// observed in the native ARM7 trace.  This joins the released-write driver,
// passive control shadow, completion-relative settle guard, and output
// adapter.  The behavioral engine deliberately delays completion and requires
// the driver to hold each request and payload stable until done.
module tb_nds_sound_native_output_sequence;
    localparam integer SETTLE_CYCLES = 4;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic        released_write_valid = 1'b0;
    logic        released_write_ready;
    logic [31:0] released_write_address = 32'd0;
    logic [1:0]  released_write_access = 2'd0;
    logic [31:0] released_write_data = 32'd0;

    logic        engine_cpu_request;
    logic        engine_cpu_is_arm9;
    logic        engine_cpu_write;
    logic [31:0] engine_cpu_address;
    logic [1:0]  engine_cpu_access;
    logic [31:0] engine_cpu_write_data;
    logic        engine_cpu_done = 1'b0;
    logic        engine_cpu_rejected = 1'b0;
    logic        driver_busy;
    logic        driver_protocol_error;

    logic        control_released_write_ready;
    logic        master_enable;
    logic [1:0]  left_output_source;
    logic [1:0]  right_output_source;
    logic        exclude_channel_1_from_mixer;
    logic        exclude_channel_3_from_mixer;
    logic [9:0]  sound_bias;
    logic        capture_0_active;
    logic        capture_1_active;
    logic [15:0] soundcnt_value;
    logic [15:0] soundcap_value;
    logic        controls_valid;
    logic        control_failclosed;
    logic        control_protocol_error;

    logic        controls_settled;
    logic        settle_protocol_error;
    logic signed [15:0] fpga_audio_left;
    logic signed [15:0] fpga_audio_right;
    logic        fpga_audio_supported;
    logic        fpga_audio_valid;
    logic        fallback_required;

    logic [7:0] response_delay = 8'd0;
    logic [7:0] response_count = 8'd0;
    logic [31:0] held_address = 32'd0;
    logic [1:0] held_access = 2'd0;
    logic [31:0] held_data = 32'd0;
    integer released_count = 0;
    integer accepted_count = 0;
    integer completed_count = 0;
    integer cycle_index;
    integer timeout;

    typedef enum logic [1:0] {
        ENGINE_IDLE,
        ENGINE_PENDING,
        ENGINE_WAIT_LOW
    } engine_state_t;
    engine_state_t engine_state = ENGINE_IDLE;

    wire released_write_fire =
        released_write_valid && released_write_ready;

    nds_sound_released_write_driver driver (
        .clk,
        .reset,
        .released_write_valid,
        .released_write_ready,
        .released_write_address,
        .released_write_access,
        .released_write_data,
        .source_protocol_error(1'b0),
        .shadow_cpu_request(engine_cpu_request),
        .shadow_cpu_is_arm9(engine_cpu_is_arm9),
        .shadow_cpu_write(engine_cpu_write),
        .shadow_cpu_address(engine_cpu_address),
        .shadow_cpu_access(engine_cpu_access),
        .shadow_cpu_write_data(engine_cpu_write_data),
        .shadow_cpu_done(engine_cpu_done),
        .shadow_cpu_rejected(engine_cpu_rejected),
        .busy(driver_busy),
        .protocol_error(driver_protocol_error)
    );

    nds_sound_output_control_shadow output_control (
        .clk,
        .reset,
        .released_write_valid(released_write_fire),
        .released_write_ready(control_released_write_ready),
        .released_write_cpu_arm9(1'b0),
        .released_write_read_not_write(1'b0),
        .released_write_access,
        .released_write_address,
        .released_write_data,
        .source_capture_overflow(1'b0),
        .source_sequence_exhausted(1'b0),
        .source_protocol_error(1'b0),
        .master_enable,
        .left_output_source,
        .right_output_source,
        .exclude_channel_1_from_mixer,
        .exclude_channel_3_from_mixer,
        .sound_bias,
        .capture_0_active,
        .capture_1_active,
        .soundcnt_value,
        .soundcap_value,
        .controls_valid,
        .failclosed(control_failclosed),
        .protocol_error(control_protocol_error)
    );

    nds_sound_output_settle_guard #(
        .SETTLE_CYCLES(SETTLE_CYCLES)
    ) settle_guard (
        .clk,
        .reset,
        .engine_cpu_request,
        .engine_cpu_write,
        .engine_cpu_address,
        .engine_cpu_access,
        .engine_cpu_done,
        .engine_cpu_rejected,
        .controls_settled,
        .protocol_error(settle_protocol_error)
    );

    nds_sound_output_adapter adapter (
        .raw_audio_left(16'sd100),
        .raw_audio_right(-16'sd100),
        .master_enable,
        .left_output_source,
        .right_output_source,
        .exclude_channel_1_from_mixer,
        .exclude_channel_3_from_mixer,
        .sound_bias,
        .capture_0_active,
        .capture_1_active,
        .soundcnt_value,
        .soundcap_value,
        .controls_settled,
        .fpga_audio_left,
        .fpga_audio_right,
        .fpga_audio_supported,
        .fpga_audio_valid,
        .fallback_required
    );

    // Registered stand-in for the VHDL wrapper completion protocol.  A
    // request is sampled on one edge, completed only after a configurable
    // delay, and done remains visible for exactly the edge on which the
    // released-write driver consumes it.
    always_ff @(posedge clk) begin
        if (reset) begin
            engine_state <= ENGINE_IDLE;
            engine_cpu_done <= 1'b0;
            response_count <= 8'd0;
            held_address <= 32'd0;
            held_access <= 2'd0;
            held_data <= 32'd0;
            accepted_count <= 0;
            completed_count <= 0;
        end else begin
            engine_cpu_done <= 1'b0;
            case (engine_state)
                ENGINE_IDLE: begin
                    if (engine_cpu_request) begin
                        if (engine_cpu_is_arm9 || !engine_cpu_write)
                            $fatal(1,
                                "native sound write lost ARM7/write qualifiers");
                        held_address <= engine_cpu_address;
                        held_access <= engine_cpu_access;
                        held_data <= engine_cpu_write_data;
                        response_count <= response_delay;
                        accepted_count <= accepted_count + 1;
                        engine_state <= ENGINE_PENDING;
                    end
                end

                ENGINE_PENDING: begin
                    if (!engine_cpu_request)
                        $fatal(1,
                            "released-write request dropped before completion");
                    if (engine_cpu_address !== held_address ||
                        engine_cpu_access !== held_access ||
                        engine_cpu_write_data !== held_data)
                        $fatal(1,
                            "released-write payload changed while held");
                    if (response_count != 0) begin
                        response_count <= response_count - 1'b1;
                    end else begin
                        engine_cpu_done <= 1'b1;
                        completed_count <= completed_count + 1;
                        engine_state <= ENGINE_WAIT_LOW;
                    end
                end

                ENGINE_WAIT_LOW: begin
                    if (!engine_cpu_request)
                        engine_state <= ENGINE_IDLE;
                end

                default: $fatal(1, "invalid behavioral engine state");
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            released_count <= 0;
        end else if (released_write_fire) begin
            released_count <= released_count + 1;
        end
    end

    task automatic check_shadow(
        input logic [15:0] expected_soundcnt,
        input logic [15:0] expected_soundcap,
        input integer case_id
    );
        begin
            #1;
            if (!control_released_write_ready ||
                !controls_valid ||
                control_failclosed ||
                control_protocol_error ||
                driver_protocol_error ||
                settle_protocol_error ||
                soundcnt_value !== expected_soundcnt ||
                soundcap_value !== expected_soundcap ||
                sound_bias !== 10'h200)
                $fatal(1,
                    "native sequence mismatch case=%0d cnt=%h/%h cap=%h/%h bias=%h ready=%b valid=%b faults=%b/%b/%b",
                    case_id, soundcnt_value, expected_soundcnt,
                    soundcap_value, expected_soundcap, sound_bias,
                    control_released_write_ready, controls_valid,
                    control_protocol_error, driver_protocol_error,
                    settle_protocol_error);
        end
    endtask

    task automatic send_native_write(
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data,
        input logic [7:0] delay_cycles,
        input logic [15:0] expected_soundcnt,
        input logic [15:0] expected_soundcap,
        input integer case_id
    );
        begin
            timeout = 0;
            while (!released_write_ready && timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!released_write_ready)
                $fatal(1,
                    "native write source never became ready case=%0d",
                    case_id);

            @(negedge clk);
            response_delay = delay_cycles;
            released_write_address = address;
            released_write_access = access;
            released_write_data = data;
            released_write_valid = 1'b1;
            @(posedge clk);
            check_shadow(expected_soundcnt, expected_soundcap, case_id);
            if (!engine_cpu_request || !driver_busy)
                $fatal(1,
                    "native write did not launch held request case=%0d",
                    case_id);

            // The source is free to mutate immediately after the ready/valid
            // fire; the driver must preserve the accepted native payload.
            @(negedge clk);
            released_write_valid = 1'b0;
            released_write_address = 32'hdeadbeef;
            released_write_access = 2'b11;
            released_write_data = 32'hcafef00d;

            timeout = 0;
            while (!released_write_ready && timeout < 200) begin
                @(posedge clk);
                check_shadow(
                    expected_soundcnt, expected_soundcap, case_id);
                timeout = timeout + 1;
            end
            if (!released_write_ready)
                $fatal(1,
                    "native held request did not complete case=%0d",
                    case_id);
            check_shadow(expected_soundcnt, expected_soundcap, case_id);
        end
    endtask

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "native sound output sequence timeout");
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(posedge clk);
        check_shadow(16'h0000, 16'h0000, 0);

        // Exact relevant prefix from the native NSMB ARM7 trace: duplicated
        // master-enable byte, low volume byte, capture clears, then byte B9
        // at 04000501 and halfword 8080 at 04000508.
        send_native_write(
            32'h04000501, 2'b00, 32'h00000080, 8'd1,
            16'h8000, 16'h0000, 1);
        send_native_write(
            32'h04000501, 2'b00, 32'h00000080, 8'd4,
            16'h8000, 16'h0000, 2);
        send_native_write(
            32'h04000500, 2'b00, 32'h0000007f, 8'd2,
            16'h807f, 16'h0000, 3);

        timeout = 0;
        while (!controls_settled && timeout < 20) begin
            @(posedge clk);
            check_shadow(16'h807f, 16'h0000, 4);
            timeout = timeout + 1;
        end
        if (!controls_settled || !fpga_audio_supported)
            $fatal(1,
                "settled native 807f prefix did not select FPGA audio");

        send_native_write(
            32'h04000508, 2'b00, 32'h00000000, 8'd5,
            16'h807f, 16'h0000, 5);
        send_native_write(
            32'h04000509, 2'b00, 32'h00000000, 8'd3,
            16'h807f, 16'h0000, 6);
        send_native_write(
            32'h04000501, 2'b00, 32'h000000b9, 8'd7,
            16'hb97f, 16'h0000, 7);
        if (fpga_audio_supported || fpga_audio_valid ||
            !fallback_required)
            $fatal(1,
                "byte B9 without capture incorrectly selected FPGA audio");

        send_native_write(
            32'h04000508, 2'b01, 32'h00008080, 8'd6,
            16'hb97f, 16'h8080, 8);

        // The tuple must remain exact while the real held request completes
        // and until the conservative output pipeline settle period expires.
        timeout = 0;
        while (!controls_settled && timeout < 20) begin
            @(posedge clk);
            check_shadow(16'hb97f, 16'h8080, 9);
            timeout = timeout + 1;
        end
        if (!controls_settled ||
            !fpga_audio_supported ||
            !fpga_audio_valid ||
            fallback_required ||
            fpga_audio_left !== 16'sd1600 ||
            fpga_audio_right !== -16'sd1600)
            $fatal(1,
                "settled native B97F/8080 tuple did not select FPGA audio");

        repeat (32) begin
            @(posedge clk);
            check_shadow(16'hb97f, 16'h8080, 10);
            if (!controls_settled || !fpga_audio_supported ||
                !fpga_audio_valid || fallback_required)
                $fatal(1,
                    "native B97F/8080 tuple did not persist");
        end

        if (released_count != 7 ||
            accepted_count != 7 ||
            completed_count != 7)
            $fatal(1,
                "native write accounting mismatch released=%0d accepted=%0d completed=%0d",
                released_count, accepted_count, completed_count);

        $display(
            "PASS: native byte B9 @04000501 plus halfword 8080 @04000508 persists as exact B97F/8080");
        $display(
            "PASS: seven native writes remain exactly once and stable through delayed held-request completions");
        $display(
            "PASS: settle guard requalifies the persistent tuple without a protocol fault and the adapter selects FPGA audio");
        $finish;
    end
endmodule

`default_nettype wire
