`timescale 1ns/1ps
`default_nettype none

module tb_nds_sound_output_settle_guard;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic engine_cpu_request = 0;
    logic engine_cpu_write = 1;
    logic [31:0] engine_cpu_address = 0;
    logic [1:0] engine_cpu_access = 0;
    logic engine_cpu_done = 0;
    logic engine_cpu_rejected = 0;
    logic controls_settled;
    logic settle_protocol_error;

    logic signed [15:0] raw_audio_left = 16'sd100;
    logic signed [15:0] raw_audio_right = -16'sd100;
    logic master_enable = 1;
    logic [1:0] left_output_source = 0;
    logic [1:0] right_output_source = 0;
    logic exclude_channel_1_from_mixer = 0;
    logic exclude_channel_3_from_mixer = 0;
    logic [9:0] sound_bias = 10'h200;
    logic capture_0_active = 0;
    logic capture_1_active = 0;
    logic [15:0] soundcnt_value = 16'h807f;
    logic [15:0] soundcap_value = 16'h0000;

    logic signed [15:0] fpga_audio_left;
    logic signed [15:0] fpga_audio_right;
    logic fpga_audio_supported;
    logic fpga_audio_valid;
    logic fallback_required;

    nds_sound_output_settle_guard #(
        .SETTLE_CYCLES(4)
    ) guard (
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
        .raw_audio_left,
        .raw_audio_right,
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

    task automatic require_fallback(input integer case_id);
        begin
            #1;
            if (controls_settled && case_id < 0)
                $fatal(1, "internal test misuse case=%0d", case_id);
            if (fpga_audio_supported !== 1'b0 ||
                fpga_audio_valid !== 1'b0 ||
                fallback_required !== 1'b1 ||
                fpga_audio_left !== 16'sd0 ||
                fpga_audio_right !== 16'sd0)
                $fatal(1,
                    "settle fallback mismatch case=%0d settled=%b state=%0d count=%0d pending_relevant=%b output=%0d/%0d supported=%b valid=%b fallback=%b",
                    case_id, controls_settled, guard.state,
                    guard.settle_count, guard.pending_relevant,
                    $signed(fpga_audio_left), $signed(fpga_audio_right),
                    fpga_audio_supported, fpga_audio_valid,
                    fallback_required);
        end
    endtask

    task automatic require_normal_scaled(input integer case_id);
        begin
            #1;
            if (settle_protocol_error ||
                controls_settled !== 1'b1 ||
                fpga_audio_supported !== 1'b1 ||
                fpga_audio_valid !== 1'b1 ||
                fallback_required !== 1'b0 ||
                fpga_audio_left !== 16'sd1600 ||
                fpga_audio_right !== -16'sd1600)
                $fatal(1,
                    "settled output mismatch case=%0d error=%b settled=%b state=%0d count=%0d output=%0d/%0d supported=%b valid=%b fallback=%b",
                    case_id, settle_protocol_error, controls_settled,
                    guard.state, guard.settle_count,
                    $signed(fpga_audio_left), $signed(fpga_audio_right),
                    fpga_audio_supported, fpga_audio_valid,
                    fallback_required);
        end
    endtask

    task automatic launch_request(
        input logic [31:0] address,
        input logic [1:0] access
    );
        begin
            @(negedge clk);
            engine_cpu_address = address;
            engine_cpu_access = access;
            engine_cpu_write = 1;
            engine_cpu_request = 1;
        end
    endtask

    task automatic complete_request;
        begin
            @(negedge clk);
            engine_cpu_done = 1;
            @(posedge clk);
            #1;
            engine_cpu_done = 0;
            engine_cpu_request = 0;
        end
    endtask

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "sound output settle-guard timeout");
    end

    integer cycle_index;
    initial begin
        repeat (3) @(posedge clk);
        #1;
        require_fallback(1);
        if (settle_protocol_error)
            $fatal(1, "settle guard faulted during reset");

        @(negedge clk);
        reset = 0;
        #1;
        require_fallback(2);

        // The shadow exposes the normal 0x807f tuple on request launch, but
        // ownership remains blocked through an arbitrarily delayed VHDL
        // completion.
        launch_request(32'h04000500, 2'b01);
        #1;
        require_fallback(10);
        for (cycle_index = 0; cycle_index < 7;
             cycle_index = cycle_index + 1) begin
            @(posedge clk);
            require_fallback(11 + cycle_index);
        end
        complete_request();
        require_fallback(20);

        // Four full clocks after completion are required.  The first is also
        // the held-request release edge.
        for (cycle_index = 1; cycle_index <= 3;
             cycle_index = cycle_index + 1) begin
            @(posedge clk);
            require_fallback(20 + cycle_index);
        end
        @(posedge clk);
        require_normal_scaled(24);

        // Ordinary channel writes do not change output scaling and must not
        // cause needless one-cycle HPS fallbacks.
        launch_request(32'h04000400, 2'b10);
        #1;
        require_normal_scaled(30);
        repeat (3) begin
            @(posedge clk);
            require_normal_scaled(31);
        end
        complete_request();
        require_normal_scaled(32);
        @(posedge clk);
        require_normal_scaled(33);

        // Native NSMB next writes SOUNDCNT 0xb97f.  The exposed direct tuple is
        // unsupported before capture starts, independent of settle state.
        @(negedge clk);
        left_output_source = 2'b01;
        right_output_source = 2'b10;
        exclude_channel_1_from_mixer = 1;
        exclude_channel_3_from_mixer = 1;
        soundcnt_value = 16'hb97f;
        engine_cpu_address = 32'h04000500;
        engine_cpu_access = 2'b01;
        engine_cpu_request = 1;
        #1;
        require_fallback(40);
        repeat (2) begin
            @(posedge clk);
            require_fallback(41);
        end
        complete_request();
        require_fallback(42);

        // Start SOUNDCAP=0x8080 before the previous settle window expires,
        // matching the real ordered stream.  The abstract proxy predicate is
        // now true, but direct-scale raw samples must remain completely muted
        // from launch through delayed completion and pipeline settling.
        @(posedge clk);
        require_fallback(43);
        @(negedge clk);
        capture_0_active = 1;
        capture_1_active = 1;
        soundcap_value = 16'h8080;
        raw_audio_left = 16'sh3000;
        raw_audio_right = -16'sh3000;
        engine_cpu_address = 32'h04000508;
        engine_cpu_access = 2'b01;
        engine_cpu_request = 1;
        #1;
        require_fallback(44);
        for (cycle_index = 0; cycle_index < 9;
             cycle_index = cycle_index + 1) begin
            @(posedge clk);
            require_fallback(45 + cycle_index);
        end
        complete_request();
        require_fallback(55);

        @(posedge clk);
        require_fallback(56);
        @(posedge clk);
        require_fallback(57);
        @(negedge clk);
        // Robert's registered capture hack has reached sound_out_* by the
        // third post-completion clock.  The guard still waits a fourth.
        raw_audio_left = 16'sd100;
        raw_audio_right = -16'sd100;
        @(posedge clk);
        require_fallback(58);
        @(posedge clk);
        require_normal_scaled(59);

        // A high-half no-op in the SOUNDCAP word is not a control change and
        // must preserve already-settled proxy ownership.
        launch_request(32'h0400050a, 2'b01);
        #1;
        require_normal_scaled(60);
        @(posedge clk);
        require_normal_scaled(61);
        complete_request();
        require_normal_scaled(62);
        @(posedge clk);
        require_normal_scaled(63);

        if (settle_protocol_error)
            $fatal(1, "settle guard reported a protocol error");

        // A relevant rejected write and a withdrawn held request independently
        // poison the guard and can never expose stale qualification.
        @(negedge clk);
        reset = 1;
        engine_cpu_request = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        engine_cpu_address = 32'h04000500;
        engine_cpu_access = 2'b01;
        engine_cpu_request = 1;
        @(posedge clk);
        @(negedge clk);
        engine_cpu_rejected = 1;
        @(posedge clk);
        #1;
        if (!settle_protocol_error)
            $fatal(1, "rejected relevant write did not poison guard");
        require_fallback(70);

        @(negedge clk);
        reset = 1;
        engine_cpu_request = 0;
        engine_cpu_rejected = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        engine_cpu_address = 32'h04000508;
        engine_cpu_access = 2'b01;
        engine_cpu_request = 1;
        @(posedge clk);
        @(negedge clk);
        engine_cpu_request = 0;
        @(posedge clk);
        #1;
        if (!settle_protocol_error)
            $fatal(1, "withdrawn relevant request did not poison guard");
        require_fallback(71);

`ifndef VERILATOR
        @(negedge clk);
        reset = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        engine_cpu_request = 1'bx;
        @(posedge clk);
        #1;
        if (!settle_protocol_error)
            $fatal(1, "unknown request did not poison guard");
        require_fallback(72);
`endif

        $display(
            "PASS: delayed output-control completion blocks ownership from request launch through four post-completion clocks");
        $display(
            "PASS: exact 0x807f -> 0xb97f + 0x8080 sequence never exposes transient direct-scale raw audio through mixer x16");
        $display(
            "PASS: settled normal/proxy ownership survives unrelated channel and upper-lane no-op writes");
        $display(
            "PASS: rejected, withdrawn, and unknown control requests poison the settle guard fail-closed");
        $finish;
    end
endmodule

`default_nettype wire
