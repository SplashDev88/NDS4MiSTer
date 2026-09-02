module nds_ddram_arbiter_throughput_harness #(
    parameter integer FOUR_CLIENT = 1,
    parameter integer STICKY_GRANT_LIMIT = 8
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        active,
    input  logic [2:0]  scenario,
    output logic        done,
    output logic [31:0] elapsed_cycles,
    output logic [31:0] cpu_accepts,
    output logic [31:0] video_accepts,
    output logic [31:0] sound_accepts,
    output logic [31:0] credit_accepts
);
    localparam integer CPU_TARGET = 256;
    localparam integer VIDEO_TARGET = 16;
    localparam integer SOUND_TARGET = 8;
    localparam integer CREDIT_TARGET = 4;

    wire sparse_video = scenario >= 3'd2;
    wire sparse_all = scenario >= 3'd4;
    wire delayed_response = scenario[0];

    logic cpu_rd = 0, cpu_we = 0;
    logic video_rd = 0, video_we = 0;
    logic sound_rd = 0, sound_we = 0;
    logic credit_rd = 0, credit_we = 0;
    logic cpu_busy, video_busy, sound_busy, credit_busy;
    logic [63:0] cpu_dout, video_dout, sound_dout, credit_dout;
    logic cpu_dout_ready, video_dout_ready;
    logic sound_dout_ready, credit_dout_ready;
    logic cpu_command_accepted, video_command_accepted;
    logic sound_command_accepted, credit_command_accepted;

    logic ddram_rd, ddram_we;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic [7:0] ddram_be;
    logic ddram_busy;
    logic [63:0] ddram_dout = 64'h0123456789abcdef;
    logic ddram_dout_ready;
    logic delayed_ready = 0;
    logic [2:0] response_delay = 0;
    logic protocol_error;

    logic cpu_pending, video_pending, sound_pending, credit_pending;
    logic cpu_outstanding, video_outstanding;
    logic sound_outstanding, credit_outstanding;
    logic [31:0] cycle_count;

    wire [31:0] next_cpu_accepts =
        cpu_accepts + (cpu_command_accepted ? 1 : 0);
    wire [31:0] next_video_accepts =
        video_accepts + (video_command_accepted ? 1 : 0);
    wire [31:0] next_sound_accepts =
        sound_accepts + (sound_command_accepted ? 1 : 0);
    wire [31:0] next_credit_accepts =
        credit_accepts + (credit_command_accepted ? 1 : 0);

    generate
        if (FOUR_CLIENT != 0) begin : g_four
            nds_ddram_arbiter_4client #(
                .RESET_QUIET_CYCLES(4),
                .STICKY_GRANT_LIMIT(STICKY_GRANT_LIMIT)
            ) dut (
                .clk, .reset,
                .cpu_rd, .cpu_we,
                .cpu_burstcnt(8'd1),
                .cpu_addr(29'h01000000),
                .cpu_din(64'd0),
                .cpu_be(8'hff),
                .cpu_busy, .cpu_dout, .cpu_dout_ready,
                .cpu_command_accepted,
                .video_rd, .video_we,
                .video_burstcnt(8'd1),
                .video_addr(29'h02000000),
                .video_din(64'd0),
                .video_be(8'hff),
                .video_busy, .video_dout, .video_dout_ready,
                .video_command_accepted,
                .sound_rd, .sound_we,
                .sound_burstcnt(8'd1),
                .sound_addr(29'h03000000),
                .sound_din(64'd0),
                .sound_be(8'hff),
                .sound_busy, .sound_dout, .sound_dout_ready,
                .sound_command_accepted,
                .credit_rd, .credit_we,
                .credit_burstcnt(8'd1),
                .credit_addr(29'h04000000),
                .credit_din(64'd0),
                .credit_be(8'hff),
                .credit_busy, .credit_dout, .credit_dout_ready,
                .credit_command_accepted,
                .ddram_rd, .ddram_we, .ddram_burstcnt, .ddram_addr,
                .ddram_din, .ddram_be, .ddram_busy, .ddram_dout,
                .ddram_dout_ready, .protocol_error
            );
        end else begin : g_two
            logic [17:0] unused_debug_state;
            nds_ddram_arbiter dut (
                .clk, .reset,
                .a_rd(cpu_rd), .a_we(cpu_we),
                .a_burstcnt(8'd1),
                .a_addr(29'h01000000),
                .a_din(64'd0),
                .a_be(8'hff),
                .a_busy(cpu_busy), .a_dout(cpu_dout),
                .a_dout_ready(cpu_dout_ready),
                .a_command_accepted(cpu_command_accepted),
                .b_rd(video_rd), .b_we(video_we),
                .b_burstcnt(8'd1),
                .b_addr(29'h02000000),
                .b_din(64'd0),
                .b_be(8'hff),
                .b_busy(video_busy), .b_dout(video_dout),
                .b_dout_ready(video_dout_ready),
                .b_command_accepted(video_command_accepted),
                .debug_state(unused_debug_state),
                .ddram_rd, .ddram_we, .ddram_burstcnt, .ddram_addr,
                .ddram_din, .ddram_be, .ddram_busy, .ddram_dout,
                .ddram_dout_ready
            );
            always_comb begin
                sound_busy = 1'b1;
                credit_busy = 1'b1;
                sound_dout = 64'd0;
                credit_dout = 64'd0;
                sound_dout_ready = 1'b0;
                credit_dout_ready = 1'b0;
                sound_command_accepted = 1'b0;
                credit_command_accepted = 1'b0;
                protocol_error = 1'b0;
            end
        end
    endgenerate

    // Model MiSTer's legal idle-high waitrequest convention.  During the
    // reset/quarantine preamble the port is explicitly quiet (busy low).
    // Once measurement begins it lowers waitrequest only after RD/WE appears.
    always_comb begin
        if (!active)
            ddram_busy = 1'b0;
        else
            ddram_busy = !(ddram_rd || ddram_we);
        ddram_dout_ready =
            delayed_response ? delayed_ready :
            (active && ddram_rd && !ddram_busy);
    end

    // Delayed mode returns a one-beat read two clocks after acceptance.
    always_ff @(posedge clk) begin
        if (reset || !active || !delayed_response) begin
            response_delay <= 3'd0;
            delayed_ready <= 1'b0;
        end else begin
            delayed_ready <= 1'b0;
            if (ddram_rd && !ddram_busy) begin
                if (response_delay != 0)
                    $fatal(1, "benchmark DDR accepted overlapping reads");
                response_delay <= 3'd2;
            end else if (response_delay != 0) begin
                response_delay <= response_delay - 1'b1;
                if (response_delay == 1)
                    delayed_ready <= 1'b1;
            end
        end
    end

    // All requesters use the strict registered contract: a one-cycle RD pulse
    // is raised only on the clock after that client observes busy low.
    always_ff @(posedge clk) begin
        if (reset) begin
            cpu_rd <= 1'b0;
            video_rd <= 1'b0;
            sound_rd <= 1'b0;
            credit_rd <= 1'b0;
            cpu_pending <= 1'b1;
            video_pending <= 1'b0;
            sound_pending <= 1'b0;
            credit_pending <= 1'b0;
            cpu_outstanding <= 1'b0;
            video_outstanding <= 1'b0;
            sound_outstanding <= 1'b0;
            credit_outstanding <= 1'b0;
            cpu_accepts <= 32'd0;
            video_accepts <= 32'd0;
            sound_accepts <= 32'd0;
            credit_accepts <= 32'd0;
            cycle_count <= 32'd0;
            elapsed_cycles <= 32'd0;
            done <= 1'b0;
        end else begin
            cpu_rd <= 1'b0;
            video_rd <= 1'b0;
            sound_rd <= 1'b0;
            credit_rd <= 1'b0;

            if (active && !done)
                cycle_count <= cycle_count + 1'b1;

            if (active && !done &&
                cpu_pending && !cpu_outstanding && !cpu_busy) begin
                cpu_rd <= 1'b1;
                cpu_pending <= 1'b0;
                cpu_outstanding <= 1'b1;
            end
            if (active && !done &&
                video_pending && !video_outstanding && !video_busy) begin
                video_rd <= 1'b1;
                video_pending <= 1'b0;
                video_outstanding <= 1'b1;
            end
            if (active && !done && FOUR_CLIENT != 0 &&
                sound_pending && !sound_outstanding && !sound_busy) begin
                sound_rd <= 1'b1;
                sound_pending <= 1'b0;
                sound_outstanding <= 1'b1;
            end
            if (active && !done && FOUR_CLIENT != 0 &&
                credit_pending && !credit_outstanding && !credit_busy) begin
                credit_rd <= 1'b1;
                credit_pending <= 1'b0;
                credit_outstanding <= 1'b1;
            end

            if (cpu_command_accepted) begin
                cpu_accepts <= next_cpu_accepts;
                cpu_outstanding <= 1'b0;
                if (next_cpu_accepts < CPU_TARGET)
                    cpu_pending <= 1'b1;

                if (sparse_video &&
                    next_cpu_accepts[3:0] == 4'd0 &&
                    next_video_accepts < VIDEO_TARGET &&
                    !video_pending && !video_outstanding)
                    video_pending <= 1'b1;
                if (sparse_all && FOUR_CLIENT != 0 &&
                    next_cpu_accepts[4:0] == 5'd0 &&
                    next_sound_accepts < SOUND_TARGET &&
                    !sound_pending && !sound_outstanding)
                    sound_pending <= 1'b1;
                if (sparse_all && FOUR_CLIENT != 0 &&
                    next_cpu_accepts[5:0] == 6'd0 &&
                    next_credit_accepts < CREDIT_TARGET &&
                    !credit_pending && !credit_outstanding)
                    credit_pending <= 1'b1;
            end
            if (video_command_accepted) begin
                video_accepts <= next_video_accepts;
                video_outstanding <= 1'b0;
            end
            if (sound_command_accepted) begin
                sound_accepts <= next_sound_accepts;
                sound_outstanding <= 1'b0;
            end
            if (credit_command_accepted) begin
                credit_accepts <= next_credit_accepts;
                credit_outstanding <= 1'b0;
            end

            if (active && !done &&
                next_cpu_accepts >= CPU_TARGET &&
                (!sparse_video ||
                 next_video_accepts >= VIDEO_TARGET) &&
                (!sparse_all || FOUR_CLIENT == 0 ||
                 (next_sound_accepts >= SOUND_TARGET &&
                  next_credit_accepts >= CREDIT_TARGET))) begin
                done <= 1'b1;
                elapsed_cycles <= cycle_count + 1'b1;
            end

            if (active && protocol_error)
                $fatal(1, "benchmark observed ownerless DDR response");
        end
    end
endmodule

module tb_nds_ddram_arbiter_4client_throughput;
    logic clk = 0;
    logic reset = 1;
    logic active = 0;
    logic [2:0] scenario = 0;
    always #5 clk = ~clk;

    logic done_two, done_legacy, done_sticky;
    logic [31:0] cycles_two, cycles_legacy, cycles_sticky;
    logic [31:0] cpu_two, video_two, sound_two, credit_two;
    logic [31:0] cpu_legacy, video_legacy, sound_legacy, credit_legacy;
    logic [31:0] cpu_sticky, video_sticky, sound_sticky, credit_sticky;

    nds_ddram_arbiter_throughput_harness #(
        .FOUR_CLIENT(0)
    ) two_client (
        .clk, .reset, .active, .scenario, .done(done_two),
        .elapsed_cycles(cycles_two),
        .cpu_accepts(cpu_two), .video_accepts(video_two),
        .sound_accepts(sound_two), .credit_accepts(credit_two)
    );

    nds_ddram_arbiter_throughput_harness #(
        .FOUR_CLIENT(1),
        .STICKY_GRANT_LIMIT(0)
    ) four_client_legacy (
        .clk, .reset, .active, .scenario, .done(done_legacy),
        .elapsed_cycles(cycles_legacy),
        .cpu_accepts(cpu_legacy), .video_accepts(video_legacy),
        .sound_accepts(sound_legacy), .credit_accepts(credit_legacy)
    );

    nds_ddram_arbiter_throughput_harness #(
        .FOUR_CLIENT(1),
        .STICKY_GRANT_LIMIT(8)
    ) four_client_sticky (
        .clk, .reset, .active, .scenario, .done(done_sticky),
        .elapsed_cycles(cycles_sticky),
        .cpu_accepts(cpu_sticky), .video_accepts(video_sticky),
        .sound_accepts(sound_sticky), .credit_accepts(credit_sticky)
    );

    task automatic run_scenario(
        input logic [2:0] selected_scenario,
        input [127:0] label
    );
        integer watchdog;
        begin
            @(negedge clk);
            active = 1'b0;
            reset = 1'b1;
            scenario = selected_scenario;
            repeat (4) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
            // Four-client reset quarantine requires four quiet DDR clocks.
            repeat (8) @(posedge clk);
            @(negedge clk);
            active = 1'b1;

            watchdog = 0;
            while (!(done_two && done_legacy && done_sticky)) begin
                @(posedge clk);
                watchdog = watchdog + 1;
                if (watchdog > 20000)
                    $fatal(1,
                        "throughput timeout %s done=%0d%0d%0d counts cpu=%0d/%0d/%0d video=%0d/%0d/%0d sound=%0d/%0d credit=%0d/%0d",
                        label, done_two, done_legacy, done_sticky,
                        cpu_two, cpu_legacy, cpu_sticky,
                        video_two, video_legacy, video_sticky,
                        sound_legacy, sound_sticky,
                        credit_legacy, credit_sticky);
            end
            @(negedge clk);
            active = 1'b0;

            $display(
                "RESULT %-16s two=%0d legacy4=%0d sticky4=%0d cpu=%0d/%0d/%0d video=%0d/%0d/%0d sound=%0d/%0d credit=%0d/%0d",
                label, cycles_two, cycles_legacy, cycles_sticky,
                cpu_two, cpu_legacy, cpu_sticky,
                video_two, video_legacy, video_sticky,
                sound_legacy, sound_sticky,
                credit_legacy, credit_sticky);

            if (cycles_sticky >= cycles_legacy)
                $fatal(1,
                    "%s sticky policy did not improve legacy four-client throughput: %0d >= %0d",
                    label, cycles_sticky, cycles_legacy);
            if (selected_scenario < 2 &&
                cycles_sticky > cycles_two)
                $fatal(1,
                    "%s sticky four-client single-CPU path is slower than original two-client: %0d > %0d",
                    label, cycles_sticky, cycles_two);
            if (cpu_legacy != 256 || cpu_sticky != 256 ||
                cpu_two != 256)
                $fatal(1, "%s CPU target mismatch", label);
            if (selected_scenario >= 2 &&
                (video_two != 16 || video_legacy != 16 ||
                 video_sticky != 16))
                $fatal(1, "%s sparse video request was starved", label);
            if (selected_scenario >= 4 &&
                (sound_legacy != 8 || sound_sticky != 8 ||
                 credit_legacy != 4 || credit_sticky != 4))
                $fatal(1, "%s sparse sound/credit request was starved",
                       label);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        run_scenario(3'd0, "cpu_same_edge");
        run_scenario(3'd1, "cpu_delayed");
        run_scenario(3'd2, "video_same_edge");
        run_scenario(3'd3, "video_delayed");
        run_scenario(3'd4, "all_same_edge");
        run_scenario(3'd5, "all_delayed");
        $display("PASS: four-client productive-owner affinity improves idle-high DDR throughput while sparse clients retain bounded service");
        $finish;
    end
endmodule
