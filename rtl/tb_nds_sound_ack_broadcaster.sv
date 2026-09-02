module tb_nds_sound_ack_broadcaster;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 1;
    logic epoch_begin_valid = 0;
    logic epoch_begin_ready;
    logic [31:0] epoch_begin = 0;
    logic epoch_begin_fresh = 1;
    logic epoch_started;
    logic epoch_active;
    logic [31:0] active_epoch;

    logic ack_valid = 0;
    logic ack_ready;
    logic [31:0] ack_epoch = 0;
    logic [31:0] ack_sequence = 0;
    logic ack_cpu_arm9 = 0;
    logic [31:0] ack_cycles = 0;
    logic [1:0] ack_kind = 0;
    logic [31:0] ack_source_id = 0;

    logic queue_ack_valid;
    logic queue_ack_ready = 0;
    logic [31:0] queue_ack_epoch;
    logic [31:0] queue_ack_sequence;
    logic queue_ack_cpu_arm9;
    logic [1:0] queue_ack_kind;
    logic [31:0] queue_ack_source_id;

    logic credit_valid;
    logic credit_ready = 0;
    logic [31:0] credit_epoch;
    logic [31:0] credit_ack_sequence;
    logic credit_cpu_arm9;
    logic [31:0] credit_cycles;
    logic [1:0] credit_kind;

    logic busy;
    logic sequence_exhausted;
    logic protocol_error;

    integer queue_fires = 0;
    integer credit_fires = 0;
    integer upstream_fires = 0;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!reset) begin
            if (queue_ack_valid && queue_ack_ready)
                queue_fires <= queue_fires + 1;
            if (credit_valid && credit_ready)
                credit_fires <= credit_fires + 1;
            if (ack_valid && ack_ready)
                upstream_fires <= upstream_fires + 1;

            if (queue_ack_valid &&
                (queue_ack_epoch != ack_epoch ||
                 queue_ack_sequence != ack_sequence ||
                 queue_ack_cpu_arm9 != ack_cpu_arm9 ||
                 queue_ack_kind != ack_kind ||
                 queue_ack_source_id != ack_source_id))
                $fatal(1, "queue payload changed from retained source");
            if (credit_valid &&
                (credit_epoch != ack_epoch ||
                 credit_ack_sequence != ack_sequence ||
                 credit_cpu_arm9 != ack_cpu_arm9 ||
                 credit_cycles != ack_cycles ||
                 credit_kind != ack_kind))
                $fatal(1, "credit payload changed from retained source");
        end
    end

    nds_sound_ack_broadcaster dut (.*);

    task automatic start_epoch(input logic [31:0] wanted);
        begin
            @(negedge clk);
            transport_quiescent = 0;
            @(posedge clk);
            @(negedge clk);
            transport_quiescent = 1;
            epoch_begin = wanted;
            epoch_begin_valid = 1;
            do @(posedge clk); while (!epoch_begin_ready);
            @(negedge clk);
            epoch_begin_valid = 0;
            epoch_begin = 0;
            while (epoch_started) @(posedge clk);
        end
    endtask

    task automatic present_record(
        input logic [31:0] seq,
        input logic cpu_arm9,
        input logic [31:0] cycles,
        input logic [1:0] kind,
        input logic [31:0] source_id
    );
        begin
            @(negedge clk);
            ack_epoch = active_epoch;
            ack_sequence = seq;
            ack_cpu_arm9 = cpu_arm9;
            ack_cycles = cycles;
            ack_kind = kind;
            ack_source_id = source_id;
            ack_valid = 1;
        end
    endtask

    task automatic retire_record;
        begin
            do @(posedge clk); while (!ack_ready);
            @(negedge clk);
            ack_valid = 0;
            ack_epoch = 0;
            ack_sequence = 0;
            ack_cpu_arm9 = 0;
            ack_cycles = 0;
            ack_kind = 0;
            ack_source_id = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        // A high quiescent level alone is not a fresh-session boundary.
        repeat (4) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready)
                $fatal(1, "epoch escaped reset quarantine without low phase");
        end
        start_epoch(32'h5a5a1001);
        if (!epoch_active || active_epoch != 32'h5a5a1001)
            $fatal(1, "valid epoch did not start");

        // Queue accepts first.  It must see the retained record once while the
        // credit consumer can remain stalled arbitrarily long.
        queue_ack_ready = 1;
        credit_ready = 0;
        present_record(1, 1, 32'h12345678, 2'b01, 32'h10);
        wait (queue_fires == 1);
        repeat (80) begin
            @(posedge clk);
            #1;
            if (ack_ready || queue_ack_valid || !credit_valid ||
                queue_fires != 1 || credit_fires != 0)
                $fatal(1, "queue-first asymmetric stall duplicated/retired");
        end
        @(negedge clk);
        credit_ready = 1;
        retire_record();
        @(posedge clk);
        #1;
        if (queue_fires != 1 || credit_fires != 1 ||
            upstream_fires != 1 || busy || protocol_error)
            $fatal(1, "queue-first record did not retire exactly once");

        // Credit accepts first, including a synthetic halt record with zero
        // cycles.  The queue copy remains stable through a longer stall.
        queue_ack_ready = 0;
        credit_ready = 1;
        present_record(2, 0, 0, 2'b10, 32'h11);
        wait (credit_fires == 2);
        repeat (113) begin
            @(posedge clk);
            #1;
            if (ack_ready || !queue_ack_valid || credit_valid ||
                queue_fires != 1 || credit_fires != 2)
                $fatal(1, "credit-first asymmetric stall duplicated/retired");
        end
        @(negedge clk);
        queue_ack_ready = 1;
        retire_record();
        @(posedge clk);
        #1;
        if (queue_fires != 2 || credit_fires != 2 ||
            upstream_fires != 2 || busy || protocol_error)
            $fatal(1, "credit-first record did not retire exactly once");

        // Simultaneous consumers still precede the separately registered
        // upstream retirement handshake.
        present_record(3, 1, 9, 2'b00, 32'h22);
        wait (queue_fires == 3 && credit_fires == 3);
        #1;
        if (!ack_valid || !ack_ready || upstream_fires != 2)
            $fatal(1,
                "registered retirement state did not follow both consumers");
        retire_record();
        @(posedge clk);
        #1;

        if (queue_fires != 3 || credit_fires != 3 ||
            upstream_fires != 3 || busy || sequence_exhausted ||
            protocol_error || !epoch_active)
            $fatal(1, "broadcaster final state mismatch");

        $display(
            "PASS: retained ACK broadcaster survives either-consumer-first and long asymmetric stalls without duplicate/drop/reorder");
        $finish;
    end
endmodule
