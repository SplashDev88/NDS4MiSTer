`timescale 1ns/1ps
`default_nettype none

module tb_nds_ddram_arbiter_4client_mask;
    logic clk = 1'b0;
    logic reset = 1'b1;

    logic cpu_we = 1'b0;
    logic video_we = 1'b0;
    logic sound_we = 1'b0;
    logic credit_we = 1'b1;
    logic cpu_busy, video_busy, sound_busy, credit_busy;
    logic cpu_accepted, video_accepted, sound_accepted, credit_accepted;
    logic ddram_rd, ddram_we;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic [7:0] ddram_be;
    logic ddram_busy = 1'b0;
    logic [63:0] ddram_dout = 64'hfeedface_deadbeef;
    logic ddram_dout_ready = 1'b0;
    logic epoch_quiescent;
    logic [31:0] debug_state;
    logic protocol_error;

    logic [28:0] accepted_address [0:2];
    integer accepted_count = 0;
    integer credit_grant_cycles = 0;

    always #5 clk = ~clk;

    nds_ddram_arbiter_4client #(
        .RESET_QUIET_CYCLES(3),
        .STICKY_GRANT_LIMIT(0),
        .CLIENT_ENABLE_MASK(4'b0111)
    ) dut (
        .clk,
        .reset,
        .cpu_rd(1'b0),
        .cpu_we,
        .cpu_burstcnt(8'd1),
        .cpu_addr(29'h0000010),
        .cpu_din(64'h11111111_11111111),
        .cpu_be(8'hff),
        .cpu_busy,
        .cpu_dout(),
        .cpu_dout_ready(),
        .cpu_command_accepted(cpu_accepted),
        .video_rd(1'b0),
        .video_we,
        .video_burstcnt(8'd1),
        .video_addr(29'h0000020),
        .video_din(64'h22222222_22222222),
        .video_be(8'hff),
        .video_busy,
        .video_dout(),
        .video_dout_ready(),
        .video_command_accepted(video_accepted),
        .sound_rd(1'b0),
        .sound_we,
        .sound_burstcnt(8'd1),
        .sound_addr(29'h0000030),
        .sound_din(64'h33333333_33333333),
        .sound_be(8'hff),
        .sound_busy,
        .sound_dout(),
        .sound_dout_ready(),
        .sound_command_accepted(sound_accepted),
        .credit_rd(1'b0),
        .credit_we,
        .credit_burstcnt(8'd1),
        .credit_addr(29'h0000040),
        .credit_din(64'h44444444_44444444),
        .credit_be(8'hff),
        .credit_busy,
        .credit_dout(),
        .credit_dout_ready(),
        .credit_command_accepted(credit_accepted),
        .ddram_rd,
        .ddram_we,
        .ddram_burstcnt,
        .ddram_addr,
        .ddram_din,
        .ddram_be,
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready,
        .epoch_quiescent,
        .debug_state,
        .protocol_error
    );

    always_ff @(posedge clk) begin
        if (!reset) begin
            if (!credit_busy || dut.grant_owner == 2'd3)
                credit_grant_cycles <= credit_grant_cycles + 1;
            if (ddram_we && !ddram_busy) begin
                if (accepted_count >= 3)
                    $fatal(1, "unexpected fourth physical command");
                accepted_address[accepted_count] <= ddram_addr;
                accepted_count <= accepted_count + 1;
            end
            if (credit_accepted)
                $fatal(1, "compile-time-disabled credit client accepted");
            if (cpu_accepted)
                cpu_we <= 1'b0;
            if (video_accepted)
                video_we <= 1'b0;
            if (sound_accepted)
                sound_we <= 1'b0;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // A stale response extends quarantine and is discarded without being
        // routed or diagnosed as an ownerless response.
        @(negedge clk);
        ddram_dout_ready = 1'b1;
        @(posedge clk);
        #1;
        if (epoch_quiescent || protocol_error)
            $fatal(1, "stale response escaped reset quarantine");
        @(negedge clk);
        ddram_dout_ready = 1'b0;

        repeat (2) begin
            @(posedge clk);
            #1;
            if (epoch_quiescent)
                $fatal(1, "DDR epoch released before full quiet interval");
        end
        @(posedge clk);
        #1;
        if (!epoch_quiescent || debug_state[31])
            $fatal(1, "DDR epoch did not release after quiet interval");

        // All three enabled clients hold a write. With legacy rotation
        // selected, their physical acceptance order must be 0,1,2 while the
        // asserted disabled credit client is invisible.
        @(negedge clk);
        cpu_we = 1'b1;
        video_we = 1'b1;
        sound_we = 1'b1;
        wait (accepted_count == 3);
        @(posedge clk);
        #1;
        if (accepted_address[0] != 29'h0000010 ||
            accepted_address[1] != 29'h0000020 ||
            accepted_address[2] != 29'h0000030)
            $fatal(1,
                "masked rotation order mismatch %h %h %h",
                accepted_address[0],
                accepted_address[1],
                accepted_address[2]);
        if (credit_grant_cycles != 0 || credit_accepted ||
            ddram_addr == 29'h0000040)
            $fatal(1, "disabled credit client consumed a grant");

        // Outside quarantine, an ownerless response is terminal evidence and
        // immediately withdraws the epoch-ready contract.
        @(negedge clk);
        ddram_dout_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!protocol_error || epoch_quiescent)
            $fatal(1, "ownerless response did not fail the epoch closed");

        $display(
            "PASS: enabled-client mask skips credit, preserves 0/1/2 order, and exports fail-closed DDR epoch readiness");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "four-client mask/quarantine timeout");
    end
endmodule

`default_nettype wire
