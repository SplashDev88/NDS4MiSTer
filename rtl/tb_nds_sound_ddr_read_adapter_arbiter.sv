module tb_nds_sound_ddr_read_adapter_arbiter;
    logic clk = 0;
    logic reset = 1;
    logic sound_request = 0;
    logic [31:0] sound_address = 0;
    logic sound_done;
    logic [31:0] sound_data;
    logic sound_busy;
    logic protocol_error;
    logic sound_ddr_read;
    logic [7:0] sound_ddr_burst;
    logic [28:0] sound_ddr_address;
    logic sound_command_accepted;
    logic [63:0] sound_read_data;
    logic sound_read_ready;
    logic ddram_epoch_quiescent = 0;

    logic a_busy;
    logic ddram_rd;
    logic ddram_we;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din;
    logic [7:0] ddram_be;
    logic ddram_busy = 1;
    logic [63:0] ddram_dout = 0;
    logic ddram_dout_ready = 0;
    logic [17:0] debug_state;
    logic b_busy_unused;
    logic [63:0] b_dout_unused;
    logic b_dout_ready_unused;
    logic b_command_accepted_unused;
    integer physical_accepts = 0;
    integer held_cycles = 0;

    always #5 clk = ~clk;

    nds_sound_ddr_read_adapter adapter (
        .clk,
        .reset,
        .sound_request,
        .sound_address,
        .sound_done,
        .sound_data,
        .sound_busy,
        .protocol_error,
        .ddram_read(sound_ddr_read),
        .ddram_burst_count(sound_ddr_burst),
        .ddram_address(sound_ddr_address),
        .ddram_command_accepted(sound_command_accepted),
        .ddram_read_data(sound_read_data),
        .ddram_read_data_ready(sound_read_ready),
        .ddram_epoch_quiescent
    );

    nds_ddram_arbiter arbiter (
        .clk,
        .reset,
        .a_rd(sound_ddr_read),
        .a_we(1'b0),
        .a_burstcnt(sound_ddr_burst),
        .a_addr(sound_ddr_address),
        .a_din(64'd0),
        .a_be(8'hff),
        .a_busy,
        .a_dout(sound_read_data),
        .a_dout_ready(sound_read_ready),
        .a_command_accepted(sound_command_accepted),
        .b_rd(1'b0),
        .b_we(1'b0),
        .b_burstcnt(8'd1),
        .b_addr(29'd0),
        .b_din(64'd0),
        .b_be(8'hff),
        .b_busy(b_busy_unused),
        .b_dout(b_dout_unused),
        .b_dout_ready(b_dout_ready_unused),
        .b_command_accepted(b_command_accepted_unused),
        .debug_state,
        .ddram_rd,
        .ddram_we,
        .ddram_burstcnt,
        .ddram_addr,
        .ddram_din,
        .ddram_be,
        .ddram_busy,
        .ddram_dout,
        .ddram_dout_ready
    );

    always @(posedge clk) begin
        if (!reset && ddram_rd && ddram_busy)
            held_cycles <= held_cycles + 1;
        if (!reset && ddram_rd && !ddram_busy)
            physical_accepts <= physical_accepts + 1;
    end

    task automatic request(input logic [31:0] address);
        begin
            @(negedge clk);
            sound_address = address;
            sound_request = 1;
            @(negedge clk);
            sound_request = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        @(posedge clk);
        // Complete the explicit low-to-high epoch acknowledgement only after
        // the real arbiter and physical model are both idle.
        @(negedge clk);
        ddram_epoch_quiescent = 1;
        @(posedge clk);
        #1;
        if (sound_busy)
            $fatal(1, "adapter remained quarantined");

        // The physical bridge remains busy while idle and only lowers
        // waitrequest after seeing a held command.
        request(32'h02000004);
        wait (ddram_rd);
        repeat (6) begin
            @(negedge clk);
            if (!ddram_rd || ddram_we ||
                ddram_addr != 29'h05820000 ||
                ddram_burstcnt != 1)
                $fatal(1,
                    "real arbiter failed to hold sound request under idle-high waitrequest");
        end
        ddram_dout = 64'hfeedface_01234567;
        ddram_dout_ready = 1;
        ddram_busy = 0;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'hfeedface)
            $fatal(1, "real-arbiter same-edge response mismatch");
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 1;

        // A second request is physically accepted without data, then receives
        // its response later through read_pending ownership.
        request(32'h02000008);
        wait (ddram_rd);
        repeat (3) @(negedge clk);
        ddram_busy = 0;
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1;
        if (ddram_rd || !sound_busy)
            $fatal(1, "real-arbiter delayed-response setup failed");
        repeat (4) @(negedge clk);
        ddram_dout = 64'h89abcdef_76543210;
        ddram_dout_ready = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h76543210)
            $fatal(1, "real-arbiter delayed response mismatch");
        @(negedge clk);
        ddram_dout_ready = 0;

        if (protocol_error || physical_accepts != 2 || held_cycles < 6)
            $fatal(1,
                "real-arbiter integration counters/error mismatch accepts=%0d held=%0d error=%0b",
                physical_accepts, held_cycles, protocol_error);
        $display("PASS: sound adapter interoperates with real queued DDR arbiter for idle-high, same-edge, and delayed responses");
        $display("INFO: physical_accepts=%0d held_cycles=%0d debug=%05x",
            physical_accepts, held_cycles, debug_state);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "real-arbiter sound adapter timeout");
    end
endmodule
