module tb_nds_arm9_stack_return_probe;
    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic done = 0;
    logic read_not_write = 1;
    logic [1:0] access = 2'b10;
    logic [31:0] address = 0;
    logic [31:0] write_data = 0;
    logic [31:0] read_data = 0;
    logic [31:0] execute_pc = 0;
    logic [3:0] phase;
    logic [7:0] value;
    logic ready;

    always #5 clk = ~clk;

    nds_arm9_stack_return_probe dut (.*);

    task automatic launch(
        input logic is_read,
        input logic [31:0] launch_address,
        input logic [31:0] launch_data,
        input logic [31:0] launch_pc
    );
        @(negedge clk);
        read_not_write = is_read;
        access = 2'b10;
        address = launch_address;
        write_data = launch_data;
        execute_pc = launch_pc;
        request = 1;
        @(negedge clk);
        request = 0;
        // Poison every live input while the accepted transaction is pending.
        // The probe must attribute completion to the latched request.
        address = 32'he5823004;
        write_data = 32'hdeadbeef;
        execute_pc = 32'h01ff8014;
    endtask

    task automatic complete(input logic [31:0] response);
        @(negedge clk);
        read_data = response;
        done = 1;
        @(negedge clk);
        done = 0;
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        launch(0, 32'h027e3928, 32'h0204d4c8, 32'h01ffd244);
        complete(0);
        // An unrelated instruction/data word must not replace the saved PC.
        launch(0, 32'h027e3930, 32'he5823004, 32'h01ff8014);
        complete(0);
        launch(1, 32'h027e3924, 0, 32'h01ffd280);
        complete(32'h00000000);
        launch(1, 32'h027e3928, 0, 32'h01ffd280);
        complete(32'he5823004);

        repeat (2) @(posedge clk);
        if (!ready)
            $fatal(1, "stack-return probe did not complete");
        if (dut.word1_write_data !== 32'h0204d4c8 ||
            dut.word1_write_pc !== 32'h01ffd244)
            $fatal(1, "saved-PC write snapshot corrupt data=%h pc=%h",
                   dut.word1_write_data, dut.word1_write_pc);
        if (dut.word0_read_data !== 32'h00000000 ||
            dut.word1_read_data !== 32'he5823004)
            $fatal(1, "stack-return read snapshots corrupt word0=%h word1=%h",
                   dut.word0_read_data, dut.word1_read_data);

        force dut.phase_counter = 19'(0 << 15);
        #1;
        if (value !== 8'hc8) $fatal(1, "phase 0 value %h", value);
        force dut.phase_counter = 19'(3 << 15);
        #1;
        if (value !== 8'h02) $fatal(1, "phase 3 value %h", value);
        force dut.phase_counter = 19'(4 << 15);
        #1;
        if (value !== 8'h04) $fatal(1, "phase 4 value %h", value);
        force dut.phase_counter = 19'(7 << 15);
        #1;
        if (value !== 8'he5) $fatal(1, "phase 7 value %h", value);
        force dut.phase_counter = 19'(8 << 15);
        #1;
        if (value !== 8'h44) $fatal(1, "phase 8 value %h", value);
        force dut.phase_counter = 19'(15 << 15);
        #1;
        if (value !== 8'h00) $fatal(1, "phase 15 value %h", value);
        release dut.phase_counter;

        $display("PASS: ARM9 stack-return probe separates saved-PC write from DTCM readback");
        $finish;
    end
endmodule
