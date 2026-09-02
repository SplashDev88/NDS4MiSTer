module tb_nds_gx_command_packet_ring_fixture;
    localparam integer ENTRY_COUNT = 7;
    localparam integer EXPECTED_COMMANDS = 80917;
    localparam integer EXPECTED_COMMAND_FRAMES = 447;

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

    string fixture_path;
    integer producer_file;
    integer consumer_file;
    integer producer_status;
    integer consumer_status;
    logic [31:0] pending_frame;
    logic [63:0] pending_timestamp;
    logic [7:0] pending_command;
    logic [31:0] pending_parameter;
    logic [31:0] expected_frame;
    logic [63:0] expected_timestamp;
    logic [7:0] expected_command;
    logic [31:0] expected_parameter;

    integer schedule_cycle = 0;
    integer produced = 0;
    integer consumed = 0;
    integer acknowledged = 0;
    integer fixture_source_pauses = 0;
    integer consumer_stall_cycles = 0;
    integer max_level = 0;
    integer write_wraps = 0;
    integer read_wraps = 0;
    integer command_frames = 0;
    logic [31:0] last_produced_frame = 32'hffffffff;

    always #5 clk = ~clk;

    nds_gx_command_packet_ring #(
        .ENABLE(1),
        .ENTRY_COUNT(ENTRY_COUNT)
    ) dut (
        .*
    );

    // Deterministic HPS-side backpressure: three consecutive stalls every
    // nineteen cycles plus one independent stall every thirty-seven cycles.
    // The fixture producer pauses only when a full ring cannot dequeue on the
    // upcoming edge, making the schedule lossless without hiding backpressure.
    function automatic logic consumer_ready_for_cycle(
        input integer cycle_number
    );
        integer phase19;
        begin
            phase19 = cycle_number % 19;
            consumer_ready_for_cycle =
                phase19 >= 3 && (cycle_number % 37) != 11;
        end
    endfunction

    task automatic drive_cycle(
        input logic push,
        input logic advance_frame,
        input logic [63:0] timestamp_value,
        input logic [7:0] command_value,
        input logic [31:0] parameter_value
    );
        logic dequeue_value;
        begin
            dequeue_value = consumer_ready_for_cycle(schedule_cycle);
            @(negedge clk);
            command_valid = push;
            frame_advance = advance_frame;
            command_timestamp = timestamp_value;
            command_id = command_value;
            command_parameter = parameter_value;
            hps_dequeue = dequeue_value;
            if (!dequeue_value)
                consumer_stall_cycles = consumer_stall_cycles + 1;
            @(posedge clk);
            #1;
            schedule_cycle = schedule_cycle + 1;
            if (integer'(level) > max_level)
                max_level = level;
        end
    endtask

    // Consume a second copy of the extracted fixture as the independent
    // scoreboard. This proves every retained packet against source order rather
    // than merely comparing producer and consumer counters.
    always @(posedge clk) begin
        if (!reset) begin
            if (hps_valid && hps_dequeue) begin
                consumer_status = $fscanf(
                    consumer_file, "%h %h %h %h",
                    expected_frame, expected_timestamp,
                    expected_command, expected_parameter);
                if (consumer_status != 4)
                    $fatal(1,
                        "fixture scoreboard ended at command %0d status=%0d",
                        consumed, consumer_status);
                if (hps_fence !== consumed + 1 ||
                    hps_epoch !== 0 ||
                    hps_frame !== expected_frame ||
                    hps_timestamp !== expected_timestamp ||
                    hps_command !== expected_command ||
                    hps_parameter !== expected_parameter ||
                    hps_packet[63:40] !== 24'd0)
                    $fatal(1,
                        "fixture packet mismatch index=%0d fence=%0d frame=%0d/%0d timestamp=%0d/%0d command=%02x/%02x parameter=%08x/%08x",
                        consumed, hps_fence,
                        hps_frame, expected_frame,
                        hps_timestamp, expected_timestamp,
                        hps_command, expected_command,
                        hps_parameter, expected_parameter);
                if (dut.read_pointer == ENTRY_COUNT - 1)
                    read_wraps = read_wraps + 1;
                consumed = consumed + 1;
            end

            if (command_valid && (!full || (hps_valid && hps_dequeue)) &&
                dut.write_pointer == ENTRY_COUNT - 1)
                write_wraps = write_wraps + 1;

            if (hps_ack_valid) begin
                if (hps_ack_fence !== acknowledged + 1)
                    $fatal(1,
                        "fixture acknowledgement mismatch index=%0d fence=%0d",
                        acknowledged, hps_ack_fence);
                acknowledged = acknowledged + 1;
            end

            if (overflow || overflow_pulse || overflow_count != 0)
                $fatal(1,
                    "lossless fixture schedule overflowed sticky=%b pulse=%b count=%0d",
                    overflow, overflow_pulse, overflow_count);
        end
    end

    initial begin : timeout_guard
        repeat (250000) @(posedge clk);
        $fatal(1, "HGS1 GX packet-ring fixture timeout");
    end

    initial begin
        if (!$value$plusargs("fixture=%s", fixture_path))
            $fatal(1, "missing +fixture=<extracted HGS1 command fixture>");
        producer_file = $fopen(fixture_path, "r");
        consumer_file = $fopen(fixture_path, "r");
        if (!producer_file || !consumer_file)
            $fatal(1, "could not open fixture %s", fixture_path);

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        producer_status = $fscanf(
            producer_file, "%h %h %h %h",
            pending_frame, pending_timestamp,
            pending_command, pending_parameter);
        while (producer_status == 4) begin
            while (current_frame < pending_frame)
                drive_cycle(0, 1, 0, 0, 0);
            if (current_frame > pending_frame)
                $fatal(1,
                    "fixture frame moved backward current=%0d pending=%0d",
                    current_frame, pending_frame);

            if (full &&
                !consumer_ready_for_cycle(schedule_cycle)) begin
                fixture_source_pauses = fixture_source_pauses + 1;
                drive_cycle(0, 0, 0, 0, 0);
            end else begin
                if (pending_frame != last_produced_frame) begin
                    command_frames = command_frames + 1;
                    last_produced_frame = pending_frame;
                end
                drive_cycle(
                    1, 0, pending_timestamp,
                    pending_command, pending_parameter);
                produced = produced + 1;
                producer_status = $fscanf(
                    producer_file, "%h %h %h %h",
                    pending_frame, pending_timestamp,
                    pending_command, pending_parameter);
            end
        end
        // Icarus reports zero while Verilator reports -1 for this trailing-EOF
        // scan. Any partial positive conversion is an actual malformed line;
        // the exact command-count gate below catches an early zero.
        if (producer_status > 0)
            $fatal(1, "fixture producer parse ended with status %0d",
                   producer_status);

        while (!empty)
            drive_cycle(0, 0, 0, 0, 0);
        // Registered acknowledgement for the final dequeue is visible on the
        // following edge.
        drive_cycle(0, 0, 0, 0, 0);

        consumer_status = $fscanf(
            consumer_file, "%h %h %h %h",
            expected_frame, expected_timestamp,
            expected_command, expected_parameter);
        if (consumer_status > 0)
            $fatal(1,
                "fixture scoreboard has trailing command status=%0d",
                consumer_status);

        if (produced != EXPECTED_COMMANDS ||
            consumed != EXPECTED_COMMANDS ||
            acknowledged != EXPECTED_COMMANDS ||
            command_frames != EXPECTED_COMMAND_FRAMES ||
            producer_fence != EXPECTED_COMMANDS ||
            consumer_fence != EXPECTED_COMMANDS ||
            current_frame != 599 ||
            current_epoch != 0 ||
            max_level != ENTRY_COUNT ||
            fixture_source_pauses == 0 ||
            write_wraps == 0 || read_wraps == 0 ||
            counter_overflow)
            $fatal(1,
                "fixture completion mismatch produced=%0d consumed=%0d ack=%0d frames=%0d producer_fence=%0d consumer_fence=%0d current_frame=%0d max_level=%0d pauses=%0d wraps=%0d/%0d counter_overflow=%b",
                produced, consumed, acknowledged, command_frames,
                producer_fence, consumer_fence, current_frame,
                max_level, fixture_source_pauses,
                write_wraps, read_wraps, counter_overflow);

        $display(
            "PASS: all HGS1 NSMB geometry commands crossed the lossless GX packet ring in exact order");
        $display(
            "commands=%0d frames=%0d schedule_cycles=%0d consumer_stalls=%0d source_pauses=%0d max_level=%0d write_wraps=%0d read_wraps=%0d",
            consumed, command_frames, schedule_cycle,
            consumer_stall_cycles, fixture_source_pauses,
            max_level, write_wraps, read_wraps);
        $fclose(producer_file);
        $fclose(consumer_file);
        $finish;
    end
endmodule
