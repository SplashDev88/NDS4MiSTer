module tb_nds_sound_direct_causality_late_epoch;
    localparam logic [28:0] MAILBOX_BASE_WORD = 29'h00300000;
    localparam logic [28:0] POSTED_BASE_WORD = 29'h00310000;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic transport_quiescent = 1'b1;

    logic shadow_feature_enable = 1'b0;
    logic epoch_contract_active = 1'b0;
    logic epoch_contract_fresh = 1'b0;
    logic [31:0] epoch_contract = 32'd0;

    logic external_epoch_valid = 1'b0;
    logic [31:0] external_epoch = 32'd0;
    logic external_epoch_fresh = 1'b0;
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

    logic posted_request = 1'b0;
    logic posted_cpu_arm9 = 1'b0;
    logic [31:0] posted_elapsed_cycles = 32'd0;
    logic [31:0] posted_address = 32'd0;
    logic [1:0] posted_access = 2'd0;
    logic [31:0] posted_write_data = 32'd0;
    logic posted_accepted;
    logic posted_active;
    logic posted_ddram_active;
    logic posted_done;
    logic [31:0] posted_producer_sequence;
    logic posted_sequence_exhausted;
    logic posted_ddram_read;
    logic posted_ddram_write;
    logic [7:0] posted_ddram_burst_count;
    logic [28:0] posted_ddram_address;
    logic [63:0] posted_ddram_write_data;
    logic [7:0] posted_ddram_byte_enable;

    logic posted_acceptance_valid;
    logic [31:0] posted_acceptance_epoch;
    logic posted_acceptance_cpu_arm9;
    logic [31:0] posted_acceptance_cycles;
    logic [31:0] posted_acceptance_producer_sequence;
    logic acceptance_owner_active;
    logic acceptance_protocol_error;
    logic [7:0] acceptance_fault_code;

    logic mailbox_request = 1'b0;
    logic mailbox_cpu_arm9 = 1'b0;
    logic [31:0] mailbox_elapsed_cycles = 32'd0;
    logic [31:0] mailbox_fence_sequence = 32'd0;
    logic [31:0] mailbox_address = 32'd0;
    logic mailbox_read_not_write = 1'b0;
    logic [1:0] mailbox_access = 2'd0;
    logic [31:0] mailbox_write_data = 32'd0;
    logic [31:0] mailbox_read_data;
    logic mailbox_irq_arm9;
    logic mailbox_irq_arm7;
    logic mailbox_halt_arm9;
    logic mailbox_halt_arm7;
    logic mailbox_done;
    logic [31:0] mailbox_completed_fence_sequence;
    logic [3:0] mailbox_debug_state;
    logic mailbox_ddram_read;
    logic mailbox_ddram_write;
    logic [7:0] mailbox_ddram_burst_count;
    logic [28:0] mailbox_ddram_address;
    logic [63:0] mailbox_ddram_write_data;
    logic [7:0] mailbox_ddram_byte_enable;
    logic [63:0] mailbox_ddram_read_data = 64'd0;
    logic mailbox_ddram_read_data_ready = 1'b0;

    logic mailbox_shadow_session_active;
    logic [31:0] mailbox_shadow_active_epoch;
    logic mailbox_epoch_seed_valid;
    logic [31:0] mailbox_epoch_next_source_generation;
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
    logic mailbox_credit_valid;
    logic mailbox_credit_ready;
    logic [31:0] mailbox_credit_epoch;
    logic [31:0] mailbox_credit_source_generation;
    logic mailbox_credit_cpu_arm9;
    logic [31:0] mailbox_credit_elapsed_cycles;
    logic [31:0] mailbox_credit_completed_fence_sequence;
    logic mailbox_credit_read_not_write;
    logic [1:0] mailbox_credit_access;
    logic [31:0] mailbox_credit_address;
    logic [31:0] mailbox_credit_write_data;
    logic [3:0] mailbox_credit_level;
    logic mailbox_tap_owner_active;
    logic mailbox_capture_overflow;
    logic mailbox_sequence_exhausted;
    logic mailbox_generation_desynchronized;
    logic mailbox_tap_protocol_error;
    logic [7:0] mailbox_tap_fault_code;

    logic merge_shadow_session_active;
    logic [31:0] merge_shadow_active_epoch;
    logic merged_credit_valid;
    logic merged_credit_ready;
    logic [31:0] merged_credit_epoch;
    logic [31:0] merged_credit_ack_sequence;
    logic merged_credit_cpu_arm9;
    logic [31:0] merged_credit_cycles;
    logic [1:0] merged_credit_kind;
    logic [31:0] merged_credit_source_id;
    logic [31:0] merged_credit_completed_fence_sequence;
    logic [4:0] merge_ledger_level;
    logic merge_mailbox_pending;
    logic [31:0] merge_last_completed_fence_sequence;
    logic merge_capture_overflow;
    logic merge_posted_sequence_exhausted;
    logic merge_ack_sequence_exhausted;
    logic merge_protocol_error;
    logic [7:0] merge_fault_code;

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

    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic sound_cycles_ready = 1'b1;
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
    logic write_ready = 1'b0;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [4:0] write_queue_level;
    logic pending_sound_ack;
    logic write_capture_overflow;
    logic write_sequence_exhausted;
    logic write_protocol_error;

    logic [63:0] mailbox_memory [0:4];
    logic mailbox_second_word_pending = 1'b0;

    integer completion_count = 0;
    integer acceptance_count = 0;
    integer merged_count = 0;
    integer write_count = 0;
    integer scaled_sum = 0;
    logic [1:0] observed_kind [0:1];
    logic [31:0] observed_source [0:1];
    logic [31:0] observed_ack [0:1];
    integer case_count = 0;

    always #5 clk = ~clk;

    nds_hps_posted_write_ring #(
        .BASE_WORD(POSTED_BASE_WORD),
        .ENTRY_COUNT(32)
    ) posted_ring (
        .clk,
        .reset,
        .request(posted_request),
        .cpu_is_arm9(posted_cpu_arm9),
        .elapsed_cycles(posted_elapsed_cycles),
        .address(posted_address),
        .access(posted_access),
        .write_data(posted_write_data),
        .session_epoch(32'h0),
        .session_capabilities(32'h0),
        .consumer_ack(mailbox_done),
        .consumer_ack_epoch(32'h0),
        .consumer_ack_sequence(mailbox_completed_fence_sequence),
        .accepted(posted_accepted),
        .active(posted_active),
        .ddram_active(posted_ddram_active),
        .done(posted_done),
        .producer_sequence(posted_producer_sequence),
        .sequence_exhausted(posted_sequence_exhausted),
        .ddram_read(posted_ddram_read),
        .ddram_write(posted_ddram_write),
        .ddram_burst_count(posted_ddram_burst_count),
        .ddram_address(posted_ddram_address),
        .ddram_write_data(posted_ddram_write_data),
        .ddram_byte_enable(posted_ddram_byte_enable),
        .ddram_busy(1'b0),
        .ddram_command_accepted(1'b1),
        .ddram_read_data(64'd0),
        .ddram_read_data_ready(1'b0)
    );

    nds_sound_posted_acceptance_tap posted_tap (
        .clk,
        .reset,
        .shadow_feature_enable,
        .shadow_session_active(merge_shadow_session_active),
        .shadow_active_epoch(merge_shadow_active_epoch),
        .posted_request,
        .posted_active,
        .posted_accepted,
        .posted_sequence_exhausted,
        .posted_producer_sequence,
        .posted_cpu_arm9,
        .posted_elapsed_cycles,
        .acceptance_valid(posted_acceptance_valid),
        .acceptance_epoch(posted_acceptance_epoch),
        .acceptance_cpu_arm9(posted_acceptance_cpu_arm9),
        .acceptance_cycles(posted_acceptance_cycles),
        .acceptance_producer_sequence(
            posted_acceptance_producer_sequence),
        .owner_active(acceptance_owner_active),
        .protocol_error(acceptance_protocol_error),
        .fault_code(acceptance_fault_code)
    );

    nds_hps_oracle_mailbox #(
        .BASE_WORD(MAILBOX_BASE_WORD),
        .POLL_DELAY_CYCLES(1)
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
        .ddram_read(mailbox_ddram_read),
        .ddram_write(mailbox_ddram_write),
        .ddram_burst_count(mailbox_ddram_burst_count),
        .ddram_address(mailbox_ddram_address),
        .ddram_write_data(mailbox_ddram_write_data),
        .ddram_byte_enable(mailbox_ddram_byte_enable),
        .ddram_busy(1'b0),
        .ddram_read_data(mailbox_ddram_read_data),
        .ddram_read_data_ready(mailbox_ddram_read_data_ready)
    );

    nds_sound_mailbox_completion_tap #(
        .CREDIT_DEPTH(8),
        .USE_EXPLICIT_LAUNCH(1'b0)
    ) mailbox_tap (
        .clk,
        .reset,
        .shadow_feature_enable,
        .transport_quiescent,
        .epoch_contract_active,
        .epoch_contract_fresh,
        .epoch_contract,
        .shadow_session_active(mailbox_shadow_session_active),
        .shadow_active_epoch(mailbox_shadow_active_epoch),
        .epoch_seed_valid(mailbox_epoch_seed_valid),
        .epoch_next_source_generation(
            mailbox_epoch_next_source_generation),
        .mailbox_explicit_launch(1'b0),
        .mailbox_request,
        .mailbox_debug_state,
        .mailbox_cpu_arm9,
        .mailbox_elapsed_cycles,
        .mailbox_fence_sequence,
        .mailbox_address,
        .mailbox_read_not_write,
        .mailbox_access,
        .mailbox_write_data,
        .mailbox_done,
        .mailbox_completed_fence_sequence,
        .completion_valid,
        .completion_epoch,
        .completion_source_id,
        .completion_cpu_arm9,
        .completion_elapsed_cycles,
        .completion_completed_fence_sequence,
        .completion_read_not_write,
        .completion_access,
        .completion_address,
        .completion_write_data,
        .credit_valid(mailbox_credit_valid),
        .credit_ready(mailbox_credit_ready),
        .credit_epoch(mailbox_credit_epoch),
        .credit_source_generation(
            mailbox_credit_source_generation),
        .credit_cpu_arm9(mailbox_credit_cpu_arm9),
        .credit_elapsed_cycles(mailbox_credit_elapsed_cycles),
        .credit_completed_fence_sequence(
            mailbox_credit_completed_fence_sequence),
        .credit_read_not_write(mailbox_credit_read_not_write),
        .credit_access(mailbox_credit_access),
        .credit_address(mailbox_credit_address),
        .credit_write_data(mailbox_credit_write_data),
        .credit_level(mailbox_credit_level),
        .owner_active(mailbox_tap_owner_active),
        .capture_overflow(mailbox_capture_overflow),
        .sequence_exhausted(mailbox_sequence_exhausted),
        .generation_desynchronized(
            mailbox_generation_desynchronized),
        .protocol_error(mailbox_tap_protocol_error),
        .fault_code(mailbox_tap_fault_code)
    );

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(16),
        .FIRST_ACK_SEQUENCE(32'd1)
    ) merge (
        .clk,
        .reset,
        .shadow_feature_enable,
        .transport_quiescent,
        .epoch_contract_active,
        .epoch_contract_fresh,
        .epoch_contract,
        .epoch_base_posted_sequence(posted_producer_sequence),
        .shadow_session_active(merge_shadow_session_active),
        .shadow_active_epoch(merge_shadow_active_epoch),
        .posted_accept_valid(posted_acceptance_valid),
        .posted_accept_epoch(posted_acceptance_epoch),
        .posted_accept_cpu_arm9(posted_acceptance_cpu_arm9),
        .posted_accept_cycles(posted_acceptance_cycles),
        .posted_accept_producer_sequence(
            posted_acceptance_producer_sequence),
        .direct_credit_valid(mailbox_credit_valid),
        .direct_credit_ready(mailbox_credit_ready),
        .direct_credit_epoch(mailbox_credit_epoch),
        .direct_credit_source_generation(
            mailbox_credit_source_generation),
        .direct_credit_cpu_arm9(mailbox_credit_cpu_arm9),
        .direct_credit_cycles(mailbox_credit_elapsed_cycles),
        .direct_credit_kind(2'b01),
        .direct_credit_completed_fence_sequence(
            mailbox_credit_completed_fence_sequence),
        .simulation_inject_missing_posted(1'b0),
        .merged_credit_valid,
        .merged_credit_ready,
        .merged_credit_epoch,
        .merged_credit_ack_sequence,
        .merged_credit_cpu_arm9,
        .merged_credit_cycles,
        .merged_credit_kind,
        .merged_credit_source_id,
        .merged_credit_completed_fence_sequence,
        .ledger_level(merge_ledger_level),
        .mailbox_pending(merge_mailbox_pending),
        .last_completed_fence_sequence(
            merge_last_completed_fence_sequence),
        .capture_overflow(merge_capture_overflow),
        .posted_sequence_exhausted(
            merge_posted_sequence_exhausted),
        .ack_sequence_exhausted(merge_ack_sequence_exhausted),
        .protocol_error(merge_protocol_error),
        .fault_code(merge_fault_code)
    );

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
        .ack_valid(merged_credit_valid),
        .ack_ready(merged_credit_ready),
        .ack_epoch(merged_credit_epoch),
        .ack_sequence(merged_credit_ack_sequence),
        .ack_cpu_arm9(merged_credit_cpu_arm9),
        .ack_cycles(merged_credit_cycles),
        .ack_kind(merged_credit_kind),
        .ack_source_id(merged_credit_source_id),
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

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(16),
        .RUNTIME_EPOCH_SEEDS(1'b1)
    ) write_queue (
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
        .epoch_seed_valid(mailbox_epoch_seed_valid),
        .epoch_seed_mailbox_source_id(
            mailbox_epoch_next_source_generation),
        .epoch_seed_posted_base_sequence(
            posted_producer_sequence),
        .epoch_seed_global_sequence(32'd1),
        .epoch_runtime_contract_active(epoch_contract_active),
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
        .queue_level(write_queue_level),
        .pending_sound_ack,
        .capture_overflow(write_capture_overflow),
        .sequence_exhausted(write_sequence_exhausted),
        .protocol_error(write_protocol_error)
    );

    always @(posedge clk) begin
        if (reset) begin
            mailbox_ddram_read_data <= 64'd0;
            mailbox_ddram_read_data_ready <= 1'b0;
            mailbox_second_word_pending <= 1'b0;
            mailbox_memory[0] <= 64'd0;
            mailbox_memory[1] <= 64'd0;
            mailbox_memory[2] <= 64'd0;
            mailbox_memory[3] <= 64'd0;
            mailbox_memory[4] <= 64'd0;
        end else begin
            mailbox_ddram_read_data_ready <= 1'b0;

            if (mailbox_ddram_write) begin
                if (mailbox_ddram_address < MAILBOX_BASE_WORD ||
                    mailbox_ddram_address > MAILBOX_BASE_WORD + 4)
                    $fatal(1, "mailbox DDR write escaped aperture");
                case (mailbox_ddram_address)
                    MAILBOX_BASE_WORD + 0:
                        mailbox_memory[0] <= mailbox_ddram_write_data;
                    MAILBOX_BASE_WORD + 1:
                        mailbox_memory[1] <= mailbox_ddram_write_data;
                    MAILBOX_BASE_WORD + 2:
                        mailbox_memory[2] <= mailbox_ddram_write_data;
                    MAILBOX_BASE_WORD + 3:
                        mailbox_memory[3] <= mailbox_ddram_write_data;
                    MAILBOX_BASE_WORD + 4:
                        mailbox_memory[4] <= mailbox_ddram_write_data;
                    default: begin end
                endcase
            end

            if (mailbox_ddram_read) begin
                if (mailbox_ddram_burst_count != 8'd2)
                    $fatal(1, "mailbox response was not a two-word burst");
                mailbox_ddram_read_data_ready <= 1'b1;
                mailbox_ddram_read_data <=
                    {mailbox_memory[0][63:32], 32'h01020304};
                mailbox_second_word_pending <= 1'b1;
            end else if (mailbox_second_word_pending) begin
                mailbox_ddram_read_data_ready <= 1'b1;
                mailbox_ddram_read_data <= 64'h0000000000000003;
                mailbox_second_word_pending <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            completion_count <= 0;
            acceptance_count <= 0;
            merged_count <= 0;
            write_count <= 0;
            scaled_sum <= 0;
            observed_kind[0] <= 2'd0;
            observed_kind[1] <= 2'd0;
            observed_source[0] <= 32'd0;
            observed_source[1] <= 32'd0;
            observed_ack[0] <= 32'd0;
            observed_ack[1] <= 32'd0;
        end else begin
            if (posted_ddram_read)
                $fatal(1, "bounded real posted ring unexpectedly polled");
            if (completion_valid)
                completion_count <= completion_count + 1;
            if (posted_acceptance_valid)
                acceptance_count <= acceptance_count + 1;
            if (merged_credit_valid && merged_credit_ready) begin
                if (merged_count >= 2)
                    $fatal(1, "global merge emitted too many records");
                observed_kind[merged_count] <= merged_credit_kind;
                observed_source[merged_count] <=
                    merged_credit_source_id;
                observed_ack[merged_count] <=
                    merged_credit_ack_sequence;
                merged_count <= merged_count + 1;
            end
            if (sound_cycles_valid && sound_cycles_ready)
                scaled_sum <= scaled_sum + sound_cycles;
            if (write_valid && write_ready)
                write_count <= write_count + 1;
        end
    end

    task automatic clear_driven_inputs;
        begin
            shadow_feature_enable = 1'b0;
            epoch_contract_active = 1'b0;
            epoch_contract_fresh = 1'b0;
            epoch_contract = 32'd0;
            external_epoch_valid = 1'b0;
            external_epoch = 32'd0;
            external_epoch_fresh = 1'b0;
            posted_request = 1'b0;
            posted_cpu_arm9 = 1'b0;
            posted_elapsed_cycles = 32'd0;
            posted_address = 32'd0;
            posted_access = 2'd0;
            posted_write_data = 32'd0;
            mailbox_request = 1'b0;
            mailbox_cpu_arm9 = 1'b0;
            mailbox_elapsed_cycles = 32'd0;
            mailbox_fence_sequence = 32'd0;
            mailbox_address = 32'd0;
            mailbox_read_not_write = 1'b0;
            mailbox_access = 2'd0;
            mailbox_write_data = 32'd0;
            sound_cycles_ready = 1'b1;
            write_ready = 1'b0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_driven_inputs();
            reset = 1'b1;
            transport_quiescent = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    task automatic issue_posted(
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data,
        input logic mutate_live
    );
        begin
            wait (!posted_active);
            @(negedge clk);
            posted_cpu_arm9 = cpu_arm9;
            posted_elapsed_cycles = cycles;
            posted_address = address;
            posted_access = access;
            posted_write_data = data;
            posted_request = 1'b1;
            @(posedge clk);
            if (mutate_live) begin
                @(negedge clk);
                posted_cpu_arm9 = ~cpu_arm9;
                posted_elapsed_cycles = 32'hdead0001;
                posted_address = 32'hdead0002;
                posted_access = 2'b11;
                posted_write_data = 32'hdead0003;
            end
            wait (posted_done);
            @(negedge clk);
            posted_request = 1'b0;
            wait (!posted_active);
            @(posedge clk);
        end
    endtask

    task automatic issue_mailbox(
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [31:0] fence,
        input logic [31:0] address,
        input logic rnw,
        input logic [1:0] access,
        input logic [31:0] data
    );
        begin
            wait (mailbox_debug_state == 4'd0);
            @(negedge clk);
            mailbox_cpu_arm9 = cpu_arm9;
            mailbox_elapsed_cycles = cycles;
            mailbox_fence_sequence = fence;
            mailbox_address = address;
            mailbox_read_not_write = rnw;
            mailbox_access = access;
            mailbox_write_data = data;
            mailbox_request = 1'b1;
            wait (mailbox_done);
            @(negedge clk);
            mailbox_request = 1'b0;
            wait (mailbox_debug_state == 4'd0);
            @(posedge clk);
        end
    endtask

    task automatic start_runtime_epoch(
        input logic [31:0] wanted_epoch,
        input logic [31:0] expected_mailbox_seed,
        input logic [31:0] expected_posted_base
    );
        begin
            @(negedge clk);
            transport_quiescent = 1'b0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1'b1;
            wait (external_epoch_ready && mailbox_epoch_seed_valid);
            #1;
            if (mailbox_epoch_next_source_generation !=
                    expected_mailbox_seed ||
                posted_producer_sequence != expected_posted_base)
                $fatal(1,
                    "late epoch seeds mismatch mailbox=%08x/%08x posted=%08x/%08x",
                    mailbox_epoch_next_source_generation,
                    expected_mailbox_seed,
                    posted_producer_sequence,
                    expected_posted_base);

            @(negedge clk);
            shadow_feature_enable = 1'b1;
            epoch_contract_active = 1'b1;
            epoch_contract_fresh = 1'b1;
            epoch_contract = wanted_epoch;
            external_epoch_valid = 1'b1;
            external_epoch = wanted_epoch;
            external_epoch_fresh = 1'b1;
            @(posedge clk);
            @(negedge clk);
            epoch_contract_fresh = 1'b0;
            external_epoch_valid = 1'b0;
            external_epoch = 32'd0;
            external_epoch_fresh = 1'b0;
            while (broadcaster_epoch_started ||
                   coordinator_epoch_started ||
                   queue_epoch_started)
                @(posedge clk);
            #1;
            if (!mailbox_shadow_session_active ||
                !merge_shadow_session_active ||
                !broadcaster_epoch_active ||
                !coordinator_epoch_active ||
                !queue_epoch_active ||
                mailbox_shadow_active_epoch != wanted_epoch ||
                merge_shadow_active_epoch != wanted_epoch ||
                broadcaster_active_epoch != wanted_epoch ||
                coordinator_active_epoch != wanted_epoch ||
                queue_active_epoch != wanted_epoch)
                $fatal(1, "late runtime epoch did not start atomically");
        end
    endtask

    task automatic require_clean;
        begin
            #1;
            if (posted_sequence_exhausted ||
                acceptance_protocol_error ||
                mailbox_capture_overflow ||
                mailbox_sequence_exhausted ||
                mailbox_generation_desynchronized ||
                mailbox_tap_protocol_error ||
                merge_capture_overflow ||
                merge_posted_sequence_exhausted ||
                merge_ack_sequence_exhausted ||
                merge_protocol_error ||
                broadcaster_sequence_exhausted ||
                broadcaster_protocol_error ||
                coordinator_sequence_exhausted ||
                coordinator_protocol_error ||
                coordinator_overflow ||
                write_capture_overflow ||
                write_sequence_exhausted ||
                write_protocol_error)
                $fatal(1,
                    "late direct causality path faulted tap=%02x merge=%02x accept=%02x",
                    mailbox_tap_fault_code,
                    merge_fault_code,
                    acceptance_fault_code);
        end
    endtask

    task automatic run_case(
        input integer disabled_mailboxes,
        input integer disabled_posted,
        input integer tag
    );
        integer i;
        logic [31:0] wanted_epoch;
        logic [31:0] mailbox_seed;
        logic [31:0] posted_base;
        logic [31:0] active_posted_sequence;
        logic [31:0] active_cycles;
        begin
            hard_reset();

            for (i = 0; i < disabled_posted; i = i + 1)
                issue_posted(
                    i[0], 32'h10 + i,
                    32'h04000100 + (i * 4),
                    2'b10, 32'h10000000 + i, 1'b0);
            posted_base = disabled_posted;

            for (i = 0; i < disabled_mailboxes; i = i + 1)
                issue_mailbox(
                    i[0], 32'h20 + i, posted_producer_sequence,
                    32'h04000200 + (i * 2),
                    1'b0, 2'b01, 32'h20000000 + i);

            repeat (3) @(posedge clk);
            if (completion_count != 0 || acceptance_count != 0 ||
                merged_count != 0 || write_count != 0 ||
                mailbox_credit_valid || protocol_error_before_epoch())
                $fatal(1,
                    "disabled traffic was not passive mailbox=%0d posted=%0d completion=%0d acceptance=%0d merged=%0d writes=%0d credit=%b errors=%b%b%b%b%b%b",
                    disabled_mailboxes, disabled_posted,
                    completion_count, acceptance_count, merged_count,
                    write_count, mailbox_credit_valid,
                    acceptance_protocol_error,
                    mailbox_tap_protocol_error, merge_protocol_error,
                    broadcaster_protocol_error,
                    coordinator_protocol_error, write_protocol_error);

            wanted_epoch = 32'hca750000 + tag;
            mailbox_seed = disabled_mailboxes + 1;
            start_runtime_epoch(
                wanted_epoch, mailbox_seed, posted_base);
            require_clean();

            active_cycles = 32'd19 + tag;
            issue_posted(
                1'b1, active_cycles, 32'h040001a0,
                2'b10, 32'hface0000 + tag, 1'b1);
            active_posted_sequence = posted_base + 1;
            wait (acceptance_count == 1);
            #1;
            if (posted_producer_sequence != active_posted_sequence ||
                posted_acceptance_epoch != wanted_epoch ||
                posted_acceptance_cpu_arm9 != 1'b1 ||
                posted_acceptance_cycles != active_cycles ||
                posted_acceptance_producer_sequence !=
                    active_posted_sequence)
                $fatal(1, "real posted acceptance metadata mismatch");

            issue_mailbox(
                1'b0, active_cycles, active_posted_sequence,
                32'h04000404, 1'b0, 2'b01,
                32'ha1b20000 + tag);
            wait (completion_count == 1);
            wait (write_valid);
            #1;

            if (completion_epoch != wanted_epoch ||
                completion_source_id != mailbox_seed ||
                completion_cpu_arm9 != 1'b0 ||
                completion_elapsed_cycles != active_cycles ||
                completion_completed_fence_sequence !=
                    active_posted_sequence ||
                completion_address != 32'h04000404 ||
                completion_read_not_write != 1'b0 ||
                completion_access != 2'b01 ||
                completion_write_data != 32'ha1b20000 + tag)
                $fatal(1, "real mailbox completion metadata mismatch");
            if (merged_count != 2 ||
                observed_kind[0] != 2'b00 ||
                observed_source[0] != active_posted_sequence ||
                observed_ack[0] != 32'd1 ||
                observed_kind[1] != 2'b01 ||
                observed_source[1] != mailbox_seed ||
                observed_ack[1] != 32'd2)
                $fatal(1,
                    "posted-before-mailbox merge order mismatch count=%0d",
                    merged_count);
            if (scaled_sum != (active_cycles * 2))
                $fatal(1,
                    "shared-time drain mismatch got=%0d expected=%0d",
                    scaled_sum, active_cycles * 2);
            if (write_epoch != wanted_epoch ||
                write_source_id != mailbox_seed ||
                write_address != 32'h04000404 ||
                write_access != 2'b01 ||
                write_data != 32'ha1b20000 + tag)
                $fatal(1, "exact retained sound write mismatch");

            @(negedge clk);
            write_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            write_ready = 1'b0;
            wait (!write_valid);
            #1;
            if (write_count != 1 || write_queue_level != 0 ||
                pending_sound_ack || merge_ledger_level != 0 ||
                mailbox_credit_level != 0 ||
                merge_mailbox_pending || broadcaster_busy ||
                coordinator_busy)
                $fatal(1, "causality path did not drain exactly once");
            require_clean();

            // A live runtime seed contract is mandatory for the entire epoch.
            // Losing it invalidates every late-start frontier and closes all
            // direct consumers before another output can escape.
            @(negedge clk);
            epoch_contract_active = 1'b0;
            @(posedge clk);
            @(posedge clk);
            #1;
            if (!mailbox_tap_protocol_error ||
                !merge_protocol_error ||
                !write_protocol_error ||
                mailbox_shadow_session_active ||
                merge_shadow_session_active ||
                queue_epoch_active ||
                write_valid)
                $fatal(1, "runtime epoch contract loss did not fail closed");

            case_count = case_count + 1;
        end
    endtask

    function automatic logic protocol_error_before_epoch;
        protocol_error_before_epoch =
            acceptance_protocol_error ||
            mailbox_tap_protocol_error ||
            merge_protocol_error ||
            broadcaster_protocol_error ||
            coordinator_protocol_error ||
            write_protocol_error;
    endfunction

    initial begin
        repeat (2) @(posedge clk);
        run_case(0, 2, 1);
        run_case(1, 3, 2);
        run_case(4, 7, 3);
        run_case(9, 11, 4);

        if (case_count != 4)
            $fatal(1, "not all varied late-epoch cases completed");
        $display(
            "PASS: real ring/mailbox late epochs seed exact source frontiers, merge posted before mailbox, drain shared time, and write once");
        $finish;
    end
endmodule
