`timescale 1ns/1ps
module tb_nds_gx_swap_retirement;
    parameter bit ENABLE = 1;
    logic clk = 0, reset = 1, lcd_vblank = 0, geometry_enabled = 1;
    logic write_valid = 0, write_ready, write_is_dma = 0;
    logic [31:0] write_address = 32'h04000480, write_data = 0;
    logic [1:0] write_access = 2;
    logic [31:0] write_frame = 1;
    logic [63:0] write_timestamp = 1;
    logic record_valid, record_ready = 1;
    logic [127:0] record;
    logic [8:0] fifo_level;
    logic fifo_full, fifo_empty, fifo_below_half, protocol_error;
    logic [39:0] expected [0:8191];
    integer queued = 0, delivered = 0;
    always #5 clk = ~clk;
    nds_gx_fifo_packet_frontend #(.SWAP_VBLANK_RETIREMENT(ENABLE)) dut (
        .clk(clk), .reset(reset), .lcd_vblank(lcd_vblank),
        .geometry_enabled(geometry_enabled),
        .write_valid(write_valid), .write_ready(write_ready),
        .write_is_dma(write_is_dma), .write_address(write_address),
        .write_access(write_access), .write_data(write_data),
        .write_frame(write_frame), .write_timestamp(write_timestamp),
        .record_valid(record_valid), .record_ready(record_ready), .record(record),
        .fifo_level(fifo_level), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .fifo_below_half(fifo_below_half), .protocol_error(protocol_error),
        .stack_ack(1'b0)
    );
    always @(posedge clk) if (!reset) begin
        if (protocol_error) $fatal(1, "frontend protocol fault");
        if (record_valid && record_ready) begin
            if (delivered == queued ||
                {record[15:8], record[95:64]} !== expected[delivered])
                $fatal(1, "transport lost/reordered record %0d", delivered);
            delivered = delivered + 1;
        end
    end
    task automatic tick(input integer cycles);
        repeat (cycles) @(negedge clk);
    endtask
    task automatic expect_cmd(input logic [7:0] cmd, input logic [31:0] data);
        expected[queued] = {cmd, data}; queued = queued + 1;
    endtask
    task automatic bus_write(input logic [31:0] address, input logic [31:0] data);
        integer cycles;
        @(negedge clk);
        write_valid = 1; write_address = address; write_data = data;
        cycles = 0;
        do begin
            @(posedge clk); cycles = cycles + 1;
            if (cycles > 1024) $fatal(1, "unexpected write stall");
        end while (!write_ready);
        @(negedge clk); write_valid = 0;
    endtask
    task automatic send(input logic [7:0] cmd, input logic [31:0] data);
        expect_cmd(cmd, data);
        bus_write(32'h04000400 + (32'(cmd) << 2), data);
    endtask
    task automatic pulse;
        @(negedge clk); lcd_vblank = 1;
        @(negedge clk); lcd_vblank = 0;
    endtask
    task automatic drained;
        tick(600);
        if (!fifo_empty || delivered != queued)
            $fatal(1, "drain failed level=%0d delivered=%0d/%0d", fifo_level, delivered, queued);
    endtask
    initial begin
        tick(3); reset = 0;
        // No barrier: sustained ordinary traffic and pointer wraps retain order.
        for (integer i=0; i<1024; i=i+1) send(8'h20, 32'(i));
        drained();
        send(8'h50, 0); tick(4);
        for (integer i=0; i<256; i=i+1) begin
            write_is_dma = i[0]; send(8'h20, 32'(i));
        end
        tick(8);
        if (!fifo_full || fifo_level != 256 || fifo_below_half || delivered != queued)
            $fatal(1, "SWAP must retain 256 credits after transport drains");
        // CPU and DMA cannot use transport pops as architectural FIFO credits.
        write_address = 32'h04000480;
        for (integer i=0; i<2; i=i+1) begin
            write_is_dma = i[0]; tick(2);
            if (write_ready) $fatal(1, "full SWAP queue accepts CPU/DMA");
        end
        pulse(); drained();
        // Consecutive SWAPs must each wait for a distinct native VBlank.
        send(8'h50, 0); send(8'h50, 1); send(8'h20, 123);
        tick(8); if (fifo_level != 2) $fatal(1, "first SWAP wait");
        pulse(); tick(8); if (fifo_level != 1) $fatal(1, "second SWAP skipped wait");
        pulse(); drained();
        // A SWAP reaching retirement ON a VBlank edge waits until next VBlank.
        send(8'h50, 0); lcd_vblank = 1;
        tick(1); lcd_vblank = 0;
        send(8'h20, 456); tick(8);
        if (fifo_level != 1) $fatal(1, "same-edge SWAP incorrectly retired");
        pulse(); drained();
        // Packed zero-param commands and multi-param commands retain all slots.
        send(8'h50, 0);
        expect_cmd(8'h11, 32'h00111611);
        expect_cmd(8'h16, 0);
        for (integer i=1; i<16; i=i+1) expect_cmd(8'h16, 32'(i));
        expect_cmd(8'h11, 15);
        bus_write(32'h04000400, 32'h00111611);
        for (integer i=0; i<16; i=i+1) bus_write(32'h04000400, 32'(i));
        tick(8); if (fifo_level != 18) $fatal(1, "packed retirement accounting");
        pulse(); drained();
        // A stalled transport remains an independent limit after retirement.
        record_ready = 0;
        for (integer i=0; i<256; i=i+1) send(8'h20, 32'(i));
        tick(8); if (!fifo_full || write_ready) $fatal(1, "transport overflow");
        record_ready = 1; drained();
        // Disabled-geometry SWAP writes do not arm a wait. Existing wait survives
        // power-off; a disabled VBlank cannot finish the pending geometry flush.
        geometry_enabled = 0;
        send(8'h50, 0); send(8'h20, 0); drained();
        geometry_enabled = 1;
        send(8'h50, 0); send(8'h20, 0); tick(8);
        geometry_enabled = 0; pulse(); tick(8);
        if (fifo_level != 1) $fatal(1, "disabled VBlank retired a pending SWAP");
        geometry_enabled = 1; pulse(); drained();
        // Session reset cancels the virtual wait as well as transport state.
        send(8'h50, 0); send(8'h20, 789); tick(8);
        reset = 1; tick(3); reset = 0;
        if (!fifo_empty) $fatal(1, "reset retained SWAP credits");
        send(8'h20, 999); drained();
        $display("PASS: SWAP/VBlank FIFO credits, CPU/DMA full stall, packed commands, transport order, power and reset (%0d records)", delivered);
        $finish;
    end
    initial begin #1000000; $fatal(1, "watchdog"); end
endmodule
