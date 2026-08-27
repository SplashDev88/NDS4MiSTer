module tb_nds_sound_write_order_queue_wrap;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 0;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic epoch_begin_fresh = 0;
    logic epoch_started;
    logic epoch_active;
    logic [31:0] active_epoch;
    logic epoch_seed_valid = 0;
    logic [31:0] epoch_seed_mailbox_source_id = 0;
    logic [31:0] epoch_seed_posted_base_sequence = 0;
    logic [31:0] epoch_seed_global_sequence = 0;
    logic epoch_runtime_contract_active = 1;
    logic completion_valid = 0;
    logic [31:0] completion_epoch = 0;
    logic [31:0] completion_source_id = 0;
    logic completion_cpu_arm9 = 0;
    logic completion_read_not_write = 0;
    logic [1:0] completion_access = 0;
    logic [31:0] completion_address = 0;
    logic [31:0] completion_write_data = 0;
    logic ack_valid = 0;
    logic ack_ready;
    logic [31:0] ack_epoch = 0;
    logic [31:0] ack_sequence = 0;
    logic ack_cpu_arm9 = 0;
    logic [1:0] ack_kind = 0;
    logic [31:0] ack_source_id = 0;
    logic drain_valid = 0;
    logic drain_ready;
    logic [31:0] drain_epoch = 0;
    logic [31:0] drain_ack_sequence = 0;
    logic write_valid;
    logic write_ready = 0;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [1:0] queue_level;
    logic pending_sound_ack;
    logic capture_overflow;
    logic sequence_exhausted;
    logic protocol_error;

    always #5 clk = ~clk;

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(2),
        .FIRST_COMPLETION_SOURCE_ID(32'hffffffff),
        .FIRST_MAILBOX_SOURCE_ID(32'hffffffff),
        .FIRST_POSTED_SOURCE_ID(32'hffffffff),
        .FIRST_ACK_SEQUENCE(32'hffffffff),
        .FIRST_DRAIN_SEQUENCE(32'hffffffff)
    ) dut (.*);

    task automatic start_epoch(input logic [31:0] epoch);
        begin
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin_valid = 1;
            epoch_begin_fresh = 1;
            epoch_begin = epoch;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin_fresh = 0;
            epoch_begin = 0;
        end
    endtask

    task automatic pulse_max_sound_completion;
        begin
            @(negedge clk);
            completion_valid = 1;
            completion_epoch = active_epoch;
            completion_source_id = 32'hffffffff;
            completion_cpu_arm9 = 0;
            completion_read_not_write = 0;
            completion_access = 2'b01;
            completion_address = 32'h0400051e;
            completion_write_data = 32'hcafef00d;
            @(posedge clk);
            @(negedge clk);
            completion_valid = 0;
        end
    endtask

    task automatic pulse_max_ack(
        input logic [1:0] kind,
        input logic cpu_arm9
    );
        begin
            @(negedge clk);
            ack_valid = 1;
            ack_epoch = active_epoch;
            ack_sequence = 32'hffffffff;
            ack_cpu_arm9 = cpu_arm9;
            ack_kind = kind;
            ack_source_id = 32'hffffffff;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
        end
    endtask

    task automatic pulse_max_drain;
        begin
            @(negedge clk);
            drain_valid = 1;
            drain_epoch = active_epoch;
            drain_ack_sequence = 32'hffffffff;
            do @(posedge clk); while (!drain_ready);
            @(negedge clk);
            drain_valid = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        start_epoch(32'h01020304);

        // The final nonzero sequence is valid and must still release its exact
        // sound payload, but every sequence domain becomes terminal instead
        // of wrapping through reserved zero.
        pulse_max_sound_completion();
        pulse_max_ack(2'b01, 1'b0);
        if (!pending_sound_ack || !sequence_exhausted)
            $fatal(1, "max sound ACK was not retained/marked terminal");
        pulse_max_drain();
        #1;
        if (!write_valid ||
            write_epoch != 32'h01020304 ||
            write_source_id != 32'hffffffff ||
            write_address != 32'h0400051e ||
            write_access != 2'b01 ||
            write_data != 32'hcafef00d ||
            protocol_error || capture_overflow)
            $fatal(1, "final nonzero sound sequence was lost");
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!write_valid || !sequence_exhausted)
                $fatal(1, "terminal output was not retained");
        end
        @(negedge clk);
        write_ready = 1;
        @(posedge clk);
        @(negedge clk);
        if (write_valid || epoch_begin_ready)
            $fatal(1, "terminal epoch resumed or restarted after wrap");

        // Reset is mandatory after exhaustion.  A separate near-wrap session
        // proves the independent posted source domain also terminates at max.
        reset = 1;
        transport_quiescent = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 0;
        write_ready = 1;
        start_epoch(32'h05060708);
        pulse_max_ack(2'b00, 1'b1);
        if (!sequence_exhausted || protocol_error)
            $fatal(1, "posted/global max sequence did not terminate cleanly");
        pulse_max_drain();
        if (!sequence_exhausted || protocol_error || write_valid)
            $fatal(1, "terminal posted drain fabricated a sound write");

        $display(
            "PASS: final nonzero completion/mailbox/posted/ACK/drain sequences deliver once and never wrap through zero");
        $finish;
    end
endmodule
