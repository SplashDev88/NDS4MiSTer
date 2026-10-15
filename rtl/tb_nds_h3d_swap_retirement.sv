`timescale 1ns/1ps
module tb_nds_h3d_swap_retirement;
    logic source_clk = 0, ddr_clk = 0, reset = 0, session_flush = 0;
    logic lcd_vblank = 0, gpu_valid = 0, gpu_ready;
    logic [27:0] gpu_address = 0;
    logic [1:0] gpu_access = 2;
    logic [3:0] gpu_byte_enable = 15;
    logic [31:0] gpu_data = 0;
    logic [63:0] gpu_timestamp = 1;
    logic hblank_valid = 0, hblank_ready;
    logic [63:0] hblank_timestamp = 10000;
    logic source_active, ddr_active, source_fault, ddr_fault;
    logic [8:0] fifo_level;
    logic fifo_full, record_valid, boundary_valid;
    logic geometry_busy;
    logic [127:0] record;
    integer commands = 0, fences = 0, swaps = 0, phases = 0;
    always #5 source_clk = ~source_clk;
    always #7 ddr_clk = ~ddr_clk;
    nds_h3d_frame_record_cdc #(.ASYNC_LGDEPTH(2), .SWAP_VBLANK_RETIREMENT(1)) dut (
        .source_clk(source_clk), .ddr_clk(ddr_clk), .reset(reset),
        .session_flush(session_flush), .lcd_vblank(lcd_vblank),
        .gpu_valid(gpu_valid), .gpu_ready(gpu_ready), .gpu_address(gpu_address),
        .gpu_access(gpu_access), .gpu_byte_enable(gpu_byte_enable),
        .gpu_data(gpu_data), .gpu_timestamp(gpu_timestamp), .gpu_scanline(9'd0),
        .arm9_vram_valid(1'b0), .arm9_vram_address(28'd0), .arm9_vram_access(2'd0),
        .arm9_vram_byte_enable(4'd0), .arm9_vram_data(32'd0),
        .arm9_vram_timestamp(64'd0), .arm9_vram_scanline(9'd0),
        .arm7_vram_valid(1'b0), .arm7_vram_address(28'd0), .arm7_vram_access(2'd0),
        .arm7_vram_byte_enable(4'd0), .arm7_vram_data(32'd0),
        .arm7_vram_timestamp(64'd0), .arm7_vram_scanline(9'd0),
        .hblank_valid(hblank_valid), .hblank_ready(hblank_ready),
        .hblank_line(9'd192), .hblank_frame(32'd1), .hblank_timestamp(hblank_timestamp),
        .frame_valid(1'b0), .frame_number(32'd0), .frame_timestamp(64'd0),
        .source_active(source_active), .ddr_active(ddr_active),
        .source_fault(source_fault), .ddr_fault(ddr_fault),
        .fifo_level(fifo_level), .fifo_full(fifo_full), .gx_stack_ack(1'b0),
        .gx_geometry_busy(geometry_busy),
        .record_valid(record_valid), .record_ready(1'b1), .record(record),
        .boundary_valid(boundary_valid), .boundary_ready(1'b1)
    );
    always @(posedge ddr_clk) if (ddr_active && !session_flush) begin
        if (source_fault || ddr_fault || boundary_valid) $fatal(1, "transport fault");
        if (record_valid) case (record[7:0])
            1: begin
                if (record[15:8] == 8'h50) swaps = swaps + 1;
                else begin
                    if (record[15:8] != 8'h20 || record[95:64] != 32'(commands))
                        $fatal(1, "command order mismatch");
                    commands = commands + 1;
                end
            end
            2: if (record[63:34] != (32'h04000304 >> 2)) $fatal(1, "unexpected register");
            8: phases = phases + 1;
            10: begin
                if (record[63:32] != 32'(fences+1) || commands != fences+1)
                    $fatal(1, "readback fence passed preceding geometry");
                fences = fences + 1;
            end
            default: $fatal(1, "unexpected record kind %0d", record[7:0]);
        endcase
    end
    task automatic send(input logic [27:0] addr, input logic [31:0] data);
        integer cycles;
        @(negedge source_clk);
        gpu_address = addr; gpu_data = data; gpu_valid = 1;
        gpu_access = addr == 28'h7f0 ? 3 : 2;
        gpu_byte_enable = addr == 28'h7f0 ? 0 : 15;
        cycles = 0;
        do begin
            @(posedge source_clk); cycles = cycles + 1;
            if (cycles > 1000) $fatal(1, "ordered source stalled address=%h", addr);
        end while (!gpu_ready);
        @(negedge source_clk); gpu_valid = 0; gpu_timestamp = gpu_timestamp + 1;
    endtask
    task automatic phase;
        integer cycles;
        @(negedge source_clk); hblank_valid = 1; cycles = 0;
        do begin
            @(posedge source_clk); cycles = cycles + 1;
            if (cycles > 1000) $fatal(1, "LCD event deadlock");
        end while (!hblank_ready);
        @(negedge source_clk); hblank_valid = 0;
    endtask
    initial begin
        #1 reset = 1; repeat (4) @(negedge source_clk); reset = 0;
        wait (source_active && ddr_active);
        // Direct boot already enables geometry; no POWCNT write is required.
        send(28'h540, 0);
        repeat (20) @(negedge source_clk);
        if (fifo_level != 0 || !geometry_busy)
            $fatal(1, "source status lost empty-FIFO SWAP busy");
        // Each fence flushes the untagged transport packer while architectural
        // occupancy accumulates behind SWAP. Even the 256th fence must pass.
        for (integer i=0; i<256; i=i+1) begin
            send(28'h480, 32'(i)); send(28'h7f0, 32'(i+1));
        end
        repeat (20) @(negedge source_clk);
        if (!fifo_full || fifo_level != 256 || commands != 256 || fences != 256 || swaps != 1)
            $fatal(1, "SWAP credits/readback transport mismatch");
        phase(); repeat (20) @(negedge source_clk);
        if (phases != 1 || !fifo_full || !geometry_busy)
            $fatal(1, "queued marker retired native SWAP");
        // Full FIFO can hold an older write in front of an LCD marker. The
        // independent native VBlank releases it, preserving source order.
        fork
            send(28'h480, 256);
            begin
                repeat (20) @(negedge source_clk);
                if (!gpu_valid || gpu_ready) $fatal(1, "full FIFO did not stall write");
                lcd_vblank = 1; @(negedge source_clk); lcd_vblank = 0;
            end
            phase();
        join
        send(28'h7f0, 257);
        repeat (400) @(negedge source_clk);
        if (fifo_level || commands != 257 || fences != 257 || phases != 2)
            $fatal(1, "native VBlank failed to release ordered stream");
        if (geometry_busy) $fatal(1, "source status stayed busy after VBlank drain");
        // Low-byte power-off suppresses new waits. A high-byte write must
        // not re-enable geometry. Low-byte enable restores SWAP retirement.
        send(28'h304, 0);
        @(negedge source_clk);
        gpu_address = 28'h304; gpu_byte_enable = 4'b0010;
        gpu_access = 0; gpu_data = 32'h00000800; gpu_valid = 1;
        do @(posedge source_clk); while (!gpu_ready);
        @(negedge source_clk); gpu_valid = 0; gpu_timestamp = gpu_timestamp + 1;
        send(28'h540, 0); send(28'h480, 257); send(28'h7f0, 258);
        repeat (30) @(negedge source_clk);
        if (fifo_level) $fatal(1, "high-byte POWCNT write enabled geometry");
        send(28'h304, 8); send(28'h540, 0); send(28'h480, 258);
        send(28'h7f0, 259); repeat (30) @(negedge source_clk);
        if (fifo_level != 1) $fatal(1, "low-byte POWCNT enable failed");
        session_flush = 1; repeat (4) @(negedge source_clk); session_flush = 0;
        wait (source_active && ddr_active);
        if (fifo_level || geometry_busy || source_fault || ddr_fault) $fatal(1, "session reset");
        $display("PASS: product CDC SWAP barrier, 259 ordered readbacks, LCD progress, native VBlank and session reset");
        $finish;
    end
    initial begin #200000; $fatal(1, "watchdog"); end
endmodule
