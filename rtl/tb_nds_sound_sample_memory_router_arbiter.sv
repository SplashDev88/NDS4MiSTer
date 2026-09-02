module tb_nds_sound_sample_memory_router_arbiter;
    localparam logic [28:0] MAIN_BASE   = 29'h05820000;
    localparam logic [28:0] SHARED_BASE = 29'h05802000;
    localparam logic [28:0] ARM7_BASE   = 29'h05804000;

    logic clk = 0;
    logic reset = 1;

    logic sound_request = 0;
    logic [31:0] sound_address = 0;
    logic [1:0] wramcnt = 2;
    logic sound_done;
    logic [31:0] sound_data;
    logic sound_busy;
    logic protocol_error;
    logic unsupported_request;
    logic [3:0] unsupported_reason;
    logic [31:0] unsupported_address;
    logic sound_ddram_read;
    logic [7:0] sound_ddram_burst;
    logic [28:0] sound_ddram_address;
    logic sound_command_accepted;
    logic [63:0] sound_read_data;
    logic sound_read_ready;
    logic ddram_epoch_quiescent = 0;

    logic a_busy;
    logic b_rd = 0;
    logic [28:0] b_addr = 29'h00123456;
    logic b_busy;
    logic [63:0] b_dout;
    logic b_dout_ready;
    logic b_command_accepted;
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

    integer sound_accepts = 0;
    integer other_accepts = 0;
    integer other_responses = 0;
    integer sound_held_behind_other = 0;
    logic [63:0] last_other_data = 0;

    always #5 clk = ~clk;

    nds_sound_sample_memory_router #(
        .MAIN_RAM_BASE_WORD(MAIN_BASE),
        .SHARED_WRAM_BASE_WORD(SHARED_BASE),
        .ARM7_WRAM_BASE_WORD(ARM7_BASE)
    ) router (
        .clk,
        .reset,
        .sound_request,
        .sound_address,
        .wramcnt,
        .sound_done,
        .sound_data,
        .sound_busy,
        .protocol_error,
        .unsupported_request,
        .unsupported_reason,
        .unsupported_address,
        .ddram_read(sound_ddram_read),
        .ddram_burst_count(sound_ddram_burst),
        .ddram_address(sound_ddram_address),
        .ddram_command_accepted(sound_command_accepted),
        .ddram_read_data(sound_read_data),
        .ddram_read_data_ready(sound_read_ready),
        .ddram_epoch_quiescent
    );

    nds_ddram_arbiter arbiter (
        .clk,
        .reset,
        .a_rd(sound_ddram_read),
        .a_we(1'b0),
        .a_burstcnt(sound_ddram_burst),
        .a_addr(sound_ddram_address),
        .a_din(64'd0),
        .a_be(8'hff),
        .a_busy,
        .a_dout(sound_read_data),
        .a_dout_ready(sound_read_ready),
        .a_command_accepted(sound_command_accepted),
        .b_rd,
        .b_we(1'b0),
        .b_burstcnt(8'd1),
        .b_addr,
        .b_din(64'd0),
        .b_be(8'hff),
        .b_busy,
        .b_dout,
        .b_dout_ready,
        .b_command_accepted,
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
        if (reset) begin
            sound_accepts <= 0;
            other_accepts <= 0;
            other_responses <= 0;
            sound_held_behind_other <= 0;
            last_other_data <= 0;
        end else begin
            if (sound_command_accepted)
                sound_accepts <= sound_accepts + 1;
            if (b_command_accepted)
                other_accepts <= other_accepts + 1;
            if (b_dout_ready) begin
                other_responses <= other_responses + 1;
                last_other_data <= b_dout;
            end
            if (sound_ddram_read && !ddram_rd)
                sound_held_behind_other <=
                    sound_held_behind_other + 1;
        end
    end

    task automatic sound_pulse(input logic [31:0] address);
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
        @(negedge clk);
        ddram_epoch_quiescent = 1;
        @(posedge clk);
        #1;
        if (sound_busy)
            $fatal(1, "router remained quarantined with idle arbiter");

        // Present both clients together. Reset grant priority is A, so the
        // translated main-RAM sound request must win first while B remains
        // asserted for the following grant.
        @(negedge clk);
        while (a_busy)
            @(negedge clk);
        sound_address = 32'h023ffffc;
        sound_request = 1;
        b_rd = 1;
        @(negedge clk);
        sound_request = 0;
        wait (ddram_rd);
        if (ddram_we || ddram_addr != MAIN_BASE + 29'h0007ffff ||
            ddram_burstcnt != 1)
            $fatal(1,
                "concurrent first grant/address mismatch addr=%08x",
                ddram_addr);
        repeat (5) begin
            @(negedge clk);
            if (!ddram_rd ||
                ddram_addr != MAIN_BASE + 29'h0007ffff)
                $fatal(1,
                    "sound command was not held under physical waitrequest");
        end
        ddram_dout = 64'hface0001_cafe0001;
        ddram_dout_ready = 1;
        ddram_busy = 0;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'hface0001 ||
            b_dout_ready)
            $fatal(1,
                "same-edge sound response ownership/data mismatch");
        @(negedge clk);
        ddram_dout_ready = 0;
        ddram_busy = 1;

        // The held competing client now receives the next command grant. Its
        // response is delayed, and a new sound request queues behind it.
        wait (ddram_rd && ddram_addr == b_addr);
        repeat (2) @(negedge clk);
        ddram_busy = 0;
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1;
        b_rd = 0;

        sound_address = 32'h03000004;
        sound_request = 1;
        @(negedge clk);
        sound_request = 0;
        repeat (4) begin
            @(negedge clk);
            if (!sound_ddram_read || ddram_rd)
                $fatal(1,
                    "sound client did not remain queued behind pending B response");
        end

        ddram_dout = 64'hbbbb0002_aaaa0002;
        ddram_dout_ready = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_dout_ready = 0;
        if (other_responses != 1 ||
            last_other_data != 64'hbbbb0002_aaaa0002 ||
            sound_done)
            $fatal(1,
                "delayed B response ownership mismatch count=%0d data=%016x",
                other_responses, last_other_data);

        // After B drains, the live WRAMCNT=2 mapping is admitted: ARM7 sees
        // the upper shared 16 KiB bank, and address bit 2 selects the high
        // 32-bit lane. Return this response after physical acceptance.
        wait (ddram_rd);
        if (ddram_addr != SHARED_BASE + 29'h00000800)
            $fatal(1,
                "queued WRAMCNT=2 sound mapping mismatch addr=%08x",
                ddram_addr);
        repeat (3) @(negedge clk);
        ddram_busy = 0;
        @(posedge clk);
        @(negedge clk);
        ddram_busy = 1;
        if (ddram_rd || !sound_busy)
            $fatal(1, "delayed sound response setup failed");
        repeat (3) @(negedge clk);
        ddram_dout = 64'h77770003_33330003;
        ddram_dout_ready = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h77770003 ||
            b_dout_ready)
            $fatal(1,
                "delayed sound response ownership/data mismatch");
        @(negedge clk);
        ddram_dout_ready = 0;

        if (protocol_error || unsupported_request ||
            sound_accepts != 2 || other_accepts != 1 ||
            other_responses != 1 || sound_held_behind_other < 4)
            $fatal(1,
                "concurrent arbiter counters/error mismatch sound=%0d other=%0d responses=%0d held=%0d protocol=%0b",
                sound_accepts, other_accepts, other_responses,
                sound_held_behind_other, protocol_error);

        $display(
            "PASS: ARM7-view sound router preserves address and response ownership under concurrent real-arbiter traffic");
        $display(
            "INFO: sound_accepts=%0d other_accepts=%0d queued_sound_cycles=%0d debug=%05x",
            sound_accepts, other_accepts,
            sound_held_behind_other, debug_state);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "sound sample router arbiter timeout");
    end
endmodule
