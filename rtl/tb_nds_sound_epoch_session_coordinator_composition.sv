module tb_nds_sound_epoch_session_coordinator_composition;
    localparam logic [28:0] BASE_WORD = 29'd32;
    localparam integer ENTRY_COUNT = 2;
    localparam integer HEADER_WORDS64 = 2;
    localparam logic [31:0] MAGIC = 32'h4341434b;
    localparam logic [31:0] EPOCH = 32'h13572468;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic transport_quiescent = 1'b1;
    logic epoch_request_valid = 1'b0;
    logic epoch_request_ready;
    logic [31:0] epoch_request = 32'd0;
    logic epoch_request_fresh = 1'b0;

    logic ring_session_begin_valid;
    logic ring_session_begin_ready;
    logic [31:0] ring_session_begin_epoch;
    logic ring_session_epoch_fresh;
    logic ring_session_started;
    logic ring_session_active;
    logic [31:0] ring_active_epoch;
    logic [31:0] ring_consumer_sequence;
    logic ring_sequence_exhausted;
    logic ring_protocol_error;
    logic ring_active;
    logic ring_ddram_active;

    logic ring_ack_valid;
    logic ring_ack_ready;
    logic [31:0] ring_ack_epoch;
    logic [31:0] ring_ack_sequence;
    logic ring_ack_cpu_arm9;
    logic [31:0] ring_ack_cycles;
    logic [1:0] ring_ack_kind;
    logic [31:0] ring_ack_source_id;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_command_accepted;
    logic [63:0] ddram_read_data = 64'd0;
    logic ddram_read_data_ready = 1'b0;

    logic broadcaster_epoch_begin_valid;
    logic broadcaster_epoch_begin_ready;
    logic [31:0] broadcaster_epoch_begin;
    logic broadcaster_epoch_begin_fresh;
    logic broadcaster_epoch_started;
    logic broadcaster_epoch_active;
    logic [31:0] broadcaster_active_epoch;
    logic broadcaster_sequence_exhausted;
    logic broadcaster_protocol_error;
    logic broadcaster_busy;

    logic queue_ack_valid;
    logic queue_ack_ready;
    logic [31:0] queue_ack_epoch;
    logic [31:0] queue_ack_sequence;
    logic queue_ack_cpu_arm9;
    logic [1:0] queue_ack_kind;
    logic [31:0] queue_ack_source_id;

    logic credit_valid;
    logic credit_ready;
    logic [31:0] credit_epoch;
    logic [31:0] credit_ack_sequence;
    logic credit_cpu_arm9;
    logic [31:0] credit_cycles;
    logic [1:0] credit_kind;

    logic queue_epoch_begin_valid;
    logic queue_epoch_begin_ready;
    logic [31:0] queue_epoch_begin;
    logic queue_epoch_begin_fresh;
    logic queue_epoch_started;
    logic queue_epoch_active;
    logic [31:0] queue_active_epoch;
    logic completion_valid = 1'b0;
    logic [31:0] completion_epoch = 32'd0;
    logic [31:0] completion_source_id = 32'd0;
    logic completion_cpu_arm9 = 1'b0;
    logic completion_read_not_write = 1'b1;
    logic [1:0] completion_access = 2'b10;
    logic [31:0] completion_address = 32'h04000006;
    logic [31:0] completion_write_data = 32'd0;
    logic drain_token_valid;
    logic drain_token_ready;
    logic [31:0] drain_token_epoch;
    logic [31:0] drain_token_ack_sequence;
    logic write_valid;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [$clog2(8 + 1)-1:0] queue_level;
    logic queue_pending_sound_ack;
    logic queue_capture_overflow;
    logic queue_sequence_exhausted;
    logic queue_protocol_error;

    logic drain_epoch_begin_valid;
    logic drain_epoch_begin_ready;
    logic [31:0] drain_epoch_begin;
    logic drain_epoch_begin_fresh;
    logic drain_epoch_started;
    logic drain_epoch_active;
    logic [31:0] drain_active_epoch;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic [63:0] remaining_delta_cycles;
    logic drain_busy;
    logic drain_sequence_exhausted;
    logic drain_protocol_error;
    logic drain_overflow;

    logic sound_data_activity;
    logic sound_epoch_ready;
    logic [31:0] coordinated_active_epoch;
    logic sound_data_enable;
    logic sound_shadow_enable;
    logic sound_shadow_reset;
    logic coordinator_protocol_error;
    logic terminal_fault;
    logic premature_activity;
    logic [7:0] fault_code;

    logic [63:0] memory [0:127];
    logic read_pending = 1'b0;
    logic [28:0] pending_read_address = 29'd0;
    integer accepted_reads = 0;
    integer accepted_writes = 0;
    integer output_cycle_sum = 0;
    logic broadcaster_ack_ready_internal;

    assign ddram_command_accepted = ddram_read || ddram_write;
    assign ring_ack_ready =
        sound_data_enable && !coordinator_protocol_error &&
        // The broadcaster owns the actual backpressure.
        broadcaster_ack_ready_internal;

    // Every sound data-plane request/valid is covered.  Ring DDR validation
    // traffic is control-plane activity and intentionally excluded.
    assign sound_data_activity =
        completion_valid || ring_ack_valid ||
        queue_ack_valid || credit_valid || drain_token_valid ||
        sound_cycles_valid || write_valid;

    nds_sound_epoch_session_coordinator coordinator (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_request_valid,
        .epoch_request_ready,
        .epoch_request,
        .epoch_request_fresh,
        .ring_session_begin_valid,
        .ring_session_begin_ready,
        .ring_session_begin_epoch,
        .ring_session_epoch_fresh,
        .ring_session_started,
        .ring_session_active,
        .ring_active_epoch,
        .ring_sequence_exhausted,
        .ring_protocol_error,
        .broadcaster_epoch_begin_valid,
        .broadcaster_epoch_begin_ready,
        .broadcaster_epoch_begin,
        .broadcaster_epoch_begin_fresh,
        .broadcaster_epoch_started,
        .broadcaster_epoch_active,
        .broadcaster_active_epoch,
        .broadcaster_sequence_exhausted,
        .broadcaster_protocol_error,
        .queue_epoch_begin_valid,
        .queue_epoch_begin_ready,
        .queue_epoch_begin,
        .queue_epoch_begin_fresh,
        .queue_epoch_started,
        .queue_epoch_active,
        .queue_active_epoch,
        .queue_capture_overflow,
        .queue_sequence_exhausted,
        .queue_protocol_error,
        .drain_epoch_begin_valid,
        .drain_epoch_begin_ready,
        .drain_epoch_begin,
        .drain_epoch_begin_fresh,
        .drain_epoch_started,
        .drain_epoch_active,
        .drain_active_epoch,
        .drain_sequence_exhausted,
        .drain_protocol_error,
        .drain_overflow,
        .sound_data_activity,
        .sound_epoch_ready,
        .active_epoch(coordinated_active_epoch),
        .sound_data_enable,
        .sound_shadow_enable,
        .sound_shadow_reset,
        .protocol_error(coordinator_protocol_error),
        .terminal_fault,
        .premature_activity,
        .fault_code
    );

    nds_hps_consumed_credit_ddr_ring #(
        .ENABLED(1'b1),
        .BASE_WORD(BASE_WORD),
        .ENTRY_COUNT(ENTRY_COUNT),
        .HEADER_WORDS64(HEADER_WORDS64),
        .POLL_BACKOFF_CYCLES(2)
    ) ring (
        .clk,
        .reset,
        .session_begin_valid(ring_session_begin_valid),
        .session_begin_ready(ring_session_begin_ready),
        .session_begin_epoch(ring_session_begin_epoch),
        .session_epoch_fresh(ring_session_epoch_fresh),
        .transport_quiescent,
        .session_started(ring_session_started),
        .session_active(ring_session_active),
        .active_epoch(ring_active_epoch),
        .consumer_sequence(ring_consumer_sequence),
        .ack_valid(ring_ack_valid),
        .ack_ready(ring_ack_ready),
        .ack_epoch(ring_ack_epoch),
        .ack_sequence(ring_ack_sequence),
        .ack_cpu_arm9(ring_ack_cpu_arm9),
        .ack_cycles(ring_ack_cycles),
        .ack_kind(ring_ack_kind),
        .ack_source_id(ring_ack_source_id),
        .active(ring_active),
        .ddram_active(ring_ddram_active),
        .sequence_exhausted(ring_sequence_exhausted),
        .protocol_error(ring_protocol_error),
        .ddram_read,
        .ddram_write,
        .ddram_burst_count,
        .ddram_address,
        .ddram_write_data,
        .ddram_byte_enable,
        .ddram_busy(1'b0),
        .ddram_command_accepted,
        .ddram_read_data,
        .ddram_read_data_ready
    );

    nds_sound_ack_broadcaster broadcaster (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(broadcaster_epoch_begin_valid),
        .epoch_begin_ready(broadcaster_epoch_begin_ready),
        .epoch_begin(broadcaster_epoch_begin),
        .epoch_begin_fresh(broadcaster_epoch_begin_fresh),
        .epoch_started(broadcaster_epoch_started),
        .epoch_active(broadcaster_epoch_active),
        .active_epoch(broadcaster_active_epoch),
        .ack_valid(ring_ack_valid && sound_data_enable),
        .ack_ready(broadcaster_ack_ready_internal),
        .ack_epoch(ring_ack_epoch),
        .ack_sequence(ring_ack_sequence),
        .ack_cpu_arm9(ring_ack_cpu_arm9),
        .ack_cycles(ring_ack_cycles),
        .ack_kind(ring_ack_kind),
        .ack_source_id(ring_ack_source_id),
        .queue_ack_valid,
        .queue_ack_ready,
        .queue_ack_epoch,
        .queue_ack_sequence,
        .queue_ack_cpu_arm9,
        .queue_ack_kind,
        .queue_ack_source_id,
        .credit_valid,
        .credit_ready,
        .credit_epoch,
        .credit_ack_sequence,
        .credit_cpu_arm9,
        .credit_cycles,
        .credit_kind,
        .busy(broadcaster_busy),
        .sequence_exhausted(broadcaster_sequence_exhausted),
        .protocol_error(broadcaster_protocol_error)
    );

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(8)
    ) queue (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(queue_epoch_begin_valid),
        .epoch_begin_ready(queue_epoch_begin_ready),
        .epoch_begin(queue_epoch_begin),
        .epoch_begin_fresh(queue_epoch_begin_fresh),
        .epoch_started(queue_epoch_started),
        .epoch_active(queue_epoch_active),
        .active_epoch(queue_active_epoch),
        .epoch_seed_valid(1'b0),
        .epoch_seed_mailbox_source_id(32'd0),
        .epoch_seed_posted_base_sequence(32'd0),
        .epoch_seed_global_sequence(32'd0),
        .epoch_runtime_contract_active(1'b0),
        .completion_valid(completion_valid &&
                          sound_data_enable),
        .completion_epoch,
        .completion_source_id,
        .completion_cpu_arm9,
        .completion_read_not_write,
        .completion_access,
        .completion_address,
        .completion_write_data,
        .ack_valid(queue_ack_valid),
        .ack_ready(queue_ack_ready),
        .ack_epoch(queue_ack_epoch),
        .ack_sequence(queue_ack_sequence),
        .ack_cpu_arm9(queue_ack_cpu_arm9),
        .ack_kind(queue_ack_kind),
        .ack_source_id(queue_ack_source_id),
        .drain_valid(drain_token_valid),
        .drain_ready(drain_token_ready),
        .drain_epoch(drain_token_epoch),
        .drain_ack_sequence(drain_token_ack_sequence),
        .write_valid,
        .write_ready(1'b1),
        .write_epoch,
        .write_source_id,
        .write_address,
        .write_access,
        .write_data,
        .queue_level,
        .pending_sound_ack(queue_pending_sound_ack),
        .capture_overflow(queue_capture_overflow),
        .sequence_exhausted(queue_sequence_exhausted),
        .protocol_error(queue_protocol_error)
    );

    nds_sound_credit_drain_coordinator drain (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(drain_epoch_begin_valid),
        .epoch_begin_ready(drain_epoch_begin_ready),
        .epoch_begin(drain_epoch_begin),
        .epoch_begin_fresh(drain_epoch_begin_fresh),
        .epoch_started(drain_epoch_started),
        .epoch_active(drain_epoch_active),
        .active_epoch(drain_active_epoch),
        .credit_valid,
        .credit_ready,
        .credit_epoch,
        .credit_ack_sequence,
        .credit_cpu_arm9,
        .credit_cycles,
        .credit_kind,
        .sound_cycles,
        .sound_cycles_valid,
        .sound_cycles_ready(1'b1),
        .drain_token_valid,
        .drain_token_ready,
        .drain_token_epoch,
        .drain_token_ack_sequence,
        .arm9_timestamp,
        .arm7_timestamp,
        .shared_timestamp,
        .remaining_delta_cycles,
        .busy(drain_busy),
        .sequence_exhausted(drain_sequence_exhausted),
        .protocol_error(drain_protocol_error),
        .overflow(drain_overflow)
    );

    always @(posedge clk) begin
        integer byte_index;
        ddram_read_data_ready <= 1'b0;

        if (reset) begin
            read_pending <= 1'b0;
        end else if (read_pending) begin
            ddram_read_data <= memory[pending_read_address];
            ddram_read_data_ready <= 1'b1;
            read_pending <= 1'b0;
        end

        if (!reset && ddram_command_accepted && ddram_read) begin
            if (read_pending)
                $fatal(1, "ring overlapped DDR reads");
            pending_read_address <= ddram_address;
            read_pending <= 1'b1;
            accepted_reads <= accepted_reads + 1;
        end

        if (!reset && ddram_command_accepted && ddram_write) begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                if (ddram_byte_enable[byte_index])
                    memory[ddram_address][byte_index * 8 +: 8]
                        <= ddram_write_data[byte_index * 8 +: 8];
            accepted_writes <= accepted_writes + 1;
        end

        if (!reset && sound_cycles_valid)
            output_cycle_sum <= output_cycle_sum + sound_cycles;
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic publish_completion(
        input logic [31:0] source_id,
        input logic cpu_arm9
    );
        begin
            @(negedge clk);
            completion_epoch = EPOCH;
            completion_source_id = source_id;
            completion_cpu_arm9 = cpu_arm9;
            completion_valid = 1'b1;
            tick();
            @(negedge clk);
            completion_valid = 1'b0;
        end
    endtask

    task automatic publish_ring_record(
        input logic [31:0] sequence_value,
        input logic [31:0] source_id,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        integer slot;
        integer entry_base;
        begin
            slot = (sequence_value - 1) &
                   (ENTRY_COUNT - 1);
            entry_base = BASE_WORD + HEADER_WORDS64 +
                         slot * 3;
            @(negedge clk);
            memory[entry_base] =
                {cycles, source_id};
            memory[entry_base + 1] =
                {EPOCH, 29'd0, 2'b01, cpu_arm9};
            memory[entry_base + 2] =
                {32'd0, sequence_value};
        end
    endtask

    initial begin
        integer index;
        integer timeout;
        for (index = 0; index < 128; index = index + 1)
            memory[index] = 64'd0;

        // HPS prepares and release-publishes a fresh descriptor while both
        // sides are held quiescent.
        memory[BASE_WORD + 1] = {MAGIC, EPOCH};

        repeat (3)
            tick();
        @(negedge clk);
        reset = 1'b0;
        repeat (2)
            tick();
        if (sound_epoch_ready || !sound_shadow_reset)
            $fatal(1, "composition escaped reset without epoch");

        @(negedge clk);
        transport_quiescent = 1'b0;
        repeat (3)
            tick();
        @(negedge clk);
        transport_quiescent = 1'b1;
        epoch_request_valid = 1'b1;
        epoch_request = EPOCH;
        epoch_request_fresh = 1'b1;
        while (!epoch_request_ready)
            tick();
        tick();
        @(negedge clk);
        epoch_request_valid = 1'b0;
        epoch_request = 32'd0;
        epoch_request_fresh = 1'b0;

        timeout = 0;
        while (!sound_epoch_ready && timeout < 300) begin
            tick();
            timeout = timeout + 1;
        end
        if (!sound_epoch_ready ||
            coordinated_active_epoch != EPOCH ||
            ring_active_epoch != EPOCH ||
            broadcaster_active_epoch != EPOCH ||
            queue_active_epoch != EPOCH ||
            drain_active_epoch != EPOCH ||
            coordinator_protocol_error ||
            ring_protocol_error ||
            broadcaster_protocol_error ||
            queue_protocol_error ||
            drain_protocol_error)
            $fatal(1, "real-block epoch composition failed");

        // Ordinary/timing credits are released only after the matching
        // completion frontier exists.
        publish_completion(32'd1, 1'b1);
        publish_ring_record(32'd1, 32'd1, 1'b1, 32'd8);
        timeout = 0;
        while (ring_consumer_sequence != 1 && timeout < 300) begin
            tick();
            timeout = timeout + 1;
        end
        if (ring_consumer_sequence != 1)
            $fatal(1, "first real credit did not retire");

        // ARM7 advances the shared minimum from zero to eight; SCALE=2 must
        // deliver exactly sixteen cycles before the keyed token retires.
        publish_completion(32'd2, 1'b0);
        publish_ring_record(32'd2, 32'd2, 1'b0, 32'd8);
        timeout = 0;
        while ((ring_consumer_sequence != 2 ||
                output_cycle_sum != 16) && timeout < 500) begin
            tick();
            timeout = timeout + 1;
        end

        if (ring_consumer_sequence != 2 ||
            output_cycle_sum != 16 ||
            arm9_timestamp != 8 ||
            arm7_timestamp != 8 ||
            shared_timestamp != 8 ||
            queue_level != 0 ||
            queue_pending_sound_ack ||
            write_valid ||
            coordinator_protocol_error ||
            ring_protocol_error ||
            broadcaster_protocol_error ||
            queue_protocol_error ||
            drain_protocol_error ||
            drain_overflow || queue_capture_overflow ||
            premature_activity || terminal_fault) begin
            $display(
                "DEBUG seq=%0d sum=%0d t9=%0d t7=%0d shared=%0d level=%0d pending=%0b write=%0b coord=%0b ring=%0b bcast=%0b queue=%0b drain=%0b dov=%0b qov=%0b premature=%0b terminal=%0b fault=%02x",
                ring_consumer_sequence, output_cycle_sum,
                arm9_timestamp, arm7_timestamp, shared_timestamp,
                queue_level, queue_pending_sound_ack, write_valid,
                coordinator_protocol_error, ring_protocol_error,
                broadcaster_protocol_error, queue_protocol_error,
                drain_protocol_error, drain_overflow,
                queue_capture_overflow, premature_activity,
                terminal_fault, fault_code);
            $fatal(1,
                "real-block credit/drain composition mismatch");
        end

        if (accepted_reads < 10 || accepted_writes < 5)
            $fatal(1, "DDR validation/retirement was not exercised");

        $display(
            "PASS: ring, broadcaster, queue, and drain compose under one fail-closed epoch");
        $finish;
    end
endmodule
