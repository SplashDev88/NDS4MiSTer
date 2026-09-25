`timescale 1ns/1ps
// Independent byte-memory scoreboard: grouping may change, but each fence
// must observe precisely the original writes, and no frame boundary may move.
module tb_nds_h3d_vram_record_packer;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    logic in_record_valid = 0, in_record_ready;
    logic [127:0] in_record = 0;
    logic [31:0] in_record_frame = 0;
    logic in_record_frame_end = 0;
    logic in_boundary_valid = 0, in_boundary_ready;
    logic [31:0] in_boundary_frame = 0;
    logic out_record_valid, out_record_ready = 0;
    logic [127:0] out_record;
    logic [31:0] out_record_frame;
    logic out_record_frame_end;
    logic out_boundary_valid, out_boundary_ready = 0;
    logic [31:0] out_boundary_frame;
    logic [7:0] expected [0:255], actual [0:255];
    logic [7:0] checkpoint [0:127][0:255];
    integer fences = 0, boundaries = 0, pairs = 0, stalls = 0;
    integer address, request_id;
    logic [31:0] rng = 32'hc519271b;
    logic [31:0] input_rng = 32'h41491383;
    logic enable_sink = 0;
    nds_h3d_vram_record_packer #(.FIFO_LGDEPTH(3), .LINGER_CYCLES(5)) dut (.*);

    always @(negedge clk) begin
        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        out_record_ready = enable_sink && rng[2:0] == 0;
        out_boundary_ready = enable_sink && rng[3:1] == 0;
    end

    always @(posedge clk) if (!reset) begin
        if (in_record_valid && !in_record_ready) stalls = stalls + 1;
        if (out_record_valid && out_boundary_valid)
            $fatal(1, "record and boundary overlapped");
        if (out_record_valid && out_record_ready) begin
            if (out_record_frame_end) $fatal(1, "unexpected synthetic frame end");
            case (out_record[7:0])
                3, 11: begin
                    address = out_record[63:32] - 32'h06000000;
                    if (address < 0 || address >= 256 || address % 4 != 0)
                        $fatal(1, "packed address out of bounds/alignment");
                    for (integer byte_id = 0; byte_id < 4; byte_id = byte_id + 1)
                        if (out_record[16+byte_id])
                            actual[address+byte_id] = out_record[64+byte_id*8 +: 8];
                    if (out_record[7:0] == 11) begin
                        if (out_record[19:8] != 12'hf02 || address > 248)
                            $fatal(1, "invalid VRAM pair metadata");
                        for (integer byte_id = 0; byte_id < 4; byte_id = byte_id + 1)
                            actual[address+4+byte_id] = out_record[96+byte_id*8 +: 8];
                        pairs = pairs + 1;
                    end
                end
                10: begin
                    request_id = out_record[63:32];
                    if (request_id != fences + 1 || out_record[127:64] != 0 ||
                        out_record[31:0] != 10 || out_record_frame != fences / 8)
                        $fatal(1, "readback fence changed or reordered");
                    for (integer byte_id = 0; byte_id < 256; byte_id = byte_id + 1)
                        if (actual[byte_id] !== checkpoint[fences][byte_id])
                            $fatal(1, "write/fence mismatch group=%0d byte=%0d", fences, byte_id);
                    fences = fences + 1;
                end
                default: $fatal(1, "unexpected output kind");
            endcase
        end
        if (out_boundary_valid && out_boundary_ready) begin
            if (out_boundary_frame != boundaries || fences != (boundaries + 1) * 8)
                $fatal(1, "boundary crossed a write/fence");
            boundaries = boundaries + 1;
        end
    end

    task automatic send(input logic [127:0] value, input integer frame);
        begin
            @(negedge clk);
            in_record = value;
            in_record_frame = frame;
            in_record_valid = 1;
            do @(posedge clk); while (!in_record_ready);
            @(negedge clk);
            in_record_valid = 0;
        end
    endtask
    task automatic write_word(input integer word_index, input logic [3:0] be,
                              input logic [31:0] data, input integer group_id);
        logic [127:0] value;
        begin
            value = {32'd0, data, (32'h06000000 + 32'(word_index*4)),
                     (32'h20000000 | (32'(group_id) << 20) | (32'(be) << 16) |
                      ((be == 15 ? 32'd2 : 32'd1) << 8) | 32'd3)};
            for (integer b = 0; b < 4; b = b + 1)
                if (be[b]) expected[word_index*4+b] = data[b*8 +: 8];
            send(value, group_id / 8);
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        // Leave buffered records at reset, including a partially merged word.
        send({64'hbad00bad, 32'h06000000, 32'h20030103}, 0);
        send({64'hbeefbeef, 32'h06000004, 32'h200f0203}, 0);
        @(negedge clk); reset = 1;
        repeat (4) @(negedge clk);
        reset = 0;
        for (integer b = 0; b < 256; b = b + 1) begin
            expected[b] = 0;
            actual[b] = 0;
        end
        enable_sink = 1;
        for (integer g = 0; g < 128; g = g + 1) begin
            // Guaranteed adjacent full pair plus repeated partial overwrites.
            write_word(0, 3, 32'h00001234 + 32'(g), g);
            write_word(0, 12, 32'h98760000, g);
            write_word(1, 15, 32'h01234567 ^ 32'(g), g);
            for (integer w = 0; w < 20; w = w + 1) begin
                input_rng = {input_rng[30:0], input_rng[31] ^ input_rng[21] ^ input_rng[1] ^ input_rng[0]};
                write_word(int'(input_rng[5:0]), input_rng[6] ? 4'hf : 4'h3, input_rng, g);
            end
            for (integer b = 0; b < 256; b = b + 1) checkpoint[g][b] = expected[b];
            send({64'd0, 32'(g+1), 32'd10}, g / 8);
            if (g % 8 == 7) begin
                @(negedge clk);
                in_boundary_valid = 1;
                in_boundary_frame = g / 8;
                do @(posedge clk); while (!in_boundary_ready);
                @(negedge clk); in_boundary_valid = 0;
            end
        end
        wait (boundaries == 16);
        repeat (20) @(posedge clk);
        if (fences != 128 || pairs == 0 || stalls == 0)
            $fatal(1, "insufficient packing/stall/fence coverage");
        $display("PASS: VRAM packer byte equivalence, %0d pairs, 128 ordered fences, 16 boundaries, %0d stall cycles, reset", pairs, stalls);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "packer test timeout");
    end
endmodule
