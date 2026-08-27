`timescale 1ns/1ps
module tb_nds_nitro_save_profile;
    logic clk = 0;
    logic reset = 1;
    logic start = 0;
    logic [31:0] game_code;
    logic busy, valid;
    logic [3:0] save_type;
    logic video_clk = 0;
    logic [3:0] cdc_type_skew, cdc_type_meta, cdc_type_sync;
    logic cdc_valid_meta, cdc_valid_sync;
    logic [3:0] previous_type;
    logic previous_valid;

    always #5 clk = ~clk;
    // Actual clk_video is slightly faster than clk1x.  The extra payload stage
    // intentionally models the worst legal CDC outcome: valid is captured on
    // one destination edge while a changing payload bit resolves one edge late.
    always #4.4 video_clk = ~video_clk;

    always_ff @(posedge video_clk) begin
        if (reset) begin
            cdc_type_skew <= '0;
            cdc_type_meta <= '0;
            cdc_type_sync <= '0;
            cdc_valid_meta <= 0;
            cdc_valid_sync <= 0;
        end else begin
            cdc_type_skew <= save_type;
            cdc_type_meta <= cdc_type_skew;
            cdc_type_sync <= cdc_type_meta;
            cdc_valid_meta <= valid;
            cdc_valid_sync <= cdc_valid_meta;
        end
    end

    always @(negedge clk) begin
        if (reset) begin
            previous_type = 0;
            previous_valid = 0;
        end else begin
            if (valid && !previous_valid && save_type !== previous_type)
                $fatal(1, "profile valid rose on the payload-changing cycle");
            previous_type = save_type;
            previous_valid = valid;
        end
    end

    nds_nitro_save_profile dut (.*);

    task automatic check(input logic [31:0] code, input logic [3:0] expected);
        begin
            @(posedge clk);
            game_code <= code;
            start <= 1;
            @(posedge clk);
            start <= 0;
            wait (!valid);
            wait (!cdc_valid_sync);
            wait (valid);
            if (save_type !== expected)
                $fatal(1, "game %08x expected save type %0d, got %0d",
                       code, expected, save_type);
            wait (cdc_valid_sync);
            @(negedge video_clk);
            if (cdc_type_sync !== expected)
                $fatal(1, "game %08x CDC valid preceded type: expected %0d got %0d",
                       code, expected, cdc_type_sync);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset <= 0;
        check(32'h45443241, 4'd2); // A2DE, NSMB, 8 KiB EEPROM
        check(32'h45555159, 4'd3); // YQUE, Chrono, 64 KiB EEPROM
        check(32'h45334441, 4'd5); // AD3E, Nintendogs, 256 KiB flash
        check(32'h45555043, 4'd6); // CPUE, Pokemon Platinum, 512 KiB flash
        check(32'h41464141, 4'd4); // AAFA, 128 KiB FRAM-compatible profile
        check(32'h444e4259, 4'd7); // YBND, 1 MiB flash profile
        check(32'h5a5a5242, 4'd3); // final populated ROM row
        check(32'h445a3659, 4'd0); // explicit melonDS no-save entry
        check(32'h45575141, 4'd1); // AQWE, tiny EEPROM (default path)
        check(32'h23232323, 4'd0); // local color-test homebrew
        $display("PASS: compact melonDS save-profile lookup");
        $finish;
    end
endmodule
