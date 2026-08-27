`timescale 1ns/1ps

module tb_nds_h3d_event_queue_cdc;
    localparam integer LOCAL_DEPTH = 4;
    localparam integer ASYNC_LGDEPTH = 4;
    localparam integer EVENT_WIDTH = 192;
    localparam integer MAX_EXPECTED = 20000;

    logic source_clk = 0;
    logic ddr_clk = 0;
    logic source_clock_enable = 1;
    logic ddr_clock_enable = 1;
    always begin
        #7;
        if (source_clock_enable) source_clk = ~source_clk;
    end
    initial begin
        #2;
        forever begin
            #11;
            if (ddr_clock_enable) ddr_clk = ~ddr_clk;
        end
    end

    logic reset = 1;
    logic session_flush = 0;

    logic gpu_valid = 0;
    logic gpu_ready;
    logic [31:0] gpu_address = 0;
    logic [31:0] gpu_data = 0;
    logic [31:0] gpu_frame = 0;
    logic [1:0] gpu_width = 0;
    logic [3:0] gpu_byte_enable = 0;
    logic [16:0] gpu_flags = 0;
    logic [63:0] gpu_timestamp = 0;

    logic arm9_vram_valid = 0;
    logic arm9_vram_ready;
    logic [31:0] arm9_vram_address = 0;
    logic [31:0] arm9_vram_data = 0;
    logic [31:0] arm9_vram_frame = 0;
    logic [1:0] arm9_vram_width = 0;
    logic [3:0] arm9_vram_byte_enable = 0;
    logic [16:0] arm9_vram_flags = 0;
    logic [63:0] arm9_vram_timestamp = 0;

    logic arm7_vram_valid = 0;
    logic arm7_vram_ready;
    logic [31:0] arm7_vram_address = 0;
    logic [31:0] arm7_vram_data = 0;
    logic [31:0] arm7_vram_frame = 0;
    logic [1:0] arm7_vram_width = 0;
    logic [3:0] arm7_vram_byte_enable = 0;
    logic [16:0] arm7_vram_flags = 0;
    logic [63:0] arm7_vram_timestamp = 0;

    logic frame_valid = 0;
    logic frame_ready;
    logic [31:0] frame_number = 0;
    logic [16:0] frame_flags = 0;
    logic [63:0] frame_timestamp = 0;

    logic source_active;
    logic ddr_active;
    logic source_fault;
    logic ddr_fault;
    logic fault;
    logic [$clog2(LOCAL_DEPTH + 1)-1:0] source_occupancy;

    logic event_valid;
    logic event_ready = 0;
    logic [31:0] event_address;
    logic [31:0] event_data;
    logic [31:0] event_frame;
    logic [7:0] event_type;
    logic event_cpu;
    logic [1:0] event_width;
    logic [3:0] event_byte_enable;
    logic [16:0] event_flags;
    logic [63:0] event_timestamp;
    logic [31:0] event_sequence;

    nds_h3d_event_queue_cdc #(
        .LOCAL_DEPTH(LOCAL_DEPTH),
        .ASYNC_LGDEPTH(ASYNC_LGDEPTH)
    ) dut (.*);

    function automatic logic [EVENT_WIDTH-1:0] pack_event(
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [31:0] frame,
        input logic [7:0] kind,
        input logic arm7,
        input logic [1:0] width,
        input logic [3:0] byte_enable,
        input logic [16:0] flags,
        input logic [63:0] timestamp
    );
        pack_event = {
            timestamp, flags, byte_enable, width, arm7, kind,
            frame, data, address
        };
    endfunction

    wire [EVENT_WIDTH-1:0] observed_event = {
        event_timestamp, event_flags, event_byte_enable, event_width,
        event_cpu, event_type, event_frame, event_data, event_address
    };
    logic [EVENT_WIDTH-1:0] expected [0:MAX_EXPECTED-1];
    integer expected_head = 0;
    integer expected_tail = 0;
    integer epoch_inputs = 0;
    integer epoch_outputs = 0;
    integer total_inputs = 0;
    integer total_outputs = 0;
    integer source_batches = 0;
    integer four_source_batches = 0;
    integer backpressure_cycles = 0;
    integer capacity_high_water = 0;
    integer epoch_number = 0;
    logic scoreboard_enabled = 0;
    logic output_stalled = 0;
    logic [EVENT_WIDTH-1:0] stalled_output_payload = 0;
    logic [31:0] stalled_output_sequence = 0;

    task automatic discard_epoch;
        begin
            scoreboard_enabled = 0;
            expected_head = expected_tail;
            epoch_inputs = 0;
            epoch_outputs = 0;
        end
    endtask

    task automatic start_epoch;
        begin
            wait (source_active && ddr_active);
            repeat (3) @(posedge source_clk);
            epoch_number = epoch_number + 1;
            epoch_inputs = 0;
            epoch_outputs = 0;
            scoreboard_enabled = 1;
        end
    endtask

    task automatic set_gpu(input integer identifier);
        begin
            gpu_address = 32'h04000400 + identifier * 4;
            gpu_data = 32'h10000000 ^ identifier;
            gpu_frame = 32'h01000000 + identifier;
            gpu_width = identifier[1:0];
            gpu_byte_enable = 4'b0001 << identifier[1:0];
            gpu_flags = 17'h10000 ^ identifier[16:0];
            gpu_timestamp = 64'h1100000000000000 + identifier;
            gpu_valid = 1;
        end
    endtask

    task automatic set_arm9(input integer identifier);
        begin
            arm9_vram_address = 32'h06000000 + identifier * 4;
            arm9_vram_data = 32'h20000000 ^ identifier;
            arm9_vram_frame = 32'h02000000 + identifier;
            arm9_vram_width = identifier[1:0];
            arm9_vram_byte_enable = 4'b0011 << identifier[0];
            arm9_vram_flags = 17'h08000 ^ identifier[16:0];
            arm9_vram_timestamp = 64'h2200000000000000 + identifier;
            arm9_vram_valid = 1;
        end
    endtask

    task automatic set_arm7(input integer identifier);
        begin
            arm7_vram_address = 32'h06080000 + identifier * 4;
            arm7_vram_data = 32'h30000000 ^ identifier;
            arm7_vram_frame = 32'h03000000 + identifier;
            arm7_vram_width = identifier[1:0];
            arm7_vram_byte_enable = 4'b1100 >> identifier[0];
            arm7_vram_flags = 17'h04000 ^ identifier[16:0];
            arm7_vram_timestamp = 64'h3300000000000000 + identifier;
            arm7_vram_valid = 1;
        end
    endtask

    task automatic set_frame(input integer identifier);
        begin
            frame_number = 32'h04000000 + identifier;
            frame_flags = 17'h02000 ^ identifier[16:0];
            frame_timestamp = 64'h4400000000000000 + identifier;
            frame_valid = 1;
        end
    endtask

    task automatic wait_all_inputs_idle;
        begin
            while (gpu_valid || arm9_vram_valid ||
                arm7_vram_valid || frame_valid)
                @(negedge source_clk);
        end
    endtask

    task automatic wait_epoch_drained;
        integer timeout;
        begin
            timeout = 0;
            event_ready = 1;
            while (epoch_outputs != epoch_inputs || event_valid ||
                source_occupancy != 0) begin
                @(posedge ddr_clk);
                #1;
                timeout = timeout + 1;
                if (timeout > 20000)
                    $fatal(1,
                        "epoch drain timeout in=%0d out=%0d occupancy=%0d",
                        epoch_inputs, epoch_outputs, source_occupancy);
            end
            repeat (6) @(posedge ddr_clk);
        end
    endtask

    logic gpu_accepted = 0;
    logic arm9_accepted = 0;
    logic arm7_accepted = 0;
    logic frame_accepted = 0;
    integer next_identifier = 1;
    logic random_sources = 0;
    logic random_sink = 0;

    always @(posedge source_clk) begin
        integer batch_size;
        batch_size = 0;
        gpu_accepted <= gpu_valid && gpu_ready;
        arm9_accepted <= arm9_vram_valid && arm9_vram_ready;
        arm7_accepted <= arm7_vram_valid && arm7_vram_ready;
        frame_accepted <= frame_valid && frame_ready;

        if (scoreboard_enabled && !reset && !session_flush) begin
            if (gpu_valid && gpu_ready) begin
                expected[expected_tail] = pack_event(
                    gpu_address, gpu_data, gpu_frame, 8'd1, 1'b0,
                    gpu_width, gpu_byte_enable, gpu_flags, gpu_timestamp);
                expected_tail = expected_tail + 1;
                batch_size = batch_size + 1;
            end
            if (arm9_vram_valid && arm9_vram_ready) begin
                expected[expected_tail] = pack_event(
                    arm9_vram_address, arm9_vram_data, arm9_vram_frame,
                    8'd2, 1'b0, arm9_vram_width,
                    arm9_vram_byte_enable, arm9_vram_flags,
                    arm9_vram_timestamp);
                expected_tail = expected_tail + 1;
                batch_size = batch_size + 1;
            end
            if (arm7_vram_valid && arm7_vram_ready) begin
                expected[expected_tail] = pack_event(
                    arm7_vram_address, arm7_vram_data, arm7_vram_frame,
                    8'd3, 1'b1, arm7_vram_width,
                    arm7_vram_byte_enable, arm7_vram_flags,
                    arm7_vram_timestamp);
                expected_tail = expected_tail + 1;
                batch_size = batch_size + 1;
            end
            if (frame_valid && frame_ready) begin
                expected[expected_tail] = pack_event(
                    32'd0, 32'd0, frame_number, 8'd4, 1'b0,
                    2'd0, 4'd0, frame_flags, frame_timestamp);
                expected_tail = expected_tail + 1;
                batch_size = batch_size + 1;
            end
            if (batch_size != 0) begin
                epoch_inputs = epoch_inputs + batch_size;
                total_inputs = total_inputs + batch_size;
                source_batches = source_batches + 1;
                if (batch_size == 4)
                    four_source_batches = four_source_batches + 1;
            end
            if ((gpu_valid || arm9_vram_valid || arm7_vram_valid ||
                frame_valid) && !gpu_ready)
                backpressure_cycles = backpressure_cycles + 1;
            if (source_occupancy > capacity_high_water)
                capacity_high_water = source_occupancy;
        end
    end

    // Producers change only on the falling edge and retain all payload until
    // the registered handshake pulse from the preceding rising edge.
    always @(negedge source_clk) begin
        if (reset || session_flush) begin
            gpu_valid = 0;
            arm9_vram_valid = 0;
            arm7_vram_valid = 0;
            frame_valid = 0;
        end else begin
            if (gpu_accepted) gpu_valid = 0;
            if (arm9_accepted) arm9_vram_valid = 0;
            if (arm7_accepted) arm7_vram_valid = 0;
            if (frame_accepted) frame_valid = 0;

            if (random_sources && source_active) begin
                if (!gpu_valid && $urandom_range(0, 2) != 0) begin
                    set_gpu(next_identifier);
                    next_identifier = next_identifier + 1;
                end
                if (!arm9_vram_valid && $urandom_range(0, 2) != 0) begin
                    set_arm9(next_identifier);
                    next_identifier = next_identifier + 1;
                end
                if (!arm7_vram_valid && $urandom_range(0, 3) != 0) begin
                    set_arm7(next_identifier);
                    next_identifier = next_identifier + 1;
                end
                if (!frame_valid && $urandom_range(0, 5) == 0) begin
                    set_frame(next_identifier);
                    next_identifier = next_identifier + 1;
                end
            end
        end
    end

    always @(negedge ddr_clk) begin
        if (reset || session_flush)
            event_ready = 0;
        else if (random_sink)
            event_ready = $urandom_range(0, 3) != 0;
    end

    always @(posedge ddr_clk) begin
        if (reset || session_flush || fault) begin
            output_stalled <= 0;
        end else begin
            if (output_stalled &&
                (!event_valid ||
                 observed_event !== stalled_output_payload ||
                 event_sequence !== stalled_output_sequence))
                $fatal(1, "DDR output changed while backpressured");
            if (event_valid && !event_ready && !output_stalled) begin
                output_stalled <= 1;
                stalled_output_payload <= observed_event;
                stalled_output_sequence <= event_sequence;
            end else if (event_valid && event_ready) begin
                output_stalled <= 0;
            end
        end

        if (scoreboard_enabled && event_valid && event_ready) begin
            if (expected_head >= expected_tail)
                $fatal(1, "DDR emitted an event with an empty scoreboard");
            if (observed_event !== expected[expected_head])
                $fatal(1,
                    "event %0d mismatch got=%h expected=%h",
                    epoch_outputs + 1, observed_event,
                    expected[expected_head]);
            if (event_sequence !== epoch_outputs + 1)
                $fatal(1,
                    "sequence got %0d expected %0d",
                    event_sequence, epoch_outputs + 1);
            expected_head = expected_head + 1;
            epoch_outputs = epoch_outputs + 1;
            total_outputs = total_outputs + 1;
        end
        if ((!ddr_active || ddr_fault) && event_valid)
            $fatal(1, "event remained valid while queue failed closed");
    end

    initial begin
        integer index;
        integer timeout;
        integer accepted_before;

        repeat (5) @(posedge source_clk);
        #3;
        reset = 0;
        start_epoch();

        // Reset release with the DDR clock stopped: the source reset pipeline
        // may release, but the remote-up handshake must keep every ready low,
        // local occupancy zero, and both async FIFO pointers stationary.
        discard_epoch();
        #3;
        reset = 1;
        #20;
        ddr_clock_enable = 0;
        #20;
        reset = 0;
        repeat (10) @(posedge source_clk);
        if (source_active || ddr_active || gpu_ready || arm9_vram_ready ||
            arm7_vram_ready || frame_ready || source_occupancy != 0 ||
            dut.crossing.write_binary != 0 ||
            dut.crossing.read_binary != 0)
            $fatal(1,
                "source ran before stopped DDR domain observed reset release");
        ddr_clock_enable = 1;
        start_epoch();

        // Mirror the skew with the source clock stopped.  The DDR side must
        // not expose a stale event or move its read pointer.
        discard_epoch();
        #5;
        reset = 1;
        #30;
        source_clock_enable = 0;
        #22;
        reset = 0;
        repeat (10) @(posedge ddr_clk);
        if (source_active || ddr_active || event_valid ||
            dut.crossing.write_binary != 0 ||
            dut.crossing.read_binary != 0)
            $fatal(1,
                "DDR ran before stopped source domain observed reset release");
        source_clock_enable = 1;
        start_epoch();

        // Exact same-edge ordering: all four inputs enter one atomic batch.
        @(negedge source_clk);
        set_gpu(1);
        set_arm9(2);
        set_arm7(3);
        set_frame(4);
        wait_all_inputs_idle();
        wait_epoch_drained();
        if (four_source_batches != 1 || epoch_inputs != 4)
            $fatal(1, "four-source atomic batch was not accepted exactly");

        // Fill the async FIFO, then fill the local queue with exactly three
        // non-frame entries.  The fourth local slot must remain available
        // for a frame and unavailable to a non-frame event.
        event_ready = 0;
        for (index = 0; index < 16; index = index + 1) begin
            @(negedge source_clk);
            set_gpu(100 + index);
            wait_all_inputs_idle();
        end
        timeout = 0;
        while (dut.async_write_ready && timeout < 1000) begin
            @(posedge source_clk);
            timeout = timeout + 1;
        end
        if (dut.async_write_ready)
            $fatal(1, "async FIFO did not reach exact full capacity");
        for (index = 0; index < LOCAL_DEPTH - 1; index = index + 1) begin
            @(negedge source_clk);
            set_gpu(200 + index);
            wait_all_inputs_idle();
        end
        repeat (2) @(posedge source_clk);
        if (source_occupancy != LOCAL_DEPTH - 1)
            $fatal(1,
                "local queue count got %0d expected reserved depth %0d",
                source_occupancy, LOCAL_DEPTH - 1);
        @(negedge source_clk);
        if (gpu_ready || !frame_ready)
            $fatal(1, "frame reservation ready signals are wrong");
        set_frame(300);
        wait_all_inputs_idle();
        repeat (2) @(posedge source_clk);
        if (source_occupancy != LOCAL_DEPTH)
            $fatal(1, "reserved frame did not consume final local slot");
        wait_epoch_drained();

        // Long randomized run crosses both pointer wraps many times and holds
        // every source through independent source and sink backpressure.
        random_sources = 1;
        random_sink = 1;
        repeat (2500) @(posedge source_clk);
        random_sources = 0;
        wait_all_inputs_idle();
        random_sink = 0;
        event_ready = 1;
        wait_epoch_drained();
        if (epoch_inputs < 1000 || four_source_batches < 20)
            $fatal(1,
                "random run was too weak inputs=%0d four_batches=%0d",
                epoch_inputs, four_source_batches);

        // Accept records, then asynchronously flush between both clock edges.
        event_ready = 0;
        for (index = 0; index < 10; index = index + 1) begin
            @(negedge source_clk);
            set_arm9(2000 + index);
            wait_all_inputs_idle();
        end
        if (epoch_inputs == epoch_outputs)
            $fatal(1, "flush test did not leave queued records");
        #3;
        discard_epoch();
        session_flush = 1;
        #37;
        session_flush = 0;
        start_epoch();
        if (event_valid || source_occupancy != 0 || fault)
            $fatal(1, "session flush left stale queue state");
        @(negedge source_clk);
        set_frame(3000);
        wait_all_inputs_idle();
        wait_epoch_drained();
        if (epoch_inputs != 1 || epoch_outputs != 1)
            $fatal(1, "post-flush sequence did not restart cleanly");

        // Fill all physical capacity again, then deliberately violate the
        // stalled-frame contract.  The violation must stick and suppress DDR
        // output until a session flush recovers both domains.
        event_ready = 0;
        for (index = 0; index < 16; index = index + 1) begin
            @(negedge source_clk);
            set_gpu(4000 + index);
            wait_all_inputs_idle();
        end
        wait (!dut.async_write_ready);
        for (index = 0; index < LOCAL_DEPTH - 1; index = index + 1) begin
            @(negedge source_clk);
            set_arm7(5000 + index);
            wait_all_inputs_idle();
        end
        @(negedge source_clk);
        set_frame(6000);
        wait_all_inputs_idle();
        repeat (2) @(posedge source_clk);
        if (source_occupancy != LOCAL_DEPTH)
            $fatal(1, "fault test did not fill total local capacity");
        @(negedge source_clk);
        set_frame(6001);
        @(posedge source_clk);
        #1;
        if (frame_ready)
            $fatal(1, "full queue unexpectedly accepted violation frame");
        @(negedge source_clk);
        frame_valid = 0;
        repeat (3) @(posedge source_clk);
        if (!source_fault || !fault || source_active ||
            gpu_ready || arm9_vram_ready || arm7_vram_ready || frame_ready)
            $fatal(1, "source protocol violation did not fail closed");
        repeat (5) @(posedge ddr_clk);
        if (!ddr_fault || ddr_active || event_valid)
            $fatal(1, "source fault did not stop DDR-domain output");

        #5;
        discard_epoch();
        session_flush = 1;
        #41;
        session_flush = 0;
        start_epoch();
        if (fault || source_occupancy != 0 || event_valid)
            $fatal(1, "flush did not recover sticky queue fault");
        accepted_before = total_outputs;
        @(negedge source_clk);
        set_gpu(7000);
        set_arm9(7001);
        set_arm7(7002);
        set_frame(7003);
        wait_all_inputs_idle();
        wait_epoch_drained();
        if (total_outputs != accepted_before + 4)
            $fatal(1, "post-fault recovery lost ordered events");

        if (expected_head != expected_tail)
            $fatal(1, "final expected scoreboard did not drain");
        if (backpressure_cycles == 0 ||
            capacity_high_water != LOCAL_DEPTH)
            $fatal(1,
                "capacity/backpressure coverage missing bp=%0d high=%0d",
                backpressure_cycles, capacity_high_water);

        $display(
            "PASS: H3D global queue %0d inputs, %0d outputs, %0d batches, %0d simultaneous-four, %0d backpressure cycles",
            total_inputs, total_outputs, source_batches,
            four_source_batches, backpressure_cycles);
        $finish;
    end

    initial begin
        repeat (50000) @(posedge source_clk);
        $fatal(1,
            "timeout epoch=%0d in=%0d out=%0d local=%0d fault=%0b",
            epoch_number, epoch_inputs, epoch_outputs,
            source_occupancy, fault);
    end
endmodule
