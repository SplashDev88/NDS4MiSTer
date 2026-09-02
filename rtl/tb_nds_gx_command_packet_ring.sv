module tb_nds_gx_command_packet_ring;
    localparam integer ENTRY_COUNT = 4;

    logic clk = 0;
    logic reset = 1;
    logic epoch_advance = 0;
    logic frame_advance = 0;
    logic command_valid = 0;
    logic [63:0] command_timestamp = 0;
    logic [7:0] command_id = 0;
    logic [31:0] command_parameter = 0;
    logic hps_valid;
    logic hps_dequeue = 0;
    logic [255:0] hps_packet;
    logic [63:0] hps_fence;
    logic [31:0] hps_epoch;
    logic [31:0] hps_frame;
    logic [63:0] hps_timestamp;
    logic [7:0] hps_command;
    logic [31:0] hps_parameter;
    logic hps_ack_valid;
    logic [63:0] hps_ack_fence;
    logic [63:0] consumer_fence;
    logic [$clog2(ENTRY_COUNT + 1)-1:0] level;
    logic empty;
    logic full;
    logic overflow;
    logic overflow_pulse;
    logic [31:0] overflow_count;
    logic [63:0] producer_fence;
    logic [31:0] current_epoch;
    logic [31:0] current_frame;
    logic counter_overflow;

    logic disabled_hps_valid;
    logic [$clog2(ENTRY_COUNT + 1)-1:0] disabled_level;
    logic disabled_empty, disabled_full, disabled_overflow;
    logic [31:0] disabled_overflow_count;
    logic [63:0] disabled_producer_fence;

    logic [255:0] reference_memory [0:ENTRY_COUNT-1];
    integer reference_write_pointer = 0;
    integer reference_read_pointer = 0;
    integer reference_count = 0;
    logic [63:0] reference_producer_fence = 0;
    logic [63:0] reference_consumer_fence = 0;
    logic [63:0] reference_ack_fence = 0;
    logic [31:0] reference_epoch = 0;
    logic [31:0] reference_frame = 0;
    logic reference_overflow = 0;
    logic [31:0] reference_overflow_count = 0;
    logic reference_counter_overflow = 0;
    logic [63:0] last_accepted_fence = 0;
    logic [31:0] last_accepted_epoch = 0;
    logic [31:0] last_accepted_frame = 0;
    logic [63:0] last_dequeued_fence = 0;
    integer compared_cycles = 0;
    integer accepted_packets = 0;
    integer dropped_packets = 0;
    integer dequeued_packets = 0;

    always #5 clk = ~clk;

    nds_gx_command_packet_ring #(
        .ENABLE(1),
        .ENTRY_COUNT(ENTRY_COUNT)
    ) dut (
        .*
    );

    nds_gx_command_packet_ring #(
        .ENABLE(0),
        .ENTRY_COUNT(ENTRY_COUNT)
    ) disabled (
        .clk, .reset,
        .epoch_advance, .frame_advance,
        .command_valid, .command_timestamp,
        .command_id, .command_parameter,
        .hps_valid(disabled_hps_valid),
        .hps_dequeue,
        .hps_packet(),
        .hps_fence(), .hps_epoch(), .hps_frame(),
        .hps_timestamp(), .hps_command(), .hps_parameter(),
        .hps_ack_valid(), .hps_ack_fence(), .consumer_fence(),
        .level(disabled_level),
        .empty(disabled_empty), .full(disabled_full),
        .overflow(disabled_overflow), .overflow_pulse(),
        .overflow_count(disabled_overflow_count),
        .producer_fence(disabled_producer_fence),
        .current_epoch(), .current_frame(), .counter_overflow()
    );

    task automatic drive_cycle(
        input logic drive_command,
        input logic drive_epoch,
        input logic drive_frame,
        input logic drive_dequeue,
        input logic [63:0] drive_timestamp,
        input logic [7:0] drive_id,
        input logic [31:0] drive_parameter
    );
        begin
            @(negedge clk);
            command_valid = drive_command;
            epoch_advance = drive_epoch;
            frame_advance = drive_frame;
            hps_dequeue = drive_dequeue;
            command_timestamp = drive_timestamp;
            command_id = drive_id;
            command_parameter = drive_parameter;
            @(posedge clk);
        end
    endtask

    logic reference_pop;
    logic reference_push;
    logic reference_drop;
    logic [31:0] next_epoch;
    logic [31:0] next_frame;
    logic [63:0] next_fence;
    logic [255:0] next_packet;
    logic [63:0] popped_fence;

    // Independent queue/counter model. Inputs change only on the falling edge,
    // so pre-edge packet comparison and post-NBA state comparison are stable.
    always @(posedge clk) begin
        if (reset) begin
            reference_write_pointer = 0;
            reference_read_pointer = 0;
            reference_count = 0;
            reference_producer_fence = 0;
            reference_consumer_fence = 0;
            reference_ack_fence = 0;
            reference_epoch = 0;
            reference_frame = 0;
            reference_overflow = 0;
            reference_overflow_count = 0;
            reference_counter_overflow = 0;
            last_accepted_fence = 0;
            last_accepted_epoch = 0;
            last_accepted_frame = 0;
            last_dequeued_fence = 0;
            accepted_packets = 0;
            dropped_packets = 0;
            dequeued_packets = 0;
            #1;
        end else begin
            compared_cycles = compared_cycles + 1;
            if (hps_valid !== (reference_count != 0))
                $fatal(1, "HPS valid/reference count mismatch");
            if (reference_count != 0) begin
                if (hps_packet !==
                    reference_memory[reference_read_pointer])
                    $fatal(1, "HPS packet/reference head mismatch");
                if (hps_fence !== hps_packet[255:192] ||
                    hps_epoch !== hps_packet[191:160] ||
                    hps_frame !== hps_packet[159:128] ||
                    hps_timestamp !== hps_packet[127:64] ||
                    hps_command !== hps_packet[39:32] ||
                    hps_parameter !== hps_packet[31:0] ||
                    hps_packet[63:40] !== 24'd0)
                    $fatal(1, "decoded HPS packet fields mismatch");
            end

            reference_pop = reference_count != 0 && hps_dequeue;
            next_epoch =
                epoch_advance && reference_epoch != 32'hffffffff
                    ? reference_epoch + 1'b1 : reference_epoch;
            next_frame =
                frame_advance && reference_frame != 32'hffffffff
                    ? reference_frame + 1'b1 : reference_frame;
            next_fence =
                reference_producer_fence != 64'hffffffffffffffff
                    ? reference_producer_fence + 1'b1
                    : reference_producer_fence;
            next_packet = {
                next_fence,
                next_epoch,
                next_frame,
                command_timestamp,
                24'd0,
                command_id,
                command_parameter
            };
            reference_push =
                command_valid &&
                (reference_count < ENTRY_COUNT || reference_pop);
            reference_drop = command_valid && !reference_push;
            popped_fence = reference_pop
                ? reference_memory[reference_read_pointer][255:192]
                : reference_ack_fence;

            if (epoch_advance) begin
                if (reference_epoch == 32'hffffffff)
                    reference_counter_overflow = 1;
                else
                    reference_epoch = reference_epoch + 1'b1;
            end
            if (frame_advance) begin
                if (reference_frame == 32'hffffffff)
                    reference_counter_overflow = 1;
                else
                    reference_frame = reference_frame + 1'b1;
            end
            if (command_valid) begin
                if (reference_producer_fence ==
                    64'hffffffffffffffff)
                    reference_counter_overflow = 1;
                else
                    reference_producer_fence =
                        reference_producer_fence + 1'b1;
            end

            if (reference_pop) begin
                if (popped_fence <= last_dequeued_fence)
                    $fatal(1, "dequeued fence was not strictly increasing");
                last_dequeued_fence = popped_fence;
                reference_ack_fence = popped_fence;
                reference_consumer_fence = popped_fence;
                reference_read_pointer =
                    reference_read_pointer == ENTRY_COUNT - 1
                        ? 0 : reference_read_pointer + 1;
                dequeued_packets = dequeued_packets + 1;
            end

            if (reference_push) begin
                if (next_fence <= last_accepted_fence ||
                    next_epoch < last_accepted_epoch ||
                    next_frame < last_accepted_frame)
                    $fatal(1,
                        "accepted metadata regressed fence=%0d epoch=%0d frame=%0d",
                        next_fence, next_epoch, next_frame);
                last_accepted_fence = next_fence;
                last_accepted_epoch = next_epoch;
                last_accepted_frame = next_frame;
                reference_memory[reference_write_pointer] =
                    next_packet;
                reference_write_pointer =
                    reference_write_pointer == ENTRY_COUNT - 1
                        ? 0 : reference_write_pointer + 1;
                accepted_packets = accepted_packets + 1;
            end

            case ({reference_push, reference_pop})
                2'b10: reference_count = reference_count + 1;
                2'b01: reference_count = reference_count - 1;
                default: reference_count = reference_count;
            endcase

            if (reference_drop) begin
                reference_overflow = 1;
                if (reference_overflow_count != 32'hffffffff)
                    reference_overflow_count =
                        reference_overflow_count + 1'b1;
                else
                    reference_counter_overflow = 1;
                dropped_packets = dropped_packets + 1;
            end

            #1;
            if (integer'(level) != reference_count ||
                empty !== (reference_count == 0) ||
                full !== (reference_count == ENTRY_COUNT))
                $fatal(1,
                    "post-edge level mismatch level=%0d/%0d empty=%b full=%b",
                    level, reference_count, empty, full);
            if (producer_fence !== reference_producer_fence ||
                consumer_fence !== reference_consumer_fence ||
                current_epoch !== reference_epoch ||
                current_frame !== reference_frame)
                $fatal(1,
                    "counter mismatch producer=%0d/%0d consumer=%0d/%0d epoch=%0d/%0d frame=%0d/%0d",
                    producer_fence, reference_producer_fence,
                    consumer_fence, reference_consumer_fence,
                    current_epoch, reference_epoch,
                    current_frame, reference_frame);
            if (overflow !== reference_overflow ||
                overflow_count !== reference_overflow_count ||
                overflow_pulse !== reference_drop ||
                counter_overflow !== reference_counter_overflow)
                $fatal(1,
                    "overflow telemetry mismatch sticky=%b/%b pulse=%b/%b count=%0d/%0d",
                    overflow, reference_overflow,
                    overflow_pulse, reference_drop,
                    overflow_count, reference_overflow_count);
            if (hps_ack_valid !== reference_pop ||
                hps_ack_fence !== reference_ack_fence)
                $fatal(1,
                    "HPS acknowledgement mismatch valid=%b/%b fence=%0d/%0d",
                    hps_ack_valid, reference_pop,
                    hps_ack_fence, reference_ack_fence);
        end

        if (disabled_hps_valid || disabled_level != 0 ||
            !disabled_empty || disabled_full || disabled_overflow ||
            disabled_overflow_count != 0 ||
            disabled_producer_fence != 0)
            $fatal(1, "default-off ring changed state");
    end

    logic [31:0] random_state = 32'h1badb002;
    integer i;

    initial begin : timeout_guard
        repeat (10000) @(posedge clk);
        $fatal(1, "GX packet-ring test timeout");
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Fill four slots. Boundary pulses on command edges must be reflected
        // in the packet emitted for that same edge.
        drive_cycle(1, 1, 1, 0, 64'h100, 8'h10, 32'h10000001);
        drive_cycle(1, 0, 0, 0, 64'h101, 8'h20, 32'h20000002);
        drive_cycle(1, 0, 1, 0, 64'h102, 8'h21, 32'h21000003);
        drive_cycle(1, 1, 0, 0, 64'h103, 8'h22, 32'h22000004);

        // Two commands are deliberately lost while full. Their fences are
        // still consumed, allowing HPS to diagnose the later 4 -> 7 gap.
        drive_cycle(1, 0, 0, 0, 64'h104, 8'h23, 32'h23000005);
        drive_cycle(1, 0, 1, 0, 64'h105, 8'h24, 32'h24000006);

        // Full-ring simultaneous dequeue/enqueue is lossless.
        drive_cycle(1, 0, 0, 1, 64'h106, 8'h25, 32'h25000007);
        drive_cycle(1, 0, 1, 1, 64'h107, 8'h26, 32'h26000008);

        // Drain before randomized stress.
        repeat (6)
            drive_cycle(0, 0, 0, 1, 0, 0, 0);

        // Deterministic randomized producer, metadata, and HPS cadence.
        for (i = 0; i < 1200; i = i + 1) begin
            random_state =
                random_state * 32'd1664525 + 32'd1013904223;
            drive_cycle(
                random_state[0] | random_state[3],
                random_state[9:4] == 0,
                random_state[6:4] == 0,
                random_state[1] | random_state[7],
                {32'habc00000, random_state},
                random_state[15:8],
                random_state ^ (32'h9e3779b9 * i));
        end

        repeat (ENTRY_COUNT + 4)
            drive_cycle(0, 0, 0, 1, 0, 0, 0);
        drive_cycle(0, 0, 0, 0, 0, 0, 0);

        if (reference_count != 0 || !empty || hps_valid)
            $fatal(1, "packet ring did not drain");
        if (!overflow || overflow_count == 0 ||
            producer_fence != accepted_packets + dropped_packets)
            $fatal(1,
                "overflow/fence accounting failed producer=%0d accepted=%0d dropped=%0d overflow=%0d",
                producer_fence, accepted_packets,
                dropped_packets, overflow_count);
        if (dequeued_packets != accepted_packets ||
            consumer_fence != last_accepted_fence)
            $fatal(1,
                "HPS did not acknowledge all retained packets dequeue=%0d accepted=%0d consumer=%0d last=%0d",
                dequeued_packets, accepted_packets,
                consumer_fence, last_accepted_fence);

        $display(
            "PASS: nonblocking GX packet ring preserves metadata, exposes fence gaps, and acknowledges HPS dequeues");
        $display(
            "cycles=%0d producer=%0d accepted=%0d dropped=%0d dequeued=%0d epoch=%0d frame=%0d",
            compared_cycles, producer_fence, accepted_packets,
            dropped_packets, dequeued_packets,
            current_epoch, current_frame);
        $finish;
    end
endmodule


// The main randomized ring test uses a power-of-two depth.  Keep this small
// independent instance to prove explicit LAST_POINTER wrapping also works for
// the non-power-of-two depths supported by the parameterized RTL.
module tb_nds_gx_command_packet_ring_depth3;
    localparam integer ENTRY_COUNT = 3;

    logic clk = 0;
    logic reset = 1;
    logic command_valid = 0;
    logic [63:0] command_timestamp = 0;
    logic [7:0] command_id = 0;
    logic [31:0] command_parameter = 0;
    logic hps_valid;
    logic hps_dequeue = 0;
    logic [63:0] hps_fence;
    logic [7:0] hps_command;
    logic [31:0] hps_parameter;
    logic hps_ack_valid;
    logic [63:0] hps_ack_fence;
    logic [$clog2(ENTRY_COUNT + 1)-1:0] level;
    logic empty;
    logic full;
    logic overflow;
    logic [31:0] overflow_count;
    logic [63:0] producer_fence;

    logic [63:0] wanted_fence [0:7];
    logic [7:0] wanted_command [0:7];
    logic [31:0] wanted_parameter [0:7];
    integer wanted_count = 0;
    integer observed_count = 0;
    integer ack_count = 0;

    always #5 clk = ~clk;

    nds_gx_command_packet_ring #(
        .ENABLE(1),
        .ENTRY_COUNT(ENTRY_COUNT)
    ) dut (
        .clk, .reset,
        .epoch_advance(1'b0),
        .frame_advance(1'b0),
        .command_valid, .command_timestamp,
        .command_id, .command_parameter,
        .hps_valid, .hps_dequeue,
        .hps_packet(), .hps_fence,
        .hps_epoch(), .hps_frame(), .hps_timestamp(),
        .hps_command, .hps_parameter,
        .hps_ack_valid, .hps_ack_fence, .consumer_fence(),
        .level, .empty, .full,
        .overflow, .overflow_pulse(), .overflow_count,
        .producer_fence,
        .current_epoch(), .current_frame(), .counter_overflow()
    );

    task automatic expect_packet(
        input logic [63:0] wanted_packet_fence,
        input logic [7:0] wanted_packet_command,
        input logic [31:0] wanted_packet_parameter
    );
        begin
            wanted_fence[wanted_count] = wanted_packet_fence;
            wanted_command[wanted_count] = wanted_packet_command;
            wanted_parameter[wanted_count] = wanted_packet_parameter;
            wanted_count = wanted_count + 1;
        end
    endtask

    task automatic drive_cycle(
        input logic push,
        input logic pop,
        input logic [7:0] drive_command,
        input logic [31:0] drive_parameter
    );
        begin
            @(negedge clk);
            command_valid = push;
            hps_dequeue = pop;
            command_id = drive_command;
            command_parameter = drive_parameter;
            command_timestamp = {32'hd3000000, drive_parameter};
            @(posedge clk);
        end
    endtask

    // Sample the pre-NBA valid/dequeue contract at the consuming edge. Inputs
    // are driven on negedges, avoiding same-edge task/monitor races.
    always @(posedge clk) begin
        if (!reset && hps_valid && hps_dequeue) begin
            if (observed_count >= wanted_count ||
                hps_fence !== wanted_fence[observed_count] ||
                hps_command !== wanted_command[observed_count] ||
                hps_parameter !== wanted_parameter[observed_count])
                $fatal(1,
                    "depth-3 packet mismatch index=%0d fence=%0d command=%02x parameter=%08x",
                    observed_count, hps_fence,
                    hps_command, hps_parameter);
            observed_count = observed_count + 1;
        end
        if (!reset && hps_ack_valid) begin
            if (ack_count >= observed_count ||
                hps_ack_fence !== wanted_fence[ack_count])
                $fatal(1,
                    "depth-3 acknowledgement mismatch index=%0d fence=%0d",
                    ack_count, hps_ack_fence);
            ack_count = ack_count + 1;
        end
    end

    initial begin : timeout_guard
        repeat (300) @(posedge clk);
        $fatal(1, "depth-3 GX packet-ring test timeout");
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        expect_packet(1, 8'h10, 32'h10000001);
        expect_packet(2, 8'h20, 32'h20000002);
        expect_packet(3, 8'h30, 32'h30000003);
        drive_cycle(1, 0, 8'h10, 32'h10000001);
        drive_cycle(1, 0, 8'h20, 32'h20000002);
        drive_cycle(1, 0, 8'h30, 32'h30000003);
        #1;
        if (!full || level != 3)
            $fatal(1, "depth-3 ring did not fill");

        // Fence 4 is dropped. On the next edge, dequeue fence 1 and enqueue
        // fence 5 through the same full slot; the retained order is 1,2,3,5.
        drive_cycle(1, 0, 8'h40, 32'h40000004);
        expect_packet(5, 8'h50, 32'h50000005);
        drive_cycle(1, 1, 8'h50, 32'h50000005);
        drive_cycle(0, 1, 0, 0);
        drive_cycle(0, 1, 0, 0);
        drive_cycle(0, 1, 0, 0);
        drive_cycle(0, 0, 0, 0);
        #1;

        if (!empty || level != 0 ||
            !overflow || overflow_count != 1 ||
            producer_fence != 5 ||
            observed_count != wanted_count ||
            ack_count != wanted_count)
            $fatal(1,
                "depth-3 completion mismatch empty=%b level=%0d overflow=%b/%0d producer=%0d observed=%0d/%0d ack=%0d",
                empty, level, overflow, overflow_count,
                producer_fence, observed_count, wanted_count, ack_count);

        $display(
            "PASS: non-power-of-two GX packet ring wraps pointers and preserves full pop/push ordering");
        $finish;
    end
endmodule


module tb_nds_gx_frontend_packet_ring;
    localparam integer ENTRY_COUNT = 4;

    logic clk = 0;
    logic reset = 1;
    logic write_valid = 0;
    logic write_ready;
    logic cpu_is_arm9 = 1;
    logic [31:0] address = 0;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] source_frame = 0;
    logic [63:0] source_timestamp = 0;
    logic normalized_valid;
    logic [31:0] normalized_frame;
    logic [63:0] normalized_timestamp;
    logic [7:0] normalized_command;
    logic [31:0] normalized_parameter;

    logic epoch_advance = 0;
    logic frame_advance = 0;
    logic hps_valid;
    logic hps_dequeue = 0;
    logic [255:0] hps_packet;
    logic [63:0] hps_fence;
    logic [31:0] hps_epoch;
    logic [31:0] hps_frame;
    logic [63:0] hps_timestamp;
    logic [7:0] hps_command;
    logic [31:0] hps_parameter;
    logic hps_ack_valid;
    logic [63:0] hps_ack_fence;
    logic [63:0] consumer_fence;
    logic [$clog2(ENTRY_COUNT + 1)-1:0] level;
    logic empty, full, overflow, overflow_pulse;
    logic [31:0] overflow_count;
    logic [63:0] producer_fence;
    logic [31:0] current_epoch, current_frame;
    logic counter_overflow;

    logic [63:0] wanted_fence [0:7];
    logic [31:0] wanted_epoch [0:7];
    logic [31:0] wanted_frame [0:7];
    logic [63:0] wanted_timestamp [0:7];
    logic [7:0] wanted_command [0:7];
    logic [31:0] wanted_parameter [0:7];
    integer wanted_count = 0;
    integer observed_count = 0;
    integer ack_count = 0;

    always #5 clk = ~clk;

    nds_gx_command_frontend #(
        .QUEUE_DEPTH(8)
    ) frontend (
        .clk, .reset,
        .write_valid, .write_ready,
        .cpu_is_arm9, .address, .access,
        .write_data,
        .frame(source_frame),
        .timestamp(source_timestamp),
        .command_valid(normalized_valid),
        .command_ready(1'b1),
        .command_frame(normalized_frame),
        .command_timestamp(normalized_timestamp),
        .command_id(normalized_command),
        .command_parameter(normalized_parameter),
        .queue_level(), .queue_empty(), .queue_full(),
        .packed_active(), .busy(), .protocol_error()
    );

    nds_gx_command_packet_ring #(
        .ENABLE(1),
        .ENTRY_COUNT(ENTRY_COUNT)
    ) ring (
        .clk, .reset,
        .epoch_advance, .frame_advance,
        .command_valid(normalized_valid),
        .command_timestamp(normalized_timestamp),
        .command_id(normalized_command),
        .command_parameter(normalized_parameter),
        .hps_valid, .hps_dequeue, .hps_packet,
        .hps_fence, .hps_epoch, .hps_frame,
        .hps_timestamp, .hps_command, .hps_parameter,
        .hps_ack_valid, .hps_ack_fence, .consumer_fence,
        .level, .empty, .full,
        .overflow, .overflow_pulse, .overflow_count,
        .producer_fence, .current_epoch, .current_frame,
        .counter_overflow
    );

    task automatic expect_packet(
        input logic [63:0] wanted_packet_fence,
        input logic [31:0] wanted_packet_epoch,
        input logic [31:0] wanted_packet_frame,
        input logic [63:0] wanted_packet_timestamp,
        input logic [7:0] wanted_packet_command,
        input logic [31:0] wanted_packet_parameter
    );
        begin
            wanted_fence[wanted_count] = wanted_packet_fence;
            wanted_epoch[wanted_count] = wanted_packet_epoch;
            wanted_frame[wanted_count] = wanted_packet_frame;
            wanted_timestamp[wanted_count] = wanted_packet_timestamp;
            wanted_command[wanted_count] = wanted_packet_command;
            wanted_parameter[wanted_count] = wanted_packet_parameter;
            wanted_count = wanted_count + 1;
        end
    endtask

    task automatic pulse_boundary(
        input logic epoch_pulse,
        input logic frame_pulse
    );
        begin
            @(negedge clk);
            epoch_advance = epoch_pulse;
            frame_advance = frame_pulse;
            @(posedge clk);
            @(negedge clk);
            epoch_advance = 0;
            frame_advance = 0;
        end
    endtask

    task automatic send_raw_write(
        input logic [31:0] bus_address,
        input logic [31:0] bus_data,
        input logic [63:0] bus_timestamp
    );
        integer waited;
        begin
            @(negedge clk);
            address = bus_address;
            write_data = bus_data;
            source_timestamp = bus_timestamp;
            write_valid = 1;
            waited = 0;
            while (!write_ready) begin
                @(posedge clk);
                waited = waited + 1;
                if (waited > 64)
                    $fatal(1, "frontend input timeout");
                @(negedge clk);
            end
            @(posedge clk);
            @(negedge clk);
            write_valid = 0;
        end
    endtask

    // HPS observes one packet per cycle while dequeue is asserted. The ring
    // has no path back to the frontend, even when overflow is active.
    always @(negedge clk) begin
        if (!reset && hps_valid && hps_dequeue) begin
            if (observed_count >= wanted_count)
                $fatal(1, "unexpected integrated HPS packet");
            if (hps_fence !== wanted_fence[observed_count] ||
                hps_epoch !== wanted_epoch[observed_count] ||
                hps_frame !== wanted_frame[observed_count] ||
                hps_timestamp !== wanted_timestamp[observed_count] ||
                hps_command !== wanted_command[observed_count] ||
                hps_parameter !== wanted_parameter[observed_count])
                $fatal(1,
                    "integrated packet mismatch at %0d got fence=%0d epoch=%0d frame=%0d ts=%0d cmd=%02x param=%08x",
                    observed_count, hps_fence, hps_epoch, hps_frame,
                    hps_timestamp, hps_command, hps_parameter);
            observed_count = observed_count + 1;
        end
        if (!reset && hps_ack_valid) begin
            if (ack_count >= observed_count ||
                hps_ack_fence !== wanted_fence[ack_count])
                $fatal(1,
                    "integrated ack mismatch at %0d fence=%0d",
                    ack_count, hps_ack_fence);
            ack_count = ack_count + 1;
        end
    end

    initial begin : timeout_guard
        repeat (3000) @(posedge clk);
        $fatal(1, "GX frontend/packet-ring integration timeout");
    end

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        pulse_boundary(1, 1);
        expect_packet(1, 1, 1, 64'h101, 8'h10, 32'h10000001);
        expect_packet(2, 1, 1, 64'h102, 8'h11, 32'h11000002);
        expect_packet(3, 1, 1, 64'h103, 8'h12, 32'h12000003);
        expect_packet(4, 1, 1, 64'h104, 8'h13, 32'h13000004);
        send_raw_write(32'h04000440, 32'h10000001, 64'h101);
        send_raw_write(32'h04000444, 32'h11000002, 64'h102);
        send_raw_write(32'h04000448, 32'h12000003, 64'h103);
        send_raw_write(32'h0400044c, 32'h13000004, 64'h104);
        wait (full);

        // Fence 5 is dropped while full. The frontend still accepts and emits
        // the raw direct write because the ring has no producer-ready path.
        if (!write_ready)
            $fatal(1, "full ring fed back into frontend readiness");
        send_raw_write(32'h04000450, 32'h14000005, 64'h105);
        repeat (3) @(posedge clk);
        if (!overflow || overflow_count != 1 ||
            producer_fence != 5 || level != ENTRY_COUNT)
            $fatal(1,
                "integrated overflow accounting mismatch overflow=%b count=%0d fence=%0d level=%0d",
                overflow, overflow_count, producer_fence, level);

        @(negedge clk);
        hps_dequeue = 1;
        wait (empty);
        @(negedge clk);
        hps_dequeue = 0;
        repeat (2) @(posedge clk);

        pulse_boundary(0, 1);
        // Packed zero-parameter commands reuse the command word. Their fence
        // values begin at 6, preserving the visible gap at dropped fence 5.
        expect_packet(6, 1, 2, 64'h200, 8'h11, 32'h00411511);
        expect_packet(7, 1, 2, 64'h200, 8'h15, 32'h00411511);
        expect_packet(8, 1, 2, 64'h200, 8'h41, 32'h00411511);
        send_raw_write(32'h04000400, 32'h00411511, 64'h200);
        repeat (8) @(posedge clk);
        if (producer_fence != 8 || level != 3)
            $fatal(1,
                "packed commands did not reach ring fence=%0d level=%0d",
                producer_fence, level);

        @(negedge clk);
        hps_dequeue = 1;
        wait (empty);
        repeat (2) @(posedge clk);
        @(negedge clk);
        hps_dequeue = 0;
        repeat (2) @(posedge clk);

        if (observed_count != wanted_count ||
            ack_count != wanted_count ||
            consumer_fence != 8 ||
            counter_overflow)
            $fatal(1,
                "integrated completion mismatch observed=%0d wanted=%0d ack=%0d consumer=%0d",
                observed_count, wanted_count, ack_count, consumer_fence);
        for (i = 1; i < wanted_count; i = i + 1)
            if (wanted_fence[i] <= wanted_fence[i-1] ||
                wanted_epoch[i] < wanted_epoch[i-1] ||
                wanted_frame[i] < wanted_frame[i-1])
                $fatal(1, "wanted metadata was not monotonic");

        $display(
            "PASS: GX frontend feeds a CPU-nonblocking coarse packet ring with explicit overflow/fence gap");
        $display(
            "packets=%0d producer_fence=%0d consumer_fence=%0d dropped=%0d epoch=%0d frame=%0d",
            observed_count, producer_fence, consumer_fence,
            overflow_count, current_epoch, current_frame);
        $finish;
    end
endmodule
