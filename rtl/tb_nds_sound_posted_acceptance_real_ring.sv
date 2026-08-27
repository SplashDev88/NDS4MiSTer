module tb_nds_sound_posted_acceptance_real_ring;
    localparam integer LEDGER_DEPTH = 4;

    logic clk = 0;
    logic reset = 1;
    logic shadow_feature_enable = 0;
    logic transport_quiescent = 1;
    logic epoch_contract_active = 0;
    logic epoch_contract_fresh = 0;
    logic [31:0] epoch_contract = 0;
    logic [31:0] epoch_base_posted_sequence = 0;
    logic shadow_session_active;
    logic [31:0] shadow_active_epoch;

    logic posted_request = 0;
    logic posted_cpu_arm9 = 0;
    logic [31:0] posted_elapsed_cycles = 0;
    logic [31:0] posted_address = 0;
    logic [1:0] posted_access = 1;
    logic [31:0] posted_write_data = 0;
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
    logic posted_ddram_busy = 0;
    logic posted_ddram_command_accepted = 1;
    logic [63:0] posted_ddram_read_data = 0;
    logic posted_ddram_read_data_ready = 0;

    logic acceptance_valid;
    logic [31:0] acceptance_epoch;
    logic acceptance_cpu_arm9;
    logic [31:0] acceptance_cycles;
    logic [31:0] acceptance_producer_sequence;
    logic tap_owner_active;
    logic tap_protocol_error;
    logic [7:0] tap_fault_code;

    logic direct_credit_valid = 0;
    logic direct_credit_ready;
    logic [31:0] direct_credit_epoch = 0;
    logic [31:0] direct_credit_source_generation = 0;
    logic direct_credit_cpu_arm9 = 0;
    logic [31:0] direct_credit_cycles = 0;
    logic [1:0] direct_credit_kind = 1;
    logic [31:0] direct_credit_completed_fence_sequence = 0;
    logic simulation_inject_missing_posted = 0;
    logic merged_credit_valid;
    logic merged_credit_ready = 0;
    logic [31:0] merged_credit_epoch;
    logic [31:0] merged_credit_ack_sequence;
    logic merged_credit_cpu_arm9;
    logic [31:0] merged_credit_cycles;
    logic [1:0] merged_credit_kind;
    logic [31:0] merged_credit_source_id;
    logic [31:0] merged_credit_completed_fence_sequence;
    logic [$clog2(LEDGER_DEPTH + 1)-1:0] ledger_level;
    logic mailbox_pending;
    logic [31:0] last_completed_fence_sequence;
    logic capture_overflow;
    logic merge_posted_sequence_exhausted;
    logic ack_sequence_exhausted;
    logic merge_protocol_error;
    logic [7:0] merge_fault_code;

    integer acceptance_count = 0;
    logic [31:0] accepted_sequence_seen [0:1];
    logic accepted_cpu_seen [0:1];
    logic [31:0] accepted_cycles_seen [0:1];

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (!reset && acceptance_valid) begin
            if (acceptance_count >= 2)
                $fatal(1, "acceptance tap duplicated a ring acceptance");
            accepted_sequence_seen[acceptance_count] <=
                acceptance_producer_sequence;
            accepted_cpu_seen[acceptance_count] <=
                acceptance_cpu_arm9;
            accepted_cycles_seen[acceptance_count] <=
                acceptance_cycles;
            acceptance_count <= acceptance_count + 1;
        end
    end

    nds_hps_posted_write_ring #(
        .ENTRY_COUNT(4)
    ) ring (
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
        .consumer_ack(1'b0),
        .consumer_ack_epoch(32'h0),
        .consumer_ack_sequence(32'd0),
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
        .ddram_busy(posted_ddram_busy),
        .ddram_command_accepted(posted_ddram_command_accepted),
        .ddram_read_data(posted_ddram_read_data),
        .ddram_read_data_ready(posted_ddram_read_data_ready)
    );

    nds_sound_posted_acceptance_tap acceptance_tap (
        .clk,
        .reset,
        .shadow_feature_enable,
        .shadow_session_active,
        .shadow_active_epoch,
        .posted_request,
        .posted_active,
        .posted_accepted,
        .posted_sequence_exhausted,
        .posted_producer_sequence,
        .posted_cpu_arm9,
        .posted_elapsed_cycles,
        .acceptance_valid,
        .acceptance_epoch,
        .acceptance_cpu_arm9,
        .acceptance_cycles,
        .acceptance_producer_sequence,
        .owner_active(tap_owner_active),
        .protocol_error(tap_protocol_error),
        .fault_code(tap_fault_code)
    );

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(LEDGER_DEPTH)
    ) merge (
        .clk,
        .reset,
        .shadow_feature_enable,
        .transport_quiescent,
        .epoch_contract_active,
        .epoch_contract_fresh,
        .epoch_contract,
        .epoch_base_posted_sequence,
        .shadow_session_active,
        .shadow_active_epoch,
        .posted_accept_valid(acceptance_valid),
        .posted_accept_epoch(acceptance_epoch),
        .posted_accept_cpu_arm9(acceptance_cpu_arm9),
        .posted_accept_cycles(acceptance_cycles),
        .posted_accept_producer_sequence(
            acceptance_producer_sequence),
        .direct_credit_valid,
        .direct_credit_ready,
        .direct_credit_epoch,
        .direct_credit_source_generation,
        .direct_credit_cpu_arm9,
        .direct_credit_cycles,
        .direct_credit_kind,
        .direct_credit_completed_fence_sequence,
        .simulation_inject_missing_posted,
        .merged_credit_valid,
        .merged_credit_ready,
        .merged_credit_epoch,
        .merged_credit_ack_sequence,
        .merged_credit_cpu_arm9,
        .merged_credit_cycles,
        .merged_credit_kind,
        .merged_credit_source_id,
        .merged_credit_completed_fence_sequence,
        .ledger_level,
        .mailbox_pending,
        .last_completed_fence_sequence,
        .capture_overflow,
        .posted_sequence_exhausted(
            merge_posted_sequence_exhausted),
        .ack_sequence_exhausted,
        .protocol_error(merge_protocol_error),
        .fault_code(merge_fault_code)
    );

    task automatic issue_mutating_post(
        input logic launch_cpu,
        input logic [31:0] launch_cycles,
        input logic [31:0] launch_address,
        input logic mutated_cpu,
        input logic [31:0] mutated_cycles,
        input logic [31:0] mutated_address
    );
        begin
            @(negedge clk);
            posted_cpu_arm9 = launch_cpu;
            posted_elapsed_cycles = launch_cycles;
            posted_address = launch_address;
            posted_write_data = launch_cycles ^ launch_address;
            posted_request = 1;
            @(posedge clk);

            // The real ring and passive observer have now captured the
            // request.  Mutate every live field before CHECK_SPACE accepts.
            @(negedge clk);
            posted_cpu_arm9 = mutated_cpu;
            posted_elapsed_cycles = mutated_cycles;
            posted_address = mutated_address;
            posted_write_data = 32'hdeadbeef;

            while (!posted_done) @(posedge clk);
            @(negedge clk);
            posted_request = 0;
            while (posted_active) @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic consume(
        input logic [31:0] ack,
        input logic [1:0] kind,
        input logic [31:0] source,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            while (!merged_credit_valid) @(posedge clk);
            #1;
            if (merged_credit_ack_sequence != ack ||
                merged_credit_kind != kind ||
                merged_credit_source_id != source ||
                merged_credit_cpu_arm9 != cpu_arm9 ||
                merged_credit_cycles != cycles ||
                merged_credit_completed_fence_sequence != 2)
                $fatal(1,
                    "real-ring merged metadata mismatch ack=%h source=%h cpu=%b cycles=%h",
                    merged_credit_ack_sequence,
                    merged_credit_source_id,
                    merged_credit_cpu_arm9,
                    merged_credit_cycles);
            @(negedge clk);
            merged_credit_ready = 1;
            @(posedge clk);
            @(negedge clk);
            merged_credit_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        shadow_feature_enable = 1;
        transport_quiescent = 0;
        epoch_contract = 32'h7a000001;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        if (!shadow_session_active || merge_protocol_error)
            $fatal(1, "real-ring composition epoch failed");

        issue_mutating_post(
            1, 32'd111, 32'h0600c000,
            0, 32'hfeed0001, 32'h0600c100);
        issue_mutating_post(
            0, 32'd222, 32'h0600c002,
            1, 32'hfeed0002, 32'h0600c200);
        repeat (3) @(posedge clk);
        #1;
        if (acceptance_count != 2 ||
            accepted_sequence_seen[0] != 1 ||
            accepted_cpu_seen[0] != 1 ||
            accepted_cycles_seen[0] != 111 ||
            accepted_sequence_seen[1] != 2 ||
            accepted_cpu_seen[1] != 0 ||
            accepted_cycles_seen[1] != 222 ||
            posted_producer_sequence != 2 ||
            ledger_level != 2 ||
            tap_protocol_error || merge_protocol_error)
            $fatal(1,
                "real ring launch metadata was not mirrored exactly");

        @(negedge clk);
        direct_credit_valid = 1;
        direct_credit_epoch = shadow_active_epoch;
        direct_credit_source_generation = 32'h100;
        direct_credit_cpu_arm9 = 1;
        direct_credit_cycles = 333;
        direct_credit_kind = 1;
        direct_credit_completed_fence_sequence = 2;
        do @(posedge clk); while (!direct_credit_ready);
        @(negedge clk);
        direct_credit_valid = 0;

        consume(1, 0, 1, 1, 111);
        consume(2, 0, 2, 0, 222);
        consume(3, 1, 32'h100, 1, 333);

        repeat (2) @(posedge clk);
        #1;
        if (ledger_level != 0 || mailbox_pending ||
            last_completed_fence_sequence != 2 ||
            tap_owner_active || tap_protocol_error ||
            merge_protocol_error || capture_overflow)
            $fatal(1, "real-ring composition final state mismatch");

        $display(
            "PASS: passive real-ring tap derives accepted seq=frontier+1 and preserves launch-time CPU/cycles despite live-input mutation");
        $finish;
    end
endmodule
