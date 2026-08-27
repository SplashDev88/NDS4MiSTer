module tb_nds_sound_ack_broadcaster_wrap;
    logic clk = 0;
    logic reset = 1;
    logic transport_quiescent = 0;
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
    logic queue_ack_ready = 1;
    logic [31:0] queue_ack_epoch;
    logic [31:0] queue_ack_sequence;
    logic queue_ack_cpu_arm9;
    logic [1:0] queue_ack_kind;
    logic [31:0] queue_ack_source_id;
    logic credit_valid;
    logic credit_ready = 1;
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
        if (!reset && queue_ack_valid && queue_ack_ready)
            queue_fires <= queue_fires + 1;
        if (!reset && credit_valid && credit_ready)
            credit_fires <= credit_fires + 1;
        if (!reset && ack_valid && ack_ready)
            upstream_fires <= upstream_fires + 1;
    end

    nds_sound_ack_broadcaster #(
        .FIRST_ACK_SEQUENCE(32'hffffffff)
    ) dut (.*);

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin = 32'h0badf00d;
        epoch_begin_valid = 1;
        do @(posedge clk); while (!epoch_begin_ready);
        @(negedge clk);
        epoch_begin_valid = 0;
        epoch_begin = 0;
        while (epoch_started) @(posedge clk);

        @(negedge clk);
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 32'hffffffff;
        ack_cpu_arm9 = 1;
        ack_cycles = 0;
        ack_kind = 2;
        ack_source_id = 32'hffffffff;

        do @(posedge clk); while (!ack_ready);
        @(negedge clk);
        ack_valid = 0;
        ack_epoch = 0;
        ack_sequence = 0;
        #1;

        if (!sequence_exhausted || protocol_error || busy ||
            queue_fires != 1 || credit_fires != 1 ||
            upstream_fires != 1)
            $fatal(1, "terminal record did not fan out and retire once");

        // The reserved zero wrap and every new epoch remain blocked until a
        // reset.  Neither downstream consumer may see another valid.
        @(negedge clk);
        transport_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        transport_quiescent = 1;
        epoch_begin_valid = 1;
        epoch_begin = 32'h0badf00e;
        ack_valid = 1;
        ack_epoch = active_epoch;
        ack_sequence = 0;
        ack_cpu_arm9 = 0;
        ack_cycles = 1;
        ack_kind = 1;
        ack_source_id = 1;
        repeat (12) begin
            @(posedge clk);
            #1;
            if (epoch_begin_ready || ack_ready || queue_ack_valid ||
                credit_valid || queue_fires != 1 || credit_fires != 1 ||
                upstream_fires != 1 || protocol_error)
                $fatal(1, "terminal sequence resumed, wrapped, or faulted");
        end

        $display(
            "PASS: final nonzero ACK reaches both consumers once and broadcaster never wraps through reserved zero");
        $finish;
    end
endmodule
