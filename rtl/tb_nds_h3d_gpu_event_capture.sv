module tb_nds_h3d_gpu_event_capture;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;
    logic write_valid, write_ready, cpu_is_arm9, write_not_read;
    logic [27:0] io_address;
    logic [1:0] access_width;
    logic [3:0] byte_enable;
    logic [31:0] write_data, frame;
    logic [63:0] timestamp;
    logic event_valid, event_ready;
    logic [31:0] event_address, event_data, event_frame;
    logic [7:0] event_type;
    logic event_cpu;
    logic [1:0] event_width;
    logic [3:0] event_byte_enable;
    logic [16:0] event_flags;
    logic [63:0] event_timestamp;

    nds_h3d_gpu_event_capture dut (.*);

    task automatic check_hit(
        input logic [27:0] aligned_address,
        input logic [27:0] expected_address,
        input logic [1:0] width,
        input logic [3:0] be
    );
        begin
            @(negedge clk);
            io_address = aligned_address;
            access_width = width;
            byte_enable = be;
            write_valid = 1'b1;
            event_ready = 1'b0;
            #1;
            if (write_ready)
                $fatal(1, "normalizer hid backpressure at %08x",
                    expected_address);
            if (!event_valid ||
                event_address !==
                    ({4'h0,expected_address} | 32'h04000000) ||
                event_data !== write_data || event_frame !== frame ||
                event_width !== width || event_byte_enable !== be ||
                event_timestamp !== timestamp)
                $fatal(1, "fresh write did not fall through at %08x",
                    expected_address);
            repeat (2) @(posedge clk);
            @(negedge clk);
            #1;
            if (!event_valid ||
                event_address !==
                    ({4'h0,expected_address} | 32'h04000000) ||
                event_data !== write_data || event_frame !== frame ||
                event_type !== 8'd1 || event_cpu !== 1'b0 ||
                event_width !== width || event_byte_enable !== be ||
                event_flags !== 0 || event_timestamp !== timestamp)
                $fatal(1, "held write changed at %08x", expected_address);
            event_ready = 1'b1;
            #1;
            if (!write_ready || !event_valid)
                $fatal(1, "held write did not retire at %08x",
                    expected_address);
            @(posedge clk);
            @(negedge clk);
            write_valid = 1'b0;
            #1;
            if (event_valid)
                $fatal(1, "event did not retire at %08x", expected_address);
            event_ready = 1'b0;
        end
    endtask

    task automatic check_miss(input logic [27:0] address);
        begin
            @(negedge clk);
            io_address = address;
            write_valid = 1'b1;
            event_ready = 1'b0;
            #1;
            if (event_valid || !write_ready)
                $fatal(1, "unrelated write was captured at %08x", address);
            @(posedge clk);
            @(negedge clk);
            write_valid = 1'b0;
        end
    endtask

    initial begin
        write_valid = 1'b0;
        cpu_is_arm9 = 1'b1;
        write_not_read = 1'b1;
        write_data = 32'h89abcdef;
        frame = 32'h12345678;
        timestamp = 64'h0123456789abcdef;
        event_ready = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        check_hit(28'h0000060, 28'h0000060, 2'd1, 4'b0011);
        check_hit(28'h0000248, 28'h0000249, 2'd0, 4'b0010);
        check_hit(28'h0000304, 28'h0000304, 2'd2, 4'b1111);
        check_hit(28'h0000320, 28'h0000320, 2'd1, 4'b0011);
        check_hit(28'h00003bc, 28'h00003bf, 2'd0, 4'b1000);
        check_hit(28'h0000400, 28'h0000400, 2'd2, 4'b1111);
        check_hit(28'h00005c8, 28'h00005cb, 2'd0, 4'b1000);
        check_hit(28'h0000600, 28'h0000600, 2'd2, 4'b1111);
        check_hit(28'h0000610, 28'h0000613, 2'd0, 4'b1000);

        check_miss(28'h000005c);
        check_miss(28'h0000064);
        check_miss(28'h000023f);
        check_miss(28'h000024a);
        check_miss(28'h0000300);
        check_miss(28'h0000308);
        check_miss(28'h000031f);
        check_miss(28'h00003c0);
        check_miss(28'h00003ff);
        check_miss(28'h00005cc);
        check_miss(28'h00005ff);
        check_miss(28'h0000614);

        @(negedge clk);
        write_valid = 1'b1;
        io_address = 28'h0000400;
        cpu_is_arm9 = 1'b0;
        #1;
        if (event_valid || !write_ready) $fatal(1, "ARM7 sound write captured");
        cpu_is_arm9 = 1'b1;
        write_not_read = 1'b0;
        #1;
        if (event_valid || !write_ready) $fatal(1, "GPU read captured");
        write_not_read = 1'b1;
        write_valid = 1'b0;
        #1;
        if (event_valid) $fatal(1, "idle cycle captured");

        // With an accepting sink, the normalized event is consumed directly
        // and must not appear again as a registered copy.
        @(negedge clk);
        io_address = 28'h0000248;
        access_width = 2'd0;
        byte_enable = 4'b0010;
        write_data = 32'h0000aa00;
        frame = 32'd54;
        timestamp = 64'd99;
        write_valid = 1'b1;
        event_ready = 1'b1;
        #1;
        if (!event_valid || !write_ready ||
            event_address !== 32'h04000249)
            $fatal(1, "accepting fall-through path was not live");
        @(posedge clk);
        @(negedge clk);
        write_valid = 1'b0;
        #1;
        if (event_valid)
            $fatal(1, "fall-through event was stored and duplicated");
        event_ready = 1'b0;

        // The upstream console gate owns the one elastic slot.  This
        // normalizer must propagate backpressure rather than accepting a
        // second hidden copy that a later frame boundary could overtake.
        cpu_is_arm9 = 1'b1;
        write_not_read = 1'b1;
        io_address = 28'h0000400;
        access_width = 2'd2;
        byte_enable = 4'hf;
        write_data = 32'h11112222;
        frame = 32'd55;
        timestamp = 64'd100;
        write_valid = 1'b1;
        event_ready = 1'b0;
        #1;
        if (write_ready || !event_valid || event_data !== 32'h11112222)
            $fatal(1, "blocked write was accepted or hidden");
        repeat (3) @(posedge clk);
        @(negedge clk);
        #1;
        if (write_ready || !event_valid || event_data !== 32'h11112222 ||
            event_frame !== 55 || event_timestamp !== 100)
            $fatal(1, "blocked write was not held by upstream contract");
        event_ready = 1'b1;
        #1;
        if (!write_ready || !event_valid)
            $fatal(1, "blocked write did not resume");
        @(posedge clk);
        @(negedge clk);
        write_valid = 1'b0;
        write_data = 32'h33334444;
        frame = 32'd56;
        timestamp = 64'd101;
        #1;
        if (event_valid)
            $fatal(1, "retired write was duplicated");

        // The following transaction is accepted only after the older one.
        write_valid = 1'b1;
        #1;
        if (!write_ready || !event_valid ||
            event_data !== 32'h33334444 || event_frame !== 56 ||
            event_timestamp !== 101)
            $fatal(1, "next write did not follow the retired write");
        @(posedge clk);
        @(negedge clk);
        write_valid = 1'b0;
        #1;
        if (event_valid) $fatal(1, "next write was duplicated");

        $display("H3D_GPU_EVENT_CAPTURE_PASS");
        $finish;
    end
endmodule
