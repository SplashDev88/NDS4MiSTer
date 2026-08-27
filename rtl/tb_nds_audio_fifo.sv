module tb_nds_audio_fifo;
    logic clk = 0;
    logic reset = 1;
    logic [28:0] control_addr = 0;
    logic [31:0] joystick = 0;
    logic ddram_busy = 0;
    logic [63:0] ddram_dout = 0;
    logic ddram_dout_ready = 0;
    logic [7:0] ddram_burstcnt;
    logic [28:0] ddram_addr;
    logic ddram_rd, ddram_we;
    logic [63:0] ddram_din;
    logic ce_pixel, de, hblank, vblank, hsync, vsync;
    logic [7:0] red, green, blue;
    logic ready, format_error;
    logic [3:0] debug_progress;
    logic signed [15:0] audio_l, audio_r;
    integer cycles = 0;
    integer observed = 0;
    integer last_sample_cycle = 0;
    integer word_index;
    localparam integer BLOCK0 = 802;
    localparam integer BLOCK1 = 803;
    localparam integer BLOCK2 = 802;
    localparam integer BLOCK3 = 803;
    localparam integer TOTAL_FRAMES = BLOCK0 + BLOCK1 + BLOCK2 + BLOCK3;

    always #5 clk = ~clk;
    always @(posedge clk) cycles <= cycles + 1;

    function automatic [63:0] pair(
        input signed [15:0] l0, input signed [15:0] r0,
        input signed [15:0] l1, input signed [15:0] r1);
        pair = {r1, l1, r0, l0};
    endfunction

    function automatic signed [15:0] expected_l(input integer index);
        expected_l = 16'sd100 + index;
    endfunction

    function automatic signed [15:0] expected_r(input integer index);
        expected_r = -16'sd100 - index;
    endfunction

    task automatic fill_bank(input integer bank, input integer base,
        input integer frames);
        integer i;
        reg [63:0] value;
        begin
            for (i = 0; i < (frames + 1) / 2; i = i + 1) begin
                value = pair(expected_l(base + i * 2),
                    expected_r(base + i * 2),
                    expected_l(base + i * 2 + 1),
                    expected_r(base + i * 2 + 1));
                if (bank) dut.audio_bank1[i] = value;
                else dut.audio_bank0[i] = value;
            end
        end
    endtask

    nds_compact_ddr_video #(
        .H_ACTIVE(8), .H_FRONT(1), .H_SYNC(1), .H_TOTAL(12),
        .V_ACTIVE(2), .V_FRONT(1), .V_SYNC(1), .V_TOTAL(5),
        .PIXEL_DIVIDE(3), .FRAME_WORDS(4), .FETCH_BURST_WORDS(2)
    ) dut (.*);

    always @(posedge clk) begin
        #1;
        if (!reset && (audio_l != 0 || audio_r != 0) &&
            audio_l == expected_l(observed)) begin
            if (audio_r !== expected_r(observed))
                $fatal(1, "sample %0d right mismatch: %0d", observed, audio_r);
            if (observed && cycles - last_sample_cycle != 1250)
                $fatal(1, "sample %0d interval was %0d clocks", observed,
                    cycles - last_sample_cycle);
            last_sample_cycle = cycles;
            observed = observed + 1;
            if (observed == 1) begin
                // Queue the following publication while bank 1 is playing.
                force dut.active_bank = 1'b0;
                force dut.active_audio_frames = BLOCK1;
            end
            if (observed == BLOCK0 + 1) begin
                // Bank 1 is now inactive. Refill it with the third block and
                // publish while the 803-sample bank 0 block is playing.
                fill_bank(1, BLOCK0 + BLOCK1, BLOCK2);
                force dut.active_bank = 1'b1;
                force dut.active_audio_frames = BLOCK2;
            end
            if (observed == BLOCK0 + BLOCK1 + 1) begin
                // Repeat the same handoff in the other direction.
                fill_bank(0, BLOCK0 + BLOCK1 + BLOCK2, BLOCK3);
                force dut.active_bank = 1'b0;
                force dut.active_audio_frames = BLOCK3;
            end
            if (observed == TOTAL_FRAMES) begin
                $display("NDS audio FIFO: 802/803/802/803-frame banks played in order with continuous 48 kHz cadence");
                $finish;
            end
        end
    end

    initial begin
        fill_bank(1, 0, BLOCK0);
        fill_bank(0, BLOCK0, BLOCK1);
        repeat (4) @(posedge clk);
        force dut.active_bank = 1'b1;
        force dut.active_audio_frames = BLOCK0;
        @(negedge clk) reset = 0;
        repeat (4200000) @(posedge clk);
        $fatal(1, "timeout after %0d samples", observed);
    end
endmodule
