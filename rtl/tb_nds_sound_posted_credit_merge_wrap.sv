module tb_nds_sound_posted_credit_merge_wrap;
    localparam integer DEPTH = 4;

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
    logic posted_accept_valid = 0;
    logic [31:0] posted_accept_epoch = 0;
    logic posted_accept_cpu_arm9 = 0;
    logic [31:0] posted_accept_cycles = 0;
    logic [31:0] posted_accept_producer_sequence = 0;
    logic direct_credit_valid = 0;
    logic direct_credit_ready;
    logic [31:0] direct_credit_epoch = 0;
    logic [31:0] direct_credit_source_generation = 0;
    logic direct_credit_cpu_arm9 = 0;
    logic [31:0] direct_credit_cycles = 0;
    logic [1:0] direct_credit_kind = 0;
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
    logic [$clog2(DEPTH + 1)-1:0] ledger_level;
    logic mailbox_pending;
    logic [31:0] last_completed_fence_sequence;
    logic capture_overflow;
    logic posted_sequence_exhausted;
    logic ack_sequence_exhausted;
    logic protocol_error;
    logic [7:0] fault_code;

    always #5 clk = ~clk;

    nds_sound_posted_credit_merge #(
        .LEDGER_DEPTH(DEPTH),
        .FIRST_ACK_SEQUENCE(32'hfffffffc)
    ) dut (.*);

    task automatic post_terminal(
        input logic [31:0] posted_sequence,
        input logic cpu_arm9,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_accept_valid = 1;
            posted_accept_epoch = shadow_active_epoch;
            posted_accept_cpu_arm9 = cpu_arm9;
            posted_accept_cycles = cycles;
            posted_accept_producer_sequence = posted_sequence;
            @(posedge clk);
            @(negedge clk);
            posted_accept_valid = 0;
        end
    endtask

    task automatic direct_record(
        input logic [31:0] source_generation
    );
        begin
            @(negedge clk);
            direct_credit_valid = 1;
            direct_credit_epoch = shadow_active_epoch;
            direct_credit_source_generation = source_generation;
            direct_credit_cpu_arm9 = source_generation[0];
            direct_credit_cycles = source_generation;
            direct_credit_kind = 2'b01;
            direct_credit_completed_fence_sequence = 32'hffffffff;
            do @(posedge clk); while (!direct_credit_ready);
            @(negedge clk);
            direct_credit_valid = 0;
        end
    endtask

    task automatic consume(
        input logic [31:0] ack,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        begin
            while (!merged_credit_valid) @(posedge clk);
            #1;
            if (merged_credit_ack_sequence != ack ||
                merged_credit_kind != kind ||
                merged_credit_source_id != source_id ||
                merged_credit_completed_fence_sequence != 32'hffffffff)
                $fatal(1,
                    "terminal ordering mismatch ack=%h kind=%h source=%h",
                    merged_credit_ack_sequence,
                    merged_credit_kind,
                    merged_credit_source_id);
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
        epoch_contract = 32'h77000001;
        epoch_base_posted_sequence = 32'hfffffffd;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_contract_active = 1;
        epoch_contract_fresh = 1;
        @(posedge clk);
        @(negedge clk);
        epoch_contract_fresh = 0;
        if (!shadow_session_active || protocol_error)
            $fatal(1, "near-wrap epoch failed");

        post_terminal(32'hfffffffe, 0, 32'h11);
        post_terminal(32'hffffffff, 1, 32'h22);
        #1;
        if (!posted_sequence_exhausted || ledger_level != 2)
            $fatal(1, "terminal posted value was not retained");

        direct_record(32'h100);
        consume(32'hfffffffc, 0, 32'hfffffffe);
        consume(32'hfffffffd, 0, 32'hffffffff);
        consume(32'hfffffffe, 1, 32'h100);
        if (ledger_level != 0 ||
            last_completed_fence_sequence != 32'hffffffff ||
            protocol_error)
            $fatal(1, "terminal posted batch did not retire");

        // A distinct direct transaction at the same terminal fence consumes
        // the final nonzero global ACK identity without duplicating posts.
        direct_record(32'h101);
        consume(32'hffffffff, 1, 32'h101);
        #1;
        if (!ack_sequence_exhausted || mailbox_pending ||
            merged_credit_valid || protocol_error)
            $fatal(1, "terminal ACK identity was not consumed exactly once");

        // There is no modulo ordering convention in this ABI.  A further
        // direct credit cannot be assigned zero and therefore fails closed.
        direct_record(32'h102);
        #1;
        if (!protocol_error || fault_code != 8'h15 ||
            shadow_session_active || merged_credit_valid ||
            direct_credit_ready)
            $fatal(1,
                "ACK wrap did not fail closed code=%h", fault_code);

        $display(
            "PASS: posted/fence/ACK terminal values retire once and reserved-zero wrap fails closed");
        $finish;
    end
endmodule
