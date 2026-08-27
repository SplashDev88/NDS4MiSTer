module tb_nds_arm9_buildtime_probe;
    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic done = 0;
    logic read_not_write = 1;
    logic [1:0] access = 0;
    logic [31:0] address = 0;
    logic [31:0] write_data = 0;
    logic [31:0] read_data = 0;
    logic [31:0] execute_pc = 0;
    logic [2:0] phase;
    logic [7:0] value;
    logic ready;

    nds_arm9_copy_probe #(.BUILDTIME_PROBE(1)) dut(.*);
    always #5 clk = ~clk;

    task automatic complete_delayed(
        input logic rnw,
        input logic [1:0] bus_access,
        input logic [31:0] bus_address,
        input logic [31:0] payload,
        input logic [31:0] pc,
        input integer delay_cycles
    );
        begin
            @(negedge clk);
            request = 1;
            done = 0;
            read_not_write = rnw;
            access = bus_access;
            address = bus_address;
            write_data = payload;
            read_data = payload;
            execute_pc = pc;
            @(negedge clk);
            request = 0;
            execute_pc = 32'h02000000;
            repeat (delay_cycles) @(negedge clk);
            done = 1;
            @(negedge clk);
            done = 0;
        end
    endtask

    task automatic expect_phase(
        input logic [2:0] wanted_phase,
        input logic [7:0] wanted_value
    );
        begin
            while (phase != wanted_phase) @(posedge clk);
            #1;
            if (value !== wanted_value)
                $fatal(1, "phase %0d got %02x expected %02x",
                       wanted_phase, value, wanted_value);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        // The same SDK buffer is used by an earlier seven-byte copy. Its
        // tail reads 0x02096a88, its first write targets 0x027e37d8, and its
        // later comparison reads that destination. None may arm r172.
        complete_delayed(
            1, 2'b01, 32'h02096a88, 32'h0000594d, 32'h020670fc, 4);
        complete_delayed(
            0, 2'b01, 32'h027e37d8, 32'h00443030, 32'h020670e4, 2);
        complete_delayed(
            1, 2'b00, 32'h027e37d8, 32'h00000049, 32'h020697c0, 6);
        if (ready !== 0)
            $fatal(1, "earlier scratch-buffer copy armed BUILDTIME probe");

        // The second matching source/write pair is the exact BUILDTIME copy.
        // execute_pc is the stable request-stage PC observed on hardware,
        // eight bytes behind the architectural memory instruction.
        complete_delayed(
            1, 2'b01, 32'h02096a88, 32'h00004209, 32'h020670cc, 5);
        complete_delayed(
            0, 2'b01, 32'h027e37d8, 32'h00495542, 32'h020670e4, 3);
        complete_delayed(
            1, 2'b00, 32'h027e37d8, 32'h00000042, 32'h020697c0, 7);

        if (ready !== 1)
            $fatal(1, "BUILDTIME source/write/read probe did not become ready");
        expect_phase(0, 8'h09);
        expect_phase(1, 8'h42);
        expect_phase(2, 8'h42);
        expect_phase(3, 8'h55);
        expect_phase(4, 8'h42);
        expect_phase(5, 8'h00);
        expect_phase(6, 8'he8);
        expect_phase(7, 8'he4);
        $display("PASS: BUILDTIME probe rejects the earlier scratch copy and preserves the second source/write/readback");
        $finish;
    end
endmodule
