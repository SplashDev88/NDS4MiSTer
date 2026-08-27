module tb_nds_sound_cycle_scaler;
    logic clk = 0;
    logic reset = 1;
    logic [7:0] source_cycles = 0;
    logic source_cycles_valid = 0;
    logic source_ready;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic idle;
    logic overflow;

    integer accepted_input_sum = 0;
    integer output_sum = 0;
    integer output_events = 0;
    integer stalled_cycles = 0;
    integer conserved_input_sum = 0;
    integer conserved_output_sum = 0;
    integer conserved_output_events = 0;
    logic previous_output_valid = 0;

    always #5 clk = ~clk;

    nds_sound_cycle_scaler dut (.*);

    always @(posedge clk) begin
        if (!reset && source_cycles_valid && source_ready)
            accepted_input_sum <=
                accepted_input_sum + integer'(source_cycles);
        if (!reset && source_cycles_valid && !source_ready)
            stalled_cycles <= stalled_cycles + 1;
        if (!reset && sound_cycles_valid) begin
            output_sum <= output_sum + integer'(sound_cycles);
            output_events <= output_events + 1;
        end
        if (!reset && sound_cycles_valid && previous_output_valid)
            $fatal(1,
                "cycle scaler emitted consecutive valid beats without Robert-compatible bubble");
        previous_output_valid <= !reset && sound_cycles_valid;
    end

    task automatic send(input logic [7:0] cycles);
        begin
            @(negedge clk);
            source_cycles = 8'(cycles);
            source_cycles_valid = 1;
            do begin
                @(posedge clk);
            end while (!source_ready);
            @(negedge clk);
            source_cycles_valid = 0;
            source_cycles = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;

        send(1);
        send(2);
        send(127);
        send(128);

        // Sustained maximum reports eventually exercise backpressure. The
        // producer holds each report until accepted, proving conservation
        // rather than relying on an unbounded finite accumulator.
        for (integer i = 0; i < 600; i++)
            send(255);
        send(3);

        wait (idle);
        @(posedge clk);
        #1;

        if (overflow)
            $fatal(1, "cycle scaler overflowed");
        if (output_sum != accepted_input_sum * 2)
            $fatal(1, "cycle conservation mismatch in=%0d out=%0d",
                accepted_input_sum, output_sum);
        if (output_events < 1000)
            $fatal(1, "split-cycle coverage too low: %0d", output_events);
        if (stalled_cycles == 0)
            $fatal(1, "sustained source never exercised source_ready backpressure");
        conserved_input_sum = accepted_input_sum;
        conserved_output_sum = output_sum;
        conserved_output_events = output_events;

        // Deliberately violate ready/valid once: hold maximum reports until a
        // blocked edge, then withdraw valid before acceptance. The scaler
        // cannot recover a withdrawn pulse, but must report the contract fault.
        @(negedge clk);
        source_cycles = 8'd255;
        source_cycles_valid = 1;
        begin : wait_for_blocked_source
            integer stalls_before;
            stalls_before = stalled_cycles;
            wait (stalled_cycles > stalls_before);
        end
        @(negedge clk);
        source_cycles_valid = 0;
        source_cycles = 0;
        @(posedge clk);
        #1;
        if (!overflow)
            $fatal(1, "withdrawn backpressured source report was not flagged");

        $display("PASS: shared-time cycle scaler conserves accepted time, applies backpressure, and inserts Robert-compatible bubbles");
        $display("INFO: conserved_input_cycles=%0d conserved_output_cycles=%0d conserved_output_events=%0d stalled_cycles=%0d",
            conserved_input_sum, conserved_output_sum,
            conserved_output_events, stalled_cycles);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule

/* verilator lint_off DECLFILENAME */
module tb_nds_sound_cycle_scaler_maxscale;
    logic clk = 0;
    logic reset = 1;
    logic [7:0] source_cycles = 0;
    logic source_cycles_valid = 0;
    logic source_ready;
    logic [7:0] sound_cycles;
    logic sound_cycles_valid;
    logic idle;
    logic overflow;
    integer output_sum = 0;
    integer output_events = 0;
    logic previous_output_valid = 0;

    always #5 clk = ~clk;

    nds_sound_cycle_scaler #(
        .SCALE(255),
        .PENDING_BITS(16)
    ) dut (.*);

    always @(posedge clk) begin
        if (!reset && sound_cycles_valid) begin
            output_sum <= output_sum + integer'(sound_cycles);
            output_events <= output_events + 1;
        end
        if (!reset && sound_cycles_valid && previous_output_valid)
            $fatal(1, "maximum-scale instance omitted output bubble");
        previous_output_valid <= !reset && sound_cycles_valid;
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        source_cycles = 8'd255;
        source_cycles_valid = 1;
        wait (source_ready);
        @(posedge clk);
        @(negedge clk);
        source_cycles_valid = 0;
        source_cycles = 0;

        wait (idle);
        @(posedge clk);
        #1;
        if (overflow || output_sum != 65025 || output_events != 255)
            $fatal(1,
                "maximum-scale conservation mismatch sum=%0d events=%0d overflow=%0b",
                output_sum, output_events, overflow);
        $display("PASS: maximum supported SCALE=255 report conserves all 65025 cycles");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "maximum-scale timeout");
    end
endmodule
/* verilator lint_on DECLFILENAME */
