module tb_nds_sound_credit_write_causality;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 1;
    logic external_epoch_valid = 0;
    logic [31:0] external_epoch = 0;
    logic external_epoch_fresh = 1;

    logic coordinator_epoch_valid;
    logic coordinator_epoch_ready;
    logic coordinator_epoch_started;
    logic coordinator_epoch_active;
    logic [31:0] coordinator_active_epoch;
    logic queue_epoch_valid;
    logic queue_epoch_ready;
    logic queue_epoch_started;
    logic queue_epoch_active;
    logic [31:0] queue_active_epoch;
    wire external_epoch_ready =
        coordinator_epoch_ready && queue_epoch_ready;
    assign coordinator_epoch_valid = external_epoch_valid;
    assign queue_epoch_valid = external_epoch_valid;

    logic external_ack_valid = 0;
    logic [31:0] external_ack_epoch = 0;
    logic [31:0] external_ack_sequence = 0;
    logic external_ack_cpu_arm9 = 0;
    logic [31:0] external_ack_cycles = 0;
    logic [1:0] external_ack_kind = 0;
    logic [31:0] external_ack_source_id = 0;
    logic coordinator_credit_valid;
    logic coordinator_credit_ready;
    logic queue_ack_valid;
    logic queue_ack_ready;
    wire external_ack_ready =
        coordinator_credit_ready && queue_ack_ready;
    // This focused composition schedules records only at boundaries where
    // both consumers are ready, then asserts the same valid beat to each.
    assign coordinator_credit_valid = external_ack_valid;
    assign queue_ack_valid = external_ack_valid;

    logic completion_valid = 0;
    logic [31:0] completion_epoch = 0;
    logic [31:0] completion_source_id = 0;
    logic completion_cpu_arm9 = 0;
    logic completion_read_not_write = 0;
    logic [1:0] completion_access = 0;
    logic [31:0] completion_address = 0;
    logic [31:0] completion_write_data = 0;

    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic sound_cycles_ready = 0;
    logic drain_token_valid;
    logic drain_token_ready;
    logic [31:0] drain_token_epoch;
    logic [31:0] drain_token_ack_sequence;
    logic [63:0] arm9_timestamp;
    logic [63:0] arm7_timestamp;
    logic [63:0] shared_timestamp;
    logic [63:0] remaining_delta_cycles;
    logic coordinator_busy;
    logic coordinator_sequence_exhausted;
    logic coordinator_protocol_error;
    logic coordinator_overflow;

    logic write_valid;
    logic write_ready = 0;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [4:0] queue_level;
    logic pending_sound_ack;
    logic capture_overflow;
    logic queue_sequence_exhausted;
    logic queue_protocol_error;

    integer scaled_sum = 0;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (!reset && sound_cycles_valid && sound_cycles_ready)
            scaled_sum <= scaled_sum + {24'd0, sound_cycles};
        if (!reset && external_ack_valid &&
            (coordinator_credit_ready != queue_ack_ready))
            $fatal(1, "composed ACK consumers disagreed on readiness");
    end

    nds_sound_credit_drain_coordinator coordinator (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(coordinator_epoch_valid),
        .epoch_begin_ready(coordinator_epoch_ready),
        .epoch_begin(external_epoch),
        .epoch_begin_fresh(external_epoch_fresh),
        .epoch_started(coordinator_epoch_started),
        .epoch_active(coordinator_epoch_active),
        .active_epoch(coordinator_active_epoch),
        .credit_valid(coordinator_credit_valid),
        .credit_ready(coordinator_credit_ready),
        .credit_epoch(external_ack_epoch),
        .credit_ack_sequence(external_ack_sequence),
        .credit_cpu_arm9(external_ack_cpu_arm9),
        .credit_cycles(external_ack_cycles),
        .credit_kind(external_ack_kind),
        .sound_cycles,
        .sound_cycles_valid,
        .sound_cycles_ready,
        .drain_token_valid,
        .drain_token_ready,
        .drain_token_epoch,
        .drain_token_ack_sequence,
        .arm9_timestamp,
        .arm7_timestamp,
        .shared_timestamp,
        .remaining_delta_cycles,
        .busy(coordinator_busy),
        .sequence_exhausted(coordinator_sequence_exhausted),
        .protocol_error(coordinator_protocol_error),
        .overflow(coordinator_overflow)
    );

    nds_sound_write_order_queue queue (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(queue_epoch_valid),
        .epoch_begin_ready(queue_epoch_ready),
        .epoch_begin(external_epoch),
        .epoch_begin_fresh(external_epoch_fresh),
        .epoch_started(queue_epoch_started),
        .epoch_active(queue_epoch_active),
        .active_epoch(queue_active_epoch),
        .epoch_seed_valid(1'b0),
        .epoch_seed_mailbox_source_id(32'd0),
        .epoch_seed_posted_base_sequence(32'd0),
        .epoch_seed_global_sequence(32'd0),
        .epoch_runtime_contract_active(1'b0),
        .completion_valid,
        .completion_epoch,
        .completion_source_id,
        .completion_cpu_arm9,
        .completion_read_not_write,
        .completion_access,
        .completion_address,
        .completion_write_data,
        .ack_valid(queue_ack_valid),
        .ack_ready(queue_ack_ready),
        .ack_epoch(external_ack_epoch),
        .ack_sequence(external_ack_sequence),
        .ack_cpu_arm9(external_ack_cpu_arm9),
        .ack_kind(external_ack_kind),
        .ack_source_id(external_ack_source_id),
        .drain_valid(drain_token_valid),
        .drain_ready(drain_token_ready),
        .drain_epoch(drain_token_epoch),
        .drain_ack_sequence(drain_token_ack_sequence),
        .write_valid,
        .write_ready,
        .write_epoch,
        .write_source_id,
        .write_address,
        .write_access,
        .write_data,
        .queue_level,
        .pending_sound_ack,
        .capture_overflow,
        .sequence_exhausted(queue_sequence_exhausted),
        .protocol_error(queue_protocol_error)
    );

    task automatic complete_mailbox(
        input logic [31:0] source_id,
        input logic cpu_arm9,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            completion_valid = 1;
            completion_epoch = queue_active_epoch;
            completion_source_id = source_id;
            completion_cpu_arm9 = cpu_arm9;
            completion_read_not_write = rnw;
            completion_access = access;
            completion_address = address;
            completion_write_data = data;
            @(posedge clk);
            @(negedge clk);
            completion_valid = 0;
        end
    endtask

    task automatic send_ack(
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] source_id
    );
        begin
            @(negedge clk);
            external_ack_valid = 1;
            external_ack_epoch = coordinator_active_epoch;
            external_ack_sequence = seq;
            external_ack_cpu_arm9 = cpu_arm9;
            external_ack_cycles = cycles;
            external_ack_kind = 2'b01;
            external_ack_source_id = source_id;
            do @(posedge clk); while (!external_ack_ready);
            @(negedge clk);
            external_ack_valid = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        external_epoch_valid = 1;
        external_epoch = 32'h55aa1234;
        do @(posedge clk); while (!external_epoch_ready);
        @(negedge clk);
        external_epoch_valid = 0;
        external_epoch = 0;
        while (coordinator_epoch_started || queue_epoch_started)
            @(posedge clk);

        // Prime ARM9 time through an unrelated completed mailbox.
        complete_mailbox(
            1, 1, 1, 2, 32'hffffffff, 32'h00000000);
        send_ack(1, 1, 100, 1);
        wait (!coordinator_busy);
        @(posedge clk);
        if (scaled_sum != 0 || write_valid || queue_level != 0)
            $fatal(1, "unrelated priming ACK created sound output/write");

        // Capture the sound write only at mailbox completion, then accept its
        // exact reverse ACK.  With the cycle consumer stalled, neither keyed
        // drain token nor register write may escape.
        complete_mailbox(
            2, 0, 0, 1, 32'h04000402, 32'h89abcdef);
        if (queue_level != 1)
            $fatal(1, "completed sound write was not queued");
        send_ack(2, 0, 100, 2);
        repeat (20) begin
            @(posedge clk);
            #1;
            if (!coordinator_busy || drain_token_valid || write_valid ||
                !pending_sound_ack)
                $fatal(1, "sound write escaped before scaled cycles drained");
        end

        sound_cycles_ready = 1;
        wait (write_valid);
        #1;
        if (scaled_sum != 200 ||
            write_epoch != 32'h55aa1234 ||
            write_source_id != 2 ||
            write_address != 32'h04000402 ||
            write_access != 1 ||
            write_data != 32'h89abcdef)
            $fatal(1, "composed scaled-time/write payload mismatch");
        repeat (4) begin
            @(posedge clk);
            #1;
            if (!write_valid || external_ack_ready)
                $fatal(1, "write output did not retain final causal barrier");
        end
        @(negedge clk);
        write_ready = 1;
        @(posedge clk);
        @(negedge clk);
        write_ready = 0;
        #1;

        if (write_valid || queue_level != 0 || pending_sound_ack ||
            coordinator_busy || coordinator_protocol_error ||
            coordinator_overflow || queue_protocol_error ||
            capture_overflow || coordinator_sequence_exhausted ||
            queue_sequence_exhausted)
            $fatal(1, "composed causality path did not finish cleanly");

        $display(
            "PASS: shared keyed drain token prevents completed sound writes from overtaking accepted SCALE=2 cycles");
        $finish;
    end
endmodule
