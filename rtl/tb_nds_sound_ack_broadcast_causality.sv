module tb_nds_sound_ack_broadcast_causality;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 1;

    logic external_epoch_valid = 0;
    logic [31:0] external_epoch = 0;
    logic external_epoch_fresh = 1;
    logic broadcaster_epoch_ready;
    logic broadcaster_epoch_started;
    logic broadcaster_epoch_active;
    logic [31:0] broadcaster_active_epoch;
    logic coordinator_epoch_ready;
    logic coordinator_epoch_started;
    logic coordinator_epoch_active;
    logic [31:0] coordinator_active_epoch;
    logic queue_epoch_ready;
    logic queue_epoch_started;
    logic queue_epoch_active;
    logic [31:0] queue_active_epoch;
    wire external_epoch_ready =
        broadcaster_epoch_ready &&
        coordinator_epoch_ready &&
        queue_epoch_ready;

    logic external_ack_valid = 0;
    logic external_ack_ready;
    logic [31:0] external_ack_epoch = 0;
    logic [31:0] external_ack_sequence = 0;
    logic external_ack_cpu_arm9 = 0;
    logic [31:0] external_ack_cycles = 0;
    logic [1:0] external_ack_kind = 0;
    logic [31:0] external_ack_source_id = 0;

    logic queue_ack_valid;
    logic queue_ack_ready;
    logic [31:0] queue_ack_epoch;
    logic [31:0] queue_ack_sequence;
    logic queue_ack_cpu_arm9;
    logic [1:0] queue_ack_kind;
    logic [31:0] queue_ack_source_id;
    logic coordinator_credit_valid;
    logic coordinator_credit_ready;
    logic [31:0] coordinator_credit_epoch;
    logic [31:0] coordinator_credit_sequence;
    logic coordinator_credit_cpu_arm9;
    logic [31:0] coordinator_credit_cycles;
    logic [1:0] coordinator_credit_kind;
    logic broadcaster_busy;
    logic broadcaster_sequence_exhausted;
    logic broadcaster_protocol_error;

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
    integer queue_accepts = 0;
    integer coordinator_accepts = 0;
    integer upstream_retires = 0;
    logic [31:0] last_queue_sequence = 0;
    logic [31:0] last_coordinator_sequence = 0;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (!reset) begin
            if (sound_cycles_valid && sound_cycles_ready)
                scaled_sum <= scaled_sum + {24'd0, sound_cycles};
            if (queue_ack_valid && queue_ack_ready) begin
                queue_accepts <= queue_accepts + 1;
                last_queue_sequence <= queue_ack_sequence;
            end
            if (coordinator_credit_valid &&
                coordinator_credit_ready) begin
                coordinator_accepts <= coordinator_accepts + 1;
                last_coordinator_sequence <=
                    coordinator_credit_sequence;
            end
            if (external_ack_valid && external_ack_ready)
                upstream_retires <= upstream_retires + 1;

            if (external_ack_ready &&
                (last_queue_sequence != external_ack_sequence ||
                 last_coordinator_sequence != external_ack_sequence))
                $fatal(1,
                    "upstream retired before both retained consumers");
        end
    end

    nds_sound_ack_broadcaster broadcaster (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(external_epoch_valid),
        .epoch_begin_ready(broadcaster_epoch_ready),
        .epoch_begin(external_epoch),
        .epoch_begin_fresh(external_epoch_fresh),
        .epoch_started(broadcaster_epoch_started),
        .epoch_active(broadcaster_epoch_active),
        .active_epoch(broadcaster_active_epoch),
        .ack_valid(external_ack_valid),
        .ack_ready(external_ack_ready),
        .ack_epoch(external_ack_epoch),
        .ack_sequence(external_ack_sequence),
        .ack_cpu_arm9(external_ack_cpu_arm9),
        .ack_cycles(external_ack_cycles),
        .ack_kind(external_ack_kind),
        .ack_source_id(external_ack_source_id),
        .queue_ack_valid,
        .queue_ack_ready,
        .queue_ack_epoch,
        .queue_ack_sequence,
        .queue_ack_cpu_arm9,
        .queue_ack_kind,
        .queue_ack_source_id,
        .credit_valid(coordinator_credit_valid),
        .credit_ready(coordinator_credit_ready),
        .credit_epoch(coordinator_credit_epoch),
        .credit_ack_sequence(coordinator_credit_sequence),
        .credit_cpu_arm9(coordinator_credit_cpu_arm9),
        .credit_cycles(coordinator_credit_cycles),
        .credit_kind(coordinator_credit_kind),
        .busy(broadcaster_busy),
        .sequence_exhausted(broadcaster_sequence_exhausted),
        .protocol_error(broadcaster_protocol_error)
    );

    nds_sound_credit_drain_coordinator coordinator (
        .clk,
        .reset,
        .transport_quiescent,
        .epoch_begin_valid(external_epoch_valid),
        .epoch_begin_ready(coordinator_epoch_ready),
        .epoch_begin(external_epoch),
        .epoch_begin_fresh(external_epoch_fresh),
        .epoch_started(coordinator_epoch_started),
        .epoch_active(coordinator_epoch_active),
        .active_epoch(coordinator_active_epoch),
        .credit_valid(coordinator_credit_valid),
        .credit_ready(coordinator_credit_ready),
        .credit_epoch(coordinator_credit_epoch),
        .credit_ack_sequence(coordinator_credit_sequence),
        .credit_cpu_arm9(coordinator_credit_cpu_arm9),
        .credit_cycles(coordinator_credit_cycles),
        .credit_kind(coordinator_credit_kind),
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
        .epoch_begin_valid(external_epoch_valid),
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

    task automatic start_epoch;
        begin
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            external_epoch = 32'h44aa8801;
            wait (external_epoch_ready);
            @(negedge clk);
            external_epoch_valid = 1;
            @(posedge clk);
            @(negedge clk);
            external_epoch_valid = 0;
            external_epoch = 0;
            while (broadcaster_epoch_started ||
                   coordinator_epoch_started ||
                   queue_epoch_started)
                @(posedge clk);
        end
    endtask

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

    task automatic present_ack(
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        begin
            @(negedge clk);
            external_ack_valid = 1;
            external_ack_epoch = broadcaster_active_epoch;
            external_ack_sequence = seq;
            external_ack_cpu_arm9 = cpu_arm9;
            external_ack_cycles = cycles;
            external_ack_kind = kind;
            external_ack_source_id = source_id;
        end
    endtask

    task automatic finish_ack;
        begin
            do @(posedge clk); while (!external_ack_ready);
            @(negedge clk);
            external_ack_valid = 0;
            external_ack_epoch = 0;
            external_ack_sequence = 0;
            external_ack_cpu_arm9 = 0;
            external_ack_cycles = 0;
            external_ack_kind = 0;
            external_ack_source_id = 0;
        end
    endtask

    task automatic require_clean;
        begin
            #1;
            if (broadcaster_protocol_error ||
                coordinator_protocol_error || coordinator_overflow ||
                queue_protocol_error || capture_overflow ||
                broadcaster_sequence_exhausted ||
                coordinator_sequence_exhausted ||
                queue_sequence_exhausted)
                $fatal(1, "composed ACK path faulted");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        start_epoch();
        require_clean();
        if (!broadcaster_epoch_active ||
            !coordinator_epoch_active || !queue_epoch_active ||
            broadcaster_active_epoch != 32'h44aa8801 ||
            coordinator_active_epoch != 32'h44aa8801 ||
            queue_active_epoch != 32'h44aa8801)
            $fatal(1, "composed epoch did not start atomically");

        // Prime ARM9 ahead; min(ARM9, ARM7) remains zero.
        complete_mailbox(1, 1, 1, 2, 32'h04000006, 0);
        present_ack(1, 1, 100, 1, 1);
        finish_ack();
        wait (!coordinator_busy);
        @(posedge clk);
        #1;
        if (scaled_sum != 0)
            $fatal(1, "min-unchanged ARM9 prime generated cycles");

        // ARM7 catches up, creating 100 shared cycles / 200 sound cycles.
        // Stall that time stream after both consumers have accepted ACK 2.
        sound_cycles_ready = 0;
        complete_mailbox(2, 0, 1, 2, 32'h04000006, 0);
        present_ack(2, 0, 100, 1, 2);
        finish_ack();
        repeat (20) begin
            @(posedge clk);
            #1;
            if (!coordinator_busy || scaled_sum != 0)
                $fatal(1, "stalled ACK 2 time escaped");
        end

        // While the coordinator is busy, ACK 3 reaches the queue first and is
        // retained for the coordinator without duplicate queue acceptance.
        complete_mailbox(3, 1, 1, 2, 32'h04000006, 0);
        present_ack(3, 1, 200, 1, 3);
        wait (queue_accepts == 3);
        repeat (61) begin
            @(posedge clk);
            #1;
            if (coordinator_accepts != 2 || external_ack_ready ||
                queue_ack_valid || !coordinator_credit_valid ||
                queue_accepts != 3)
                $fatal(1, "queue-first composed record was lost/retired");
        end
        @(negedge clk);
        sound_cycles_ready = 1;
        finish_ack();
        wait (!coordinator_busy);
        @(posedge clk);
        #1;
        if (scaled_sum != 200 || queue_accepts != 3 ||
            coordinator_accepts != 3)
            $fatal(1, "queue-first catch-up mismatch");

        // This completed ARM7 sound write advances shared time by 200, hence
        // 400 scaled cycles.  The retained register write may not appear
        // while that time stream is stalled, even though both ACK consumers
        // and upstream retirement have completed.
        complete_mailbox(
            4, 0, 0, 1, 32'h04000402, 32'h89abcdef);
        sound_cycles_ready = 0;
        present_ack(4, 0, 200, 1, 4);
        finish_ack();
        repeat (73) begin
            @(posedge clk);
            #1;
            if (write_valid || !pending_sound_ack ||
                scaled_sum != 200)
                $fatal(1,
                    "ordered sound write escaped before scaled-time drain");
        end
        @(negedge clk);
        sound_cycles_ready = 1;
        wait (write_valid);
        #1;
        if (queue_accepts != 4 || coordinator_accepts != 4 ||
            scaled_sum != 600 ||
            write_epoch != 32'h44aa8801 ||
            write_source_id != 4 ||
            write_address != 32'h04000402 ||
            write_access != 1 ||
            write_data != 32'h89abcdef)
            $fatal(1, "causally released sound write mismatch");

        // Keep that write backpressured.  The coordinator accepts a zero-cycle
        // ARM7 halt ACK first, but its token cannot pass the queue before the
        // queue has accepted the same retained ACK.
        complete_mailbox(5, 0, 1, 2, 32'h04000301, 0);
        present_ack(5, 0, 0, 2, 5);
        wait (coordinator_accepts == 5);
        repeat (89) begin
            @(posedge clk);
            #1;
            if (queue_accepts != 4 || external_ack_ready ||
                !queue_ack_valid || coordinator_credit_valid ||
                !write_valid)
                $fatal(1,
                    "coordinator-first halt record duplicated/retired");
        end

        @(negedge clk);
        write_ready = 1;
        @(posedge clk);
        @(negedge clk);
        write_ready = 0;
        finish_ack();
        wait (!coordinator_busy);
        @(posedge clk);
        #1;
        require_clean();

        if (write_valid || pending_sound_ack || queue_level != 0 ||
            broadcaster_busy || coordinator_busy ||
            queue_accepts != 5 || coordinator_accepts != 5 ||
            upstream_retires != 5 || scaled_sum != 600 ||
            last_queue_sequence != 5 ||
            last_coordinator_sequence != 5)
            $fatal(1, "composed broadcaster/queue/coordinator final mismatch");

        $display(
            "PASS: retained fanout orders sound writes behind both ACK consumers and fully accepted SCALE=2 time, including min-unchanged and halt ACKs");
        $finish;
    end
endmodule
