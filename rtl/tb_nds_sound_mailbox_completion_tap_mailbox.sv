module tb_nds_sound_mailbox_completion_tap_mailbox;
    localparam logic [28:0] BASE_WORD = 29'h00300000;

    logic clk = 0;
    logic reset = 1;

    logic shadow_feature_enable = 0;
    logic transport_quiescent = 1;
    logic epoch_contract_active = 0;
    logic epoch_contract_fresh = 0;
    logic [31:0] epoch_contract = 0;
    logic shadow_session_active;
    logic [31:0] shadow_active_epoch;
    logic epoch_seed_valid;
    logic [31:0] epoch_next_source_generation;

    logic mailbox_explicit_launch = 0;
    logic mailbox_request = 0;
    logic [3:0] mailbox_debug_state;
    logic mailbox_cpu_arm9 = 0;
    logic [31:0] mailbox_elapsed_cycles = 0;
    logic [31:0] mailbox_fence_sequence = 0;
    logic [31:0] mailbox_address = 0;
    logic mailbox_read_not_write = 0;
    logic [1:0] mailbox_access = 0;
    logic [31:0] mailbox_write_data = 0;
    logic mailbox_done;
    logic [31:0] mailbox_completed_fence_sequence;

    logic [31:0] mailbox_read_data;
    logic mailbox_irq_arm9;
    logic mailbox_irq_arm7;
    logic mailbox_halt_arm9;
    logic mailbox_halt_arm7;

    logic ddram_read;
    logic ddram_write;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic [63:0] ddram_write_data;
    logic [7:0] ddram_byte_enable;
    logic ddram_busy = 0;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;

    logic completion_valid;
    logic [31:0] completion_epoch;
    logic [31:0] completion_source_id;
    logic completion_cpu_arm9;
    logic [31:0] completion_elapsed_cycles;
    logic [31:0] completion_completed_fence_sequence;
    logic completion_read_not_write;
    logic [1:0] completion_access;
    logic [31:0] completion_address;
    logic [31:0] completion_write_data;
    logic credit_valid;
    logic credit_ready = 0;
    logic [31:0] credit_epoch;
    logic [31:0] credit_source_generation;
    logic credit_cpu_arm9;
    logic [31:0] credit_elapsed_cycles;
    logic [31:0] credit_completed_fence_sequence;
    logic credit_read_not_write;
    logic [1:0] credit_access;
    logic [31:0] credit_address;
    logic [31:0] credit_write_data;
    logic [2:0] credit_level;
    logic owner_active;
    logic capture_overflow;
    logic sequence_exhausted;
    logic generation_desynchronized;
    logic protocol_error;
    logic [7:0] fault_code;

    logic queue_epoch_begin_valid = 0;
    logic queue_epoch_begin_ready;
    logic [31:0] queue_epoch_begin = 0;
    logic queue_epoch_begin_fresh = 0;
    logic queue_epoch_started;
    logic queue_epoch_active;
    logic [31:0] queue_active_epoch;
    logic queue_ack_ready;
    logic queue_drain_ready;
    logic queue_write_valid;
    logic [31:0] queue_write_epoch;
    logic [31:0] queue_write_source_id;
    logic [31:0] queue_write_address;
    logic [1:0] queue_write_access;
    logic [31:0] queue_write_data;
    logic [2:0] queue_capture_level;
    logic queue_pending_sound_ack;
    logic queue_capture_overflow;
    logic queue_sequence_exhausted;
    logic queue_protocol_error;

    logic [63:0] memory [0:4];
    integer poll_issues = 0;
    integer transaction_poll_issues = 0;
    integer second_word_pending = 0;
    integer mailbox_done_count = 0;
    integer completion_count = 0;
    logic prior_mailbox_done = 0;
    logic active_transaction_under_test = 0;
    logic active_done_seen = 0;

    always #5 clk = ~clk;

    nds_hps_oracle_mailbox #(
        .BASE_WORD(BASE_WORD),
        .POLL_DELAY_CYCLES(2)
    ) mailbox_dut (
        .clk,
        .reset,
        .request(mailbox_request),
        .cpu_is_arm9(mailbox_cpu_arm9),
        .elapsed_cycles(mailbox_elapsed_cycles),
        .fence_sequence(mailbox_fence_sequence),
        .address(mailbox_address),
        .read_not_write(mailbox_read_not_write),
        .access(mailbox_access),
        .write_data(mailbox_write_data),
        .read_data(mailbox_read_data),
        .irq_arm9(mailbox_irq_arm9),
        .irq_arm7(mailbox_irq_arm7),
        .halt_arm9(mailbox_halt_arm9),
        .halt_arm7(mailbox_halt_arm7),
        .done(mailbox_done),
        .completed_fence_sequence(mailbox_completed_fence_sequence),
        .debug_state(mailbox_debug_state),
        .ddram_read,
        .ddram_write,
        .ddram_burst_count,
        .ddram_address,
        .ddram_write_data,
        .ddram_byte_enable,
        .ddram_busy,
        .ddram_read_data,
        .ddram_read_data_ready
    );

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(4),
        .USE_EXPLICIT_LAUNCH(1'b0)
    ) tap (.*);

    // Directly consume the no-ready completion pulse with the real write
    // ordering queue.  Source 1 occurred while the shadow was disabled, so
    // the first active completion is the mailbox's exact generation 2.
    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(4),
        .FIRST_COMPLETION_SOURCE_ID(32'd2),
        .FIRST_MAILBOX_SOURCE_ID(32'd2)
    ) queue_dut (
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
        .completion_valid,
        .completion_epoch,
        .completion_source_id,
        .completion_cpu_arm9,
        .completion_read_not_write,
        .completion_access,
        .completion_address,
        .completion_write_data,
        .ack_valid(1'b0),
        .ack_ready(queue_ack_ready),
        .ack_epoch(32'd0),
        .ack_sequence(32'd0),
        .ack_cpu_arm9(1'b0),
        .ack_kind(2'd0),
        .ack_source_id(32'd0),
        .drain_valid(1'b0),
        .drain_ready(queue_drain_ready),
        .drain_epoch(32'd0),
        .drain_ack_sequence(32'd0),
        .write_valid(queue_write_valid),
        .write_ready(1'b1),
        .write_epoch(queue_write_epoch),
        .write_source_id(queue_write_source_id),
        .write_address(queue_write_address),
        .write_access(queue_write_access),
        .write_data(queue_write_data),
        .queue_level(queue_capture_level),
        .pending_sound_ack(queue_pending_sound_ack),
        .capture_overflow(queue_capture_overflow),
        .sequence_exhausted(queue_sequence_exhausted),
        .protocol_error(queue_protocol_error)
    );

    always @(posedge clk) begin
        ddram_read_data_ready <= 0;

        if (ddram_write) begin
            if (ddram_address < BASE_WORD ||
                ddram_address > BASE_WORD + 4)
                $fatal(1, "mailbox DDR write escaped aperture");
            case (ddram_address)
                BASE_WORD + 0: memory[0] <= ddram_write_data;
                BASE_WORD + 1: memory[1] <= ddram_write_data;
                BASE_WORD + 2: memory[2] <= ddram_write_data;
                BASE_WORD + 3: memory[3] <= ddram_write_data;
                BASE_WORD + 4: memory[4] <= ddram_write_data;
                default: begin end
            endcase
            if (ddram_address == BASE_WORD)
                transaction_poll_issues <= 0;
        end

        if (ddram_read) begin
            if (ddram_burst_count != 2)
                $fatal(1, "mailbox response must remain a two-word burst");
            poll_issues <= poll_issues + 1;
            transaction_poll_issues <= transaction_poll_issues + 1;
            ddram_read_data_ready <= 1;
            second_word_pending <= 1;
            if (transaction_poll_issues == 0) begin
                // Deliberately stale generation.  The mailbox must consume
                // both words and poll again without asserting done.
                ddram_read_data <=
                    {memory[0][63:32] - 1'b1, 32'h11112222};
            end else begin
                ddram_read_data <=
                    {memory[0][63:32], 32'hcafebabe};
            end
        end else if (second_word_pending != 0) begin
            ddram_read_data_ready <= 1;
            second_word_pending <= 0;
            ddram_read_data <= 64'h0000000000000009;
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            if (completion_valid && !prior_mailbox_done)
                $fatal(1, "completion pulse was not caused by mailbox_done");
            if (active_transaction_under_test && !active_done_seen &&
                (completion_valid || credit_valid))
                $fatal(1, "stale/partial response emitted an early credit");
            if (mailbox_done) begin
                mailbox_done_count <= mailbox_done_count + 1;
                if (active_transaction_under_test)
                    active_done_seen <= 1;
            end
            if (completion_valid)
                completion_count <= completion_count + 1;
        end
        prior_mailbox_done <= mailbox_done;
    end

    task automatic issue_and_mutate(
        input logic cpu,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            wait (mailbox_debug_state == 0);
            @(negedge clk);
            mailbox_cpu_arm9 = cpu;
            mailbox_elapsed_cycles = cycles;
            mailbox_fence_sequence = fence;
            mailbox_address = address;
            mailbox_read_not_write = rnw;
            mailbox_access = access;
            mailbox_write_data = data;
            mailbox_request = 1;
            @(posedge clk);
            @(negedge clk);
            // These values remain live while request is held.  Neither the
            // real mailbox nor the sound tap may use them after launch.
            mailbox_cpu_arm9 = ~cpu;
            mailbox_elapsed_cycles = 32'hdead1001;
            mailbox_fence_sequence = 32'hdead1002;
            mailbox_address = 32'hdead1003;
            mailbox_read_not_write = ~rnw;
            mailbox_access = 2'b11;
            mailbox_write_data = 32'hdead1004;
        end
    endtask

    task automatic release_request;
        begin
            @(negedge clk);
            mailbox_request = 0;
            wait (mailbox_debug_state == 0);
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // First real mailbox transaction occurs while the observer is
        // disabled.  It must advance the mirrored source generation but emit
        // no completion or retained credit.
        issue_and_mutate(1, 32'h10, 32'h20, 32'h04000208, 0, 2'b01,
            32'h00000001);
        wait (mailbox_done);
        release_request();
        repeat (2) @(posedge clk);
        if (completion_valid || credit_valid || protocol_error ||
            generation_desynchronized)
            $fatal(1, "disabled real-mailbox transaction was not passive");

        @(negedge clk);
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        shadow_feature_enable = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        epoch_contract = 32'h0000bb01;
        queue_epoch_begin_valid = 1;
        queue_epoch_begin_fresh = 1;
        queue_epoch_begin = 32'h0000bb01;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        queue_epoch_begin_valid = 0;
        queue_epoch_begin_fresh = 0;
        queue_epoch_begin = 0;
        if (!shadow_session_active || !queue_epoch_active ||
            queue_active_epoch != 32'h0000bb01)
            $fatal(1, "active epoch contract/queue did not activate");

        active_transaction_under_test = 1;
        active_done_seen = 0;
        issue_and_mutate(0, 32'h12345678, 32'h89abcdef,
            32'h04000404, 0, 2'b01, 32'ha1b2c3d4);

        // The deliberately stale response has already been issued before the
        // valid second poll.  Neither it nor the matching result word alone
        // can create a credit; only response+IRQ mailbox_done may do so.
        wait (transaction_poll_issues >= 1);
        repeat (2) @(posedge clk);
        if (!active_done_seen && (completion_valid || credit_valid))
            $fatal(1, "stale poll emitted completion");

        wait (mailbox_done);
        #1;
        if (completion_valid || credit_valid)
            $fatal(1, "tap emitted on response edge before sampling done");
        release_request();
        wait (completion_valid);
        #1;
        if (completion_epoch != 32'h0000bb01 ||
            completion_source_id != 2 ||
            completion_cpu_arm9 != 0 ||
            completion_elapsed_cycles != 32'h12345678 ||
            completion_completed_fence_sequence != 32'h89abcdef ||
            completion_address != 32'h04000404 ||
            completion_read_not_write != 0 ||
            completion_access != 2'b01 ||
            completion_write_data != 32'ha1b2c3d4)
            $fatal(1, "real-mailbox completion metadata mismatch");
        if (!credit_valid ||
            credit_epoch != 32'h0000bb01 ||
            credit_source_generation != 2 ||
            credit_cpu_arm9 != 0 ||
            credit_elapsed_cycles != 32'h12345678 ||
            credit_completed_fence_sequence != 32'h89abcdef ||
            credit_address != 32'h04000404 ||
            credit_read_not_write != 0 ||
            credit_access != 2'b01 ||
            credit_write_data != 32'ha1b2c3d4)
            $fatal(1, "real-mailbox retained credit mismatch");
        if (transaction_poll_issues != 2)
            $fatal(1, "stale response was not rejected exactly once");

        // Downstream stall must retain the exact event.
        repeat (5) @(posedge clk);
        if (!credit_valid || credit_source_generation != 2 ||
            credit_completed_fence_sequence != 32'h89abcdef ||
            credit_write_data != 32'ha1b2c3d4)
            $fatal(1, "real-mailbox credit changed while stalled");
        if (queue_capture_level != 1 ||
            queue_protocol_error || queue_capture_overflow ||
            queue_sequence_exhausted)
            $fatal(1,
                "write-order queue did not consume exact completion pulse");
        @(negedge clk);
        credit_ready = 1;
        @(posedge clk);
        @(negedge clk);
        credit_ready = 0;
        active_transaction_under_test = 0;
        #1;
        if (credit_valid || credit_level != 0)
            $fatal(1, "real-mailbox credit did not retire");
        if (mailbox_done_count != 2 || completion_count != 1 ||
            poll_issues != 4)
            $fatal(1,
                "edge counts done=%0d completion=%0d polls=%0d",
                mailbox_done_count, completion_count, poll_issues);
        if (protocol_error || capture_overflow || sequence_exhausted ||
            queue_protocol_error)
            $fatal(1, "real-mailbox composition poisoned tap");

        $display("PASS: real mailbox stale polls cannot emit sound completion before response+IRQ done");
        $finish;
    end
endmodule
