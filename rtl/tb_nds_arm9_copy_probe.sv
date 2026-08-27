module tb_nds_arm9_copy_probe;
    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic done = 0;
    logic read_not_write = 1;
    logic [1:0] access = 2'b01;
    logic [31:0] address = 0;
    logic [31:0] write_data = 0;
    logic [31:0] read_data = 0;
    logic [31:0] execute_pc = 0;
    logic [2:0] phase;
    logic [7:0] value;
    logic ready;

    nds_arm9_copy_probe dut(.*);
    always #5 clk = ~clk;

    task automatic complete_delayed(
        input logic rnw,
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

    task automatic complete_delayed_and_launch_next(
        input logic first_rnw,
        input logic [31:0] first_address,
        input logic [31:0] first_payload,
        input logic [31:0] first_pc,
        input integer delay_cycles,
        input logic next_rnw,
        input logic [31:0] next_address,
        input logic [31:0] next_payload,
        input logic [31:0] next_pc
    );
        begin
            @(negedge clk);
            request = 1;
            done = 0;
            read_not_write = first_rnw;
            address = first_address;
            write_data = first_payload;
            execute_pc = first_pc;
            @(negedge clk);
            request = 0;
            execute_pc = 32'h02000000;
            repeat (delay_cycles) @(negedge clk);
            done = 1;
            read_data = first_payload;
            request = 1;
            read_not_write = next_rnw;
            address = next_address;
            write_data = next_payload;
            execute_pc = next_pc;
            @(negedge clk);
            done = 0;
            request = 0;
            execute_pc = 32'h02000000;
        end
    endtask

    task automatic complete_pending(
        input logic [31:0] payload,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(negedge clk);
            read_data = payload;
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
        complete_delayed_and_launch_next(
            1, 32'h02096a88, 32'h00003007, 32'h02067194, 5,
            0, 32'h027e378c, 32'h00006107, 32'h020671a4);
        complete_pending(32'h0, 1);
        complete_delayed(
            1, 32'h027e378c, 32'h00006107, 32'h020694e8, 3);

        expect_phase(0, 8'h07);
        expect_phase(1, 8'h30);
        expect_phase(2, 8'h07);
        expect_phase(3, 8'h61);
        expect_phase(4, 8'h07);
        expect_phase(5, 8'h61);
        expect_phase(6, 8'hff);
        @(negedge clk);
        execute_pc = 32'hd259d881;
        @(negedge clk);
        execute_pc = 32'h02000000;
        expect_phase(0, 8'h81);
        expect_phase(1, 8'hd8);
        expect_phase(2, 8'h59);
        expect_phase(3, 8'hd2);
        expect_phase(4, 8'h01);
        if (ready !== 0)
            $fatal(1, "argument snapshot became ready before A/B/C records");
        @(negedge clk);
        execute_pc = 32'ha0e04140;
        @(negedge clk);
        execute_pc = 32'hb0e0d840;
        @(negedge clk);
        execute_pc = 32'hc041d881;
        @(negedge clk);
        execute_pc = 32'h02000000;
        if (ready !== 1)
            $fatal(1, "argument snapshot did not become ready");
        expect_phase(0, 8'h40);
        expect_phase(1, 8'h41);
        expect_phase(2, 8'he0);
        expect_phase(3, 8'h40);
        expect_phase(4, 8'hd8);
        expect_phase(5, 8'h81);
        expect_phase(6, 8'hd8);
        expect_phase(7, 8'h41);
        $display("PASS: ARM9 filesystem copy probe associates delayed completions with latched requests");
        $finish;
    end
endmodule
