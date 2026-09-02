module tb_nds_sound_write_order_queue;
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
    logic write_ready = 1;
    logic [31:0] write_epoch;
    logic [31:0] write_source_id;
    logic [31:0] write_address;
    logic [1:0] write_access;
    logic [31:0] write_data;
    logic [2:0] queue_level;
    logic pending_sound_ack;
    logic capture_overflow;
    logic sequence_exhausted;
    logic protocol_error;

    integer next_completion = 1;
    integer next_ack = 1;
    integer next_mailbox = 1;
    integer next_posted = 1;
    integer next_drain = 1;
    integer delivered = 0;

    logic previous_write_valid = 0;
    logic previous_write_ready = 0;
    logic [31:0] previous_write_epoch = 0;
    logic [31:0] previous_write_source_id = 0;
    logic [31:0] previous_write_address = 0;
    logic [1:0] previous_write_access = 0;
    logic [31:0] previous_write_data = 0;

    always #5 clk = ~clk;

    nds_sound_write_order_queue #(
        .QUEUE_DEPTH(4)
    ) dut (.*);

    always @(posedge clk) begin
        if (!reset && previous_write_valid && !previous_write_ready) begin
            if (!write_valid ||
                write_epoch != previous_write_epoch ||
                write_source_id != previous_write_source_id ||
                write_address != previous_write_address ||
                write_access != previous_write_access ||
                write_data != previous_write_data)
                $fatal(1, "retained write changed under backpressure");
        end
        if (!reset && write_valid && write_ready)
            delivered <= delivered + 1;
        previous_write_valid <= write_valid;
        previous_write_ready <= write_ready;
        previous_write_epoch <= write_epoch;
        previous_write_source_id <= write_source_id;
        previous_write_address <= write_address;
        previous_write_access <= write_access;
        previous_write_data <= write_data;
    end

    task automatic start_epoch(input logic [31:0] epoch);
        begin
            @(negedge clk);
            epoch_begin = epoch;
            epoch_begin_fresh = 1;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin_fresh = 0;
            epoch_begin = 0;
            #1;
            if (!epoch_active || active_epoch != epoch)
                $fatal(1, "epoch did not start");
        end
    endtask

    task automatic complete_transaction(
        input logic cpu_arm9,
        input logic read_not_write,
        input logic [1:0] access,
        input logic [31:0] address,
        input logic [31:0] data,
        output logic [31:0] source_id
    );
        begin
            source_id = next_completion;
            @(negedge clk);
            completion_epoch = active_epoch;
            completion_source_id = next_completion;
            completion_cpu_arm9 = cpu_arm9;
            completion_read_not_write = read_not_write;
            completion_access = access;
            completion_address = address;
            completion_write_data = data;
            completion_valid = 1;
            @(posedge clk);
            @(negedge clk);
            completion_valid = 0;
            completion_epoch = 0;
            completion_source_id = 0;
            completion_cpu_arm9 = 0;
            completion_read_not_write = 0;
            completion_access = 0;
            completion_address = 0;
            completion_write_data = 0;
            next_completion = next_completion + 1;
            if (protocol_error)
                $fatal(1, "valid completion poisoned queue");
        end
    endtask

    task automatic send_mailbox_ack(input logic cpu_arm9);
        begin
            @(negedge clk);
            ack_epoch = active_epoch;
            ack_sequence = next_ack;
            ack_cpu_arm9 = cpu_arm9;
            ack_kind = 2'b01;
            ack_source_id = next_mailbox;
            ack_valid = 1;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_kind = 0;
            ack_source_id = 0;
            next_ack = next_ack + 1;
            next_mailbox = next_mailbox + 1;
            if (protocol_error)
                $fatal(1, "valid mailbox ACK poisoned queue");
        end
    endtask

    task automatic send_posted_ack(input logic cpu_arm9);
        begin
            @(negedge clk);
            ack_epoch = active_epoch;
            ack_sequence = next_ack;
            ack_cpu_arm9 = cpu_arm9;
            ack_kind = 2'b00;
            ack_source_id = next_posted;
            ack_valid = 1;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_kind = 0;
            ack_source_id = 0;
            next_ack = next_ack + 1;
            next_posted = next_posted + 1;
            if (protocol_error)
                $fatal(1, "valid posted ACK poisoned queue");
        end
    endtask

    task automatic send_halt_ack(input logic cpu_arm9);
        begin
            @(negedge clk);
            ack_epoch = active_epoch;
            ack_sequence = next_ack;
            ack_cpu_arm9 = cpu_arm9;
            ack_kind = 2'b10;
            ack_source_id = next_mailbox;
            ack_valid = 1;
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_kind = 0;
            ack_source_id = 0;
            next_ack = next_ack + 1;
            next_mailbox = next_mailbox + 1;
            if (protocol_error)
                $fatal(1, "valid halt ACK poisoned queue");
        end
    endtask

    task automatic send_drain;
        begin
            @(negedge clk);
            drain_epoch = active_epoch;
            drain_ack_sequence = next_drain;
            drain_valid = 1;
            do @(posedge clk); while (!drain_ready);
            @(negedge clk);
            drain_valid = 0;
            drain_epoch = 0;
            drain_ack_sequence = 0;
            next_drain = next_drain + 1;
            if (protocol_error)
                $fatal(1, "valid drain token poisoned queue");
        end
    endtask

    task automatic expect_write(
        input logic [31:0] expected_source,
        input logic [31:0] expected_address,
        input logic [1:0] expected_access,
        input logic [31:0] expected_data
    );
        begin
            #1;
            if (!write_valid ||
                write_epoch != active_epoch ||
                write_source_id != expected_source ||
                write_address != expected_address ||
                write_access != expected_access ||
                write_data != expected_data)
                $fatal(1,
                    "write mismatch source=%h/%h address=%h/%h access=%h/%h data=%h/%h",
                    write_source_id, expected_source,
                    write_address, expected_address,
                    write_access, expected_access,
                    write_data, expected_data);
        end
    endtask

    task automatic consume_write;
        begin
            @(posedge clk);
            @(negedge clk);
            #1;
            if (write_valid)
                $fatal(1, "write did not retire exactly once");
        end
    endtask

    logic [31:0] source;
    logic [31:0] address;
    logic [31:0] data;
    integer access_index;
    integer address_index;
    integer delivered_before_exhaustive;

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // Quiescence-high alone is insufficient: a post-reset low transition
        // is mandatory before accepting a fresh persistent epoch.
        transport_quiescent = 1;
        epoch_begin = 32'h12345678;
        epoch_begin_fresh = 1;
        epoch_begin_valid = 1;
        repeat (2) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || epoch_active)
                $fatal(1, "epoch started without low/high quarantine");
        end
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin_fresh = 0;
        epoch_begin = 0;
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        start_epoch(32'h12345678);

        // Reverse transport can beat the mailbox response.  It must wait for
        // completed metadata, rather than infer anything from request launch.
        @(negedge clk);
        ack_epoch = active_epoch;
        ack_sequence = 1;
        ack_cpu_arm9 = 1;
        ack_kind = 2'b01;
        ack_source_id = 1;
        ack_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (ack_ready)
                $fatal(1, "ACK overtook completion metadata");
        end
        complete_transaction(
            1'b1, 1'b1, 2'b10, 32'hffffffff, 32'h11111111, source);
        if (source != 1)
            $fatal(1, "first completion source mismatch");
        do @(posedge clk); while (!ack_ready);
        @(negedge clk);
        ack_valid = 0;
        ack_epoch = 0;
        ack_sequence = 0;
        ack_cpu_arm9 = 0;
        ack_kind = 0;
        ack_source_id = 0;
        next_ack = 2;
        next_mailbox = 2;
        send_drain();

        // ARM9 writes and ARM7 reads inside the sound aperture are unrelated.
        complete_transaction(
            1'b1, 1'b0, 2'b10, 32'h04000400, 32'ha5a5a5a5, source);
        send_mailbox_ack(1'b1);
        send_drain();
        complete_transaction(
            1'b0, 1'b1, 2'b00, 32'h04000400, 32'hdeadbeef, source);
        send_mailbox_ack(1'b0);
        send_drain();
        // Synthetic halt timing shares the mailbox-generation source domain
        // but carries no sound-register effect.
        complete_transaction(
            1'b0, 1'b1, 2'b10, 32'hffffffff, 32'h00000000, source);
        send_halt_ack(1'b0);
        send_drain();
        if (queue_level != 0 || write_valid || delivered != 0)
            $fatal(1, "unrelated mailbox traffic created a sound write");

        // A completed byte write is held through its exact consumed ACK and
        // every earlier drain token.  Later unrelated ACKs are serialized
        // behind this one-pending sound barrier.
        complete_transaction(
            1'b0, 1'b0, 2'b00, 32'h04000403, 32'h89abcdef, source);
        if (queue_level != 1 || write_valid)
            $fatal(1, "sound completion was not retained");
        write_ready = 0;
        send_mailbox_ack(1'b0);
        if (!pending_sound_ack || queue_level != 0 || write_valid)
            $fatal(1, "sound ACK did not enter pending-drain state");

        @(negedge clk);
        ack_epoch = active_epoch;
        ack_sequence = next_ack;
        ack_cpu_arm9 = 1;
        ack_kind = 2'b00;
        ack_source_id = next_posted;
        ack_valid = 1;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (ack_ready)
                $fatal(1, "later ACK overtook pending sound drain");
        end

        send_drain();
        expect_write(source, 32'h04000403, 2'b00, 32'h89abcdef);
        repeat (5) @(posedge clk);
        expect_write(source, 32'h04000403, 2'b00, 32'h89abcdef);
        if (ack_ready)
            $fatal(1, "ACK resumed before retained output was consumed");
        @(negedge clk);
        write_ready = 1;
        @(posedge clk);
        @(negedge clk);
        #1;
        if (write_valid || !ack_ready)
            $fatal(1, "output/ACK turnover failed");
        // The held posted record is accepted now.
        @(posedge clk);
        @(negedge clk);
        ack_valid = 0;
        ack_epoch = 0;
        ack_sequence = 0;
        ack_cpu_arm9 = 0;
        ack_kind = 0;
        ack_source_id = 0;
        next_ack = next_ack + 1;
        next_posted = next_posted + 1;
        send_drain();

        // Exhaust every byte address and all three legal lane widths.  The
        // queue must preserve low address bits, access, and all payload bits
        // exactly; it performs no lane shifting or alignment normalization.
        delivered_before_exhaustive = delivered;
        for (access_index = 0; access_index < 3; access_index = access_index + 1) begin
            for (address_index = 0; address_index < 16'h120;
                 address_index = address_index + 1) begin
                address = 32'h04000400 + address_index;
                data = 32'h6d3a0000 ^
                    (address_index * 32'h01010101) ^
                    (access_index * 32'h13579bdf);
                complete_transaction(
                    1'b0, 1'b0, access_index[1:0],
                    address, data, source);
                send_mailbox_ack(1'b0);
                send_drain();
                expect_write(source, address, access_index[1:0], data);
                consume_write();
            end
        end
        // The monitor increments on the consume edge; allow its nonblocking
        // counter update to settle before checking the exact event count.
        @(posedge clk);
        #1;
        if (delivered - delivered_before_exhaustive != 864)
            $fatal(1, "exhaustive lane replay count mismatch %0d",
                delivered - delivered_before_exhaustive);

        // Multiple completions may be retained without stalling their source.
        complete_transaction(
            1'b0, 1'b0, 2'b00, 32'h04000400, 32'h11111111, source);
        complete_transaction(
            1'b0, 1'b0, 2'b01, 32'h04000402, 32'h22222222, source);
        complete_transaction(
            1'b0, 1'b0, 2'b10, 32'h04000404, 32'h33333333, source);
        if (queue_level != 3 || capture_overflow)
            $fatal(1, "completion FIFO backlog mismatch");

        // Drain them in exact mailbox-generation order.
        repeat (3) begin
            send_mailbox_ack(1'b0);
            send_drain();
            if (!write_valid)
                $fatal(1, "queued write did not release");
            consume_write();
        end
        if (queue_level != 0 || pending_sound_ack ||
            write_valid || capture_overflow || protocol_error ||
            sequence_exhausted)
            $fatal(1, "normal queue did not finish cleanly");

        $display(
            "PASS: completed-only sound writes retain exact ACK/time causality and all 864 address/access lane payloads");
        $finish;
    end
endmodule
