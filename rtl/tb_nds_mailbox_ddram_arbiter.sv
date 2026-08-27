module tb_nds_mailbox_ddram_arbiter;
    timeunit 1ns;
    timeprecision 1ns;

    localparam logic [28:0] ORACLE = 29'h00200000;

    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic request = 0;
    logic [31:0] read_data;
    logic [31:0] completed_fence_sequence;
    logic irq_arm9, irq_arm7, halt_arm9, halt_arm7, done;
    logic a_rd, a_we, a_busy, a_ready;
    logic [7:0] a_burst, a_be;
    logic [28:0] a_addr;
    logic [63:0] a_din, a_dout;

    logic b_rd = 0, b_we, b_busy, b_ready;
    logic [28:0] b_addr = 29'h00300000;
    logic [63:0] b_dout;

    logic ddram_rd, ddram_we;
    logic [7:0] ddram_burst, ddram_be;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din, ddram_dout = 0;
    logic ddram_busy, ddram_ready = 0;
    integer busy_count = 0;
    integer response_delay = 0;
    integer response_beats = 0;
    integer accepted_a_writes = 0;
    integer accepted_a_reads = 0;
    integer accepted_b_writes = 0;
    logic [31:0] published_sequence = 0;

    // MiSTer's Avalon bridge may leave waitrequest asserted while idle and
    // only drop it in response to a presented command. A one-entry arbiter
    // queue must therefore let its selected client enqueue independently of
    // this raw physical signal; otherwise a client that waits for busy-low
    // can never present the request that makes busy fall.
    assign ddram_busy = busy_count != 0 || !(ddram_rd || ddram_we);
    assign b_we = !reset;

    nds_hps_oracle_mailbox #(
        .BASE_WORD(ORACLE),
        .POLL_DELAY_CYCLES(2)
    ) mailbox (
        .clk, .reset, .request, .cpu_is_arm9(1'b1),
        .elapsed_cycles(32'd7), .fence_sequence(32'h1234abcd),
        .address(32'h04000208),
        .read_not_write(1'b0), .access(2'b10),
        .write_data(32'h04000000), .read_data,
        .irq_arm9, .irq_arm7, .halt_arm9, .halt_arm7, .done,
        .completed_fence_sequence,
        .ddram_read(a_rd), .ddram_write(a_we),
        .ddram_burst_count(a_burst), .ddram_address(a_addr),
        .ddram_write_data(a_din), .ddram_byte_enable(a_be),
        .ddram_busy(a_busy), .ddram_read_data(a_dout),
        .ddram_read_data_ready(a_ready)
    );

    nds_ddram_arbiter arbiter (
        .clk, .reset,
        .a_rd, .a_we, .a_burstcnt(a_burst), .a_addr,
        .a_din, .a_be, .a_busy, .a_dout,
        .a_dout_ready(a_ready),
        .b_rd, .b_we, .b_burstcnt(8'd1), .b_addr,
        .b_din(64'hfeedfacecafebeef), .b_be(8'hff),
        .b_busy, .b_dout, .b_dout_ready(b_ready),
        .ddram_rd, .ddram_we, .ddram_burstcnt(ddram_burst),
        .ddram_addr, .ddram_din, .ddram_be,
        .ddram_busy, .ddram_dout, .ddram_dout_ready(ddram_ready)
    );

    always_ff @(posedge clk) begin
        ddram_ready <= 0;
        if (reset) begin
            busy_count <= 0;
            response_delay <= 0;
            response_beats <= 0;
            accepted_a_writes <= 0;
            accepted_a_reads <= 0;
            accepted_b_writes <= 0;
            published_sequence <= 0;
        end else begin
            if (busy_count != 0)
                busy_count <= busy_count - 1;

            if ((ddram_rd || ddram_we) && !ddram_busy) begin
                busy_count <= 2;
                if (ddram_addr >= ORACLE && ddram_addr <= ORACLE + 4) begin
                    if (ddram_we) begin
                        case (accepted_a_writes)
                            0: assert (ddram_addr == ORACLE + 1 &&
                                       ddram_din ==
                                       64'h0400000004000208)
                                else $fatal(1,
                                    "transaction beat mismatch addr=%h data=%h",
                                    ddram_addr, ddram_din);
                            1: assert (ddram_addr == ORACLE + 2 &&
                                       ddram_din ==
                                       64'h000000070000000c)
                                else $fatal(1,
                                    "control beat mismatch addr=%h data=%h",
                                    ddram_addr, ddram_din);
                            2: assert (ddram_addr == ORACLE + 4 &&
                                       ddram_din ==
                                       64'h1234abcd00000000)
                                else $fatal(1,
                                    "fence beat mismatch addr=%h data=%h",
                                    ddram_addr, ddram_din);
                            3: begin
                                assert (ddram_addr == ORACLE &&
                                        ddram_din[31:0] == 32'h4f53444e)
                                    else $fatal(1,
                                        "header beat mismatch addr=%h data=%h",
                                        ddram_addr, ddram_din);
                                published_sequence <= ddram_din[63:32];
                            end
                            default: $fatal(1,
                                "unexpected extra mailbox write");
                        endcase
                        accepted_a_writes <= accepted_a_writes + 1;
                    end else begin
                        assert (ddram_addr == ORACLE + 3 &&
                                ddram_burst == 2)
                            else $fatal(1,
                                "poll command mismatch addr=%h burst=%0d",
                                ddram_addr, ddram_burst);
                        accepted_a_reads <= accepted_a_reads + 1;
                        response_delay <= 2;
                        response_beats <= 2;
                    end
                end else if (ddram_we) begin
                    accepted_b_writes <= accepted_b_writes + 1;
                end
            end

            if (response_delay != 0) begin
                response_delay <= response_delay - 1;
            end else if (response_beats != 0) begin
                ddram_ready <= 1;
                if (response_beats == 2)
                    ddram_dout <= {published_sequence, 32'h12345678};
                else
                    ddram_dout <= 64'h0000000000000000;
                response_beats <= response_beats - 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        request = 1;
        fork
            begin
                wait (done);
            end
            begin
                #20us;
                $fatal(1,
                    "mailbox/arbiter timeout writes=%0d reads=%0d video=%0d",
                    accepted_a_writes, accepted_a_reads,
                    accepted_b_writes);
            end
        join_any
        disable fork;
        if (accepted_a_writes != 4 || accepted_a_reads != 1)
            $fatal(1, "mailbox command count mismatch writes=%0d reads=%0d",
                accepted_a_writes, accepted_a_reads);
        if (accepted_b_writes == 0)
            $fatal(1, "continuous video client was not exercised");
        if (read_data != 32'h12345678)
            $fatal(1, "mailbox response mismatch %h", read_data);
        if (completed_fence_sequence != 32'h1234abcd)
            $fatal(1, "mailbox completed wrong fence %h",
                completed_fence_sequence);
        request = 0;
        $display("PASS: mailbox publishes transaction/control/fence/header and completes through contended DDR arbiter");
        $finish;
    end
endmodule
