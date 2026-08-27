`timescale 1ns/1ps
`default_nettype none

module tb_nds_ddr_layer_reader_scanline_budget;
    localparam logic [28:0] BASE = 29'h06080000;
    localparam integer RECORDS = 512;
    localparam integer SCANLINE_CYCLES = 640 * 6;

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    always #5 clk = ~clk;

    logic legacy_start = 1'b0;
    logic legacy_busy;
    logic legacy_done;
    logic [7:0] legacy_burst;
    logic [28:0] legacy_addr;
    logic legacy_ddr_busy = 1'b0;
    logic [63:0] legacy_dout = 64'd0;
    logic legacy_ready = 1'b0;
    logic legacy_rd;
    logic legacy_valid;
    logic [319:0] legacy_record;

    logic burst_start = 1'b0;
    logic burst_busy;
    logic burst_done;
    logic [7:0] burst_count;
    logic [28:0] burst_addr;
    logic burst_ddr_busy = 1'b0;
    logic [63:0] burst_dout = 64'd0;
    logic burst_ready = 1'b0;
    logic burst_rd;
    logic burst_valid;
    logic [319:0] burst_record;

    nds_ddr_layer_reader #(.RECORDS_PER_BURST(1)) legacy (
        .clk,.reset_n,.start(legacy_start),.base_addr(BASE),
        .record_count(20'(RECORDS)),.busy(legacy_busy),.done(legacy_done),
        .ddram_burstcnt(legacy_burst),.ddram_addr(legacy_addr),
        .ddram_busy(legacy_ddr_busy),.ddram_dout(legacy_dout),
        .ddram_dout_ready(legacy_ready),.ddram_rd(legacy_rd),
        .record_valid(legacy_valid),.record_ready(1'b1),
        .record_data(legacy_record));

    localparam integer SAFE_BURST_RECORDS = 16;
    nds_ddr_layer_reader #(.RECORDS_PER_BURST(SAFE_BURST_RECORDS)) burst (
        .clk,.reset_n,.start(burst_start),.base_addr(BASE),
        .record_count(20'(RECORDS)),.busy(burst_busy),.done(burst_done),
        .ddram_burstcnt(burst_count),.ddram_addr(burst_addr),
        .ddram_busy(burst_ddr_busy),.ddram_dout(burst_dout),
        .ddram_dout_ready(burst_ready),.ddram_rd(burst_rd),
        .record_valid(burst_valid),.record_ready(1'b1),
        .record_data(burst_record));

    integer cycle = 0;
    integer legacy_start_cycle = 0;
    integer legacy_end_cycle = 0;
    integer burst_start_cycle = 0;
    integer burst_end_cycle = 0;
    integer legacy_commands = 0;
    integer burst_commands = 0;
    integer legacy_beats_left = 0;
    integer burst_beats_left = 0;
    integer legacy_records = 0;
    integer burst_records = 0;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        legacy_ready <= 1'b0;
        burst_ready <= 1'b0;

        if (legacy_beats_left > 0) begin
            legacy_dout <= 64'h0102030405060708;
            legacy_ready <= 1'b1;
            legacy_beats_left <= legacy_beats_left - 1;
        end else if (legacy_rd) begin
            legacy_commands <= legacy_commands + 1;
            legacy_beats_left <= legacy_burst;
        end

        if (burst_beats_left > 0) begin
            burst_dout <= 64'h1112131415161718;
            burst_ready <= 1'b1;
            burst_beats_left <= burst_beats_left - 1;
        end else if (burst_rd) begin
            burst_commands <= burst_commands + 1;
            burst_beats_left <= burst_count;
        end

        if (legacy_valid)
            legacy_records <= legacy_records + 1;
        if (burst_valid)
            burst_records <= burst_records + 1;
        if (legacy_done && legacy_end_cycle == 0)
            legacy_end_cycle <= cycle;
        if (burst_done && burst_end_cycle == 0)
            burst_end_cycle <= cycle;
    end

    integer legacy_elapsed;
    integer burst_elapsed;
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;
        legacy_start_cycle = cycle;
        legacy_start = 1'b1;
        @(negedge clk);
        legacy_start = 1'b0;
        wait (legacy_end_cycle != 0);

        @(negedge clk);
        burst_start_cycle = cycle;
        burst_start = 1'b1;
        @(negedge clk);
        burst_start = 1'b0;
        wait (burst_end_cycle != 0);
        #1;

        legacy_elapsed = legacy_end_cycle - legacy_start_cycle;
        burst_elapsed = burst_end_cycle - burst_start_cycle;
        if (legacy_records != RECORDS || burst_records != RECORDS)
            $fatal(1,"record loss legacy=%0d burst=%0d",
                legacy_records,burst_records);
        if (legacy_commands != RECORDS)
            $fatal(1,"legacy command count %0d",legacy_commands);
        if (burst_commands != RECORDS/SAFE_BURST_RECORDS)
            $fatal(1,"burst command count %0d",burst_commands);
        if (legacy_elapsed <= SCANLINE_CYCLES)
            $fatal(1,"legacy unexpectedly fits scanline: %0d",legacy_elapsed);
        if (burst_elapsed >= SCANLINE_CYCLES)
            $fatal(1,"batched reader misses scanline: %0d",burst_elapsed);
        $display(
            "PASS: 512-record line legacy=%0d cycles/%0d commands, batched=%0d cycles/%0d commands, scanline_budget=%0d",
            legacy_elapsed,legacy_commands,burst_elapsed,burst_commands,
            SCANLINE_CYCLES);
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1,"timeout legacy_done=%0d burst_done=%0d",legacy_done,burst_done);
    end
endmodule

`default_nettype wire
