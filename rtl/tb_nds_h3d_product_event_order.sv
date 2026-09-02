`timescale 1ns/1ps

// Composed product-chain regression for the H3D GPU normalizer and global
// ordered queue. The normalizer must be fall-through when ready and propagate
// backpressure when blocked; an independent skid would let a frame boundary
// pass a second, older GPU record held by the upstream console gate.
module tb_nds_h3d_product_event_order;
    logic source_clk = 1'b0;
    logic ddr_clk = 1'b0;
    always #5 source_clk = ~source_clk;
    always #7 ddr_clk = ~ddr_clk;

    logic reset = 1'b1;
    logic session_flush = 1'b0;

    logic write_valid;
    logic write_ready;
    logic [27:0] io_address;
    logic [1:0] access_width;
    logic [3:0] byte_enable;
    logic [31:0] write_data;
    logic [31:0] gpu_frame;
    logic [63:0] gpu_timestamp;

    logic gpu_valid;
    logic gpu_ready;
    logic [31:0] gpu_address;
    logic [31:0] gpu_data;
    logic [31:0] gpu_event_frame;
    logic [7:0] gpu_event_type;
    logic gpu_event_cpu;
    logic [1:0] gpu_width;
    logic [3:0] gpu_be;
    logic [16:0] gpu_flags;
    logic [63:0] gpu_event_timestamp;

    logic arm9_valid;
    logic arm9_ready;
    logic [31:0] arm9_address;
    logic [31:0] arm9_data;
    logic [31:0] arm9_frame;
    logic [1:0] arm9_width;
    logic [3:0] arm9_be;
    logic [63:0] arm9_timestamp;

    logic arm7_valid;
    logic arm7_ready;
    logic [31:0] arm7_address;
    logic [31:0] arm7_data;
    logic [31:0] arm7_frame;
    logic [1:0] arm7_width;
    logic [3:0] arm7_be;
    logic [63:0] arm7_timestamp;

    logic frame_valid;
    logic frame_ready;
    logic [31:0] frame_number;
    logic [63:0] frame_timestamp;

    logic source_active;
    logic ddr_active;
    logic source_fault;
    logic ddr_fault;
    logic queue_fault;
    logic [2:0] source_occupancy;

    logic event_valid;
    logic event_ready = 1'b1;
    logic [31:0] event_address;
    logic [31:0] event_data;
    logic [31:0] event_frame;
    logic [7:0] event_type;
    logic event_cpu;
    logic [1:0] event_width;
    logic [3:0] event_be;
    logic [16:0] event_flags;
    logic [63:0] event_timestamp;
    logic [31:0] event_sequence;

    nds_h3d_gpu_event_capture gpu_capture (
        .clk(source_clk),
        .reset(reset),
        .write_valid(write_valid),
        .write_ready(write_ready),
        .cpu_is_arm9(1'b1),
        .write_not_read(1'b1),
        .io_address(io_address),
        .access_width(access_width),
        .byte_enable(byte_enable),
        .write_data(write_data),
        .frame(gpu_frame),
        .timestamp(gpu_timestamp),
        .event_valid(gpu_valid),
        .event_ready(gpu_ready),
        .event_address(gpu_address),
        .event_data(gpu_data),
        .event_frame(gpu_event_frame),
        .event_type(gpu_event_type),
        .event_cpu(gpu_event_cpu),
        .event_width(gpu_width),
        .event_byte_enable(gpu_be),
        .event_flags(gpu_flags),
        .event_timestamp(gpu_event_timestamp)
    );

    nds_h3d_event_queue_cdc event_queue (
        .source_clk(source_clk),
        .ddr_clk(ddr_clk),
        .reset(reset),
        .session_flush(session_flush),
        .gpu_valid(gpu_valid),
        .gpu_ready(gpu_ready),
        .gpu_address(gpu_address),
        .gpu_data(gpu_data),
        .gpu_frame(gpu_event_frame),
        .gpu_width(gpu_width),
        .gpu_byte_enable(gpu_be),
        .gpu_flags(gpu_flags),
        .gpu_timestamp(gpu_event_timestamp),
        .arm9_vram_valid(arm9_valid),
        .arm9_vram_ready(arm9_ready),
        .arm9_vram_address(arm9_address),
        .arm9_vram_data(arm9_data),
        .arm9_vram_frame(arm9_frame),
        .arm9_vram_width(arm9_width),
        .arm9_vram_byte_enable(arm9_be),
        .arm9_vram_flags(17'd0),
        .arm9_vram_timestamp(arm9_timestamp),
        .arm7_vram_valid(arm7_valid),
        .arm7_vram_ready(arm7_ready),
        .arm7_vram_address(arm7_address),
        .arm7_vram_data(arm7_data),
        .arm7_vram_frame(arm7_frame),
        .arm7_vram_width(arm7_width),
        .arm7_vram_byte_enable(arm7_be),
        .arm7_vram_flags(17'd0),
        .arm7_vram_timestamp(arm7_timestamp),
        .frame_valid(frame_valid),
        .frame_ready(frame_ready),
        .frame_number(frame_number),
        .frame_flags(17'd0),
        .frame_timestamp(frame_timestamp),
        .source_active(source_active),
        .ddr_active(ddr_active),
        .source_fault(source_fault),
        .ddr_fault(ddr_fault),
        .fault(queue_fault),
        .source_occupancy(source_occupancy),
        .event_valid(event_valid),
        .event_ready(event_ready),
        .event_address(event_address),
        .event_data(event_data),
        .event_frame(event_frame),
        .event_type(event_type),
        .event_cpu(event_cpu),
        .event_width(event_width),
        .event_byte_enable(event_be),
        .event_flags(event_flags),
        .event_timestamp(event_timestamp),
        .event_sequence(event_sequence)
    );

    task automatic expect_event(
        input logic [31:0] expected_sequence,
        input logic [7:0] expected_type,
        input logic [31:0] expected_address,
        input logic [31:0] expected_frame,
        input logic expected_cpu,
        input logic [63:0] expected_timestamp
    );
        integer guard;
        begin
            guard = 0;
            do begin
                @(posedge ddr_clk);
                guard = guard + 1;
                if (guard > 200)
                    $fatal(1, "timeout waiting for event sequence %0d",
                        expected_sequence);
            end while (!event_valid);
            if (event_sequence !== expected_sequence ||
                event_type !== expected_type ||
                event_address !== expected_address ||
                event_frame !== expected_frame || event_cpu !== expected_cpu ||
                event_timestamp !== expected_timestamp)
                $fatal(1,
                    "event mismatch got seq=%0d type=%0d addr=%08x frame=%0d cpu=%0d expected seq=%0d type=%0d addr=%08x frame=%0d cpu=%0d",
                    event_sequence, event_type, event_address, event_frame,
                    event_cpu, expected_sequence, expected_type,
                    expected_address, expected_frame, expected_cpu);
        end
    endtask

    task automatic clear_sources;
        begin
            write_valid = 1'b0;
            arm9_valid = 1'b0;
            arm7_valid = 1'b0;
            frame_valid = 1'b0;
        end
    endtask

    initial begin
        clear_sources();
        io_address = 28'd0;
        access_width = 2'd2;
        byte_enable = 4'hf;
        write_data = 32'd0;
        gpu_frame = 32'd0;
        gpu_timestamp = 64'd0;
        arm9_address = 32'd0;
        arm9_data = 32'd0;
        arm9_frame = 32'd0;
        arm9_width = 2'd2;
        arm9_be = 4'hf;
        arm9_timestamp = 64'd0;
        arm7_address = 32'd0;
        arm7_data = 32'd0;
        arm7_frame = 32'd0;
        arm7_width = 2'd1;
        arm7_be = 4'h3;
        arm7_timestamp = 64'd0;
        frame_number = 32'd0;
        frame_timestamp = 64'd0;

        repeat (4) @(posedge source_clk);
        reset = 1'b0;
        wait (source_active && ddr_active);
        repeat (2) @(posedge source_clk);

        // Empty capture, accepting queue: GPU and frame are fresh on the same
        // edge. The normalized GPU byte write must receive sequence 1.
        @(negedge source_clk);
        io_address = 28'h0000248;
        access_width = 2'd0;
        byte_enable = 4'b0010;
        write_data = 32'h0000aa00;
        gpu_frame = 32'd9;
        gpu_timestamp = 64'd90;
        frame_number = 32'd9;
        frame_timestamp = 64'd91;
        write_valid = 1'b1;
        frame_valid = 1'b1;
        #1;
        if (!gpu_valid || !write_ready || !gpu_ready || !frame_ready ||
            gpu_address !== 32'h04000249)
            $fatal(1, "fresh GPU+frame batch did not fall through atomically");
        @(posedge source_clk);
        @(negedge source_clk);
        write_valid = 1'b0;
        frame_valid = 1'b0;

        expect_event(32'd1, 8'd1, 32'h04000249, 32'd9, 1'b0, 64'd90);
        expect_event(32'd2, 8'd4, 32'd0, 32'd9, 1'b0, 64'd91);

        wait (source_occupancy == 0);
        repeat (4) @(posedge source_clk);

        // Empty capture, accepting queue: simultaneous GPU, ARM9 VRAM, and
        // ARM7 VRAM must be assigned the queue's fixed 1/2/3 order.
        @(negedge source_clk);
        io_address = 28'h00003bc;
        access_width = 2'd0;
        byte_enable = 4'b1000;
        write_data = 32'hbb000000;
        gpu_frame = 32'd10;
        gpu_timestamp = 64'd100;
        arm9_address = 32'h06001000;
        arm9_data = 32'h11223344;
        arm9_frame = 32'd10;
        arm9_timestamp = 64'd100;
        arm7_address = 32'h06002000;
        arm7_data = 32'h000055aa;
        arm7_frame = 32'd10;
        arm7_timestamp = 64'd100;
        write_valid = 1'b1;
        arm9_valid = 1'b1;
        arm7_valid = 1'b1;
        #1;
        if (!gpu_valid || !write_ready || !gpu_ready ||
            !arm9_ready || !arm7_ready || gpu_address !== 32'h040003bf)
            $fatal(1, "fresh GPU+VRAM batch did not fall through atomically");
        @(posedge source_clk);
        @(negedge source_clk);
        write_valid = 1'b0;
        arm9_valid = 1'b0;
        arm7_valid = 1'b0;

        expect_event(32'd3, 8'd1, 32'h040003bf, 32'd10, 1'b0, 64'd100);
        expect_event(32'd4, 8'd2, 32'h06001000, 32'd10, 1'b0, 64'd100);
        expect_event(32'd5, 8'd3, 32'h06002000, 32'd10, 1'b1, 64'd100);

        repeat (12) begin
            @(posedge ddr_clk);
            if (event_valid)
                $fatal(1, "composed chain duplicated an accepted batch");
        end
        if (source_fault || ddr_fault || queue_fault)
            $fatal(1, "composed chain raised a protocol fault");

        // Reset the complete chain, then present GPU+frame before the queue's
        // cross-domain release handshake. Backpressure must propagate through
        // the stateless normalizer, leaving both records held upstream until
        // they can enter one atomic GPU-before-frame batch. An independent GPU
        // skid here is the frame/older-command inversion seen on hardware.
        reset = 1'b1;
        repeat (3) @(posedge source_clk);
        clear_sources();
        reset = 1'b0;
        @(negedge source_clk);
        io_address = 28'h0000400;
        access_width = 2'd2;
        byte_enable = 4'hf;
        write_data = 32'hdeadbeef;
        gpu_frame = 32'd11;
        gpu_timestamp = 64'd110;
        frame_number = 32'd11;
        frame_timestamp = 64'd111;
        write_valid = 1'b1;
        frame_valid = 1'b1;
        #1;
        if (write_ready || gpu_ready || frame_ready)
            $fatal(1, "inactive queue did not backpressure the atomic batch");
        repeat (3) @(posedge source_clk);
        @(negedge source_clk);
        #1;
        if (write_ready || !gpu_valid || gpu_data !== 32'hdeadbeef ||
            gpu_event_timestamp !== 64'd110)
            $fatal(1, "GPU backpressure was not propagated upstream");
        wait (frame_ready);
        #1;
        if (!write_ready || !gpu_ready)
            $fatal(1, "held GPU did not join the released frame batch");
        @(posedge source_clk);
        @(negedge source_clk);
        write_valid = 1'b0;
        frame_valid = 1'b0;

        expect_event(32'd1, 8'd1, 32'h04000400, 32'd11, 1'b0, 64'd110);
        expect_event(32'd2, 8'd4, 32'd0, 32'd11, 1'b0, 64'd111);
        repeat (8) begin
            @(posedge ddr_clk);
            if (event_valid)
                $fatal(1, "stored atomic batch was emitted more than once");
        end

        $display("H3D_PRODUCT_EVENT_ORDER_PASS");
        $finish;
    end
endmodule
