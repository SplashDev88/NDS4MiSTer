module tb_nds_sound_posted_acceptance_tap_faults;
    logic clk = 0;
    logic reset = 1;
    logic shadow_feature_enable = 0;
    logic shadow_session_active = 0;
    logic [31:0] shadow_active_epoch = 0;
    logic posted_request = 0;
    logic posted_active = 0;
    logic posted_accepted = 0;
    logic posted_sequence_exhausted = 0;
    logic [31:0] posted_producer_sequence = 0;
    logic posted_cpu_arm9 = 0;
    logic [31:0] posted_elapsed_cycles = 0;
    logic acceptance_valid;
    logic [31:0] acceptance_epoch;
    logic acceptance_cpu_arm9;
    logic [31:0] acceptance_cycles;
    logic [31:0] acceptance_producer_sequence;
    logic owner_active;
    logic protocol_error;
    logic [7:0] fault_code;

    integer fault_cases = 0;

    always #5 clk = ~clk;
    nds_sound_posted_acceptance_tap dut (.*);

    task automatic clear_inputs;
        begin
            shadow_feature_enable = 0;
            shadow_session_active = 0;
            shadow_active_epoch = 0;
            posted_request = 0;
            posted_active = 0;
            posted_accepted = 0;
            posted_sequence_exhausted = 0;
            posted_producer_sequence = 0;
            posted_cpu_arm9 = 0;
            posted_elapsed_cycles = 0;
        end
    endtask

    task automatic hard_reset;
        begin
            @(negedge clk);
            clear_inputs();
            reset = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task automatic enable_session;
        begin
            shadow_feature_enable = 1;
            shadow_session_active = 1;
            shadow_active_epoch = 32'h7b000001;
        end
    endtask

    task automatic require_fault(
        input logic [7:0] expected_code,
        input [8*64-1:0] label
    );
        begin
            #1;
            if (!protocol_error || fault_code != expected_code ||
                owner_active || acceptance_valid)
                $fatal(1,
                    "%0s did not close tap code=%h owner=%b valid=%b",
                    label, fault_code, owner_active, acceptance_valid);
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!protocol_error || fault_code != expected_code ||
                    owner_active || acceptance_valid)
                    $fatal(1, "%0s fault was not sticky", label);
            end
            fault_cases = fault_cases + 1;
            clear_inputs();
        end
    endtask

    task automatic launch(
        input logic [31:0] frontier,
        input logic cpu,
        input logic [31:0] cycles
    );
        begin
            @(negedge clk);
            posted_request = 1;
            posted_active = 0;
            posted_producer_sequence = frontier;
            posted_cpu_arm9 = cpu;
            posted_elapsed_cycles = cycles;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);

        // Valid terminal acceptance is emitted exactly once.
        hard_reset();
        enable_session();
        launch(32'hfffffffe, 1, 32'h12345678);
        posted_active = 1;
        posted_accepted = 1;
        @(posedge clk);
        @(negedge clk);
        posted_accepted = 0;
        #1;
        if (!acceptance_valid ||
            acceptance_epoch != 32'h7b000001 ||
            acceptance_cpu_arm9 != 1 ||
            acceptance_cycles != 32'h12345678 ||
            acceptance_producer_sequence != 32'hffffffff ||
            owner_active || protocol_error)
            $fatal(1, "valid terminal acceptance metadata mismatch");
        @(posedge clk);
        #1;
        if (acceptance_valid)
            $fatal(1, "valid terminal acceptance duplicated");

        hard_reset();
        shadow_feature_enable = 1;
        posted_request = 1;
        posted_producer_sequence = 1;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h01, "request outside active session");

        hard_reset();
        enable_session();
        posted_active = 1;
        posted_accepted = 1;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h03, "ownerless acceptance");

        hard_reset();
        enable_session();
        launch(5, 1, 10);
        // Keeping active low presents an impossible second launch.
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h02, "multiple launch");

        hard_reset();
        enable_session();
        launch(5, 1, 10);
        posted_active = 1;
        posted_producer_sequence = 6;
        posted_accepted = 1;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h04, "frontier changed before acceptance");

        hard_reset();
        enable_session();
        launch(32'hffffffff, 1, 10);
        require_fault(8'h05, "launch beyond terminal frontier");

        hard_reset();
        enable_session();
        launch(7, 0, 20);
        shadow_session_active = 0;
        shadow_active_epoch = 0;
        @(posedge clk);
        @(negedge clk);
        require_fault(8'h01, "session loss with retained owner");

        if (fault_cases != 6)
            $fatal(1, "acceptance fault count %0d", fault_cases);
        $display(
            "PASS: posted acceptance tap terminal value and six session/owner/frontier failures are exact and sticky");
        $finish;
    end
endmodule
