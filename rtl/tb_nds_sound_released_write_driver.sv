`timescale 1ns/1ps

module tb_nds_sound_released_write_driver;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic in_valid, in_ready;
    logic [31:0] in_address, in_data;
    logic [1:0] in_access;
    logic source_error;
    logic request, cpu_arm9, cpu_write;
    logic [31:0] cpu_address, cpu_data;
    logic [1:0] cpu_access;
    logic done, rejected;
    logic busy, protocol_error;

    nds_sound_released_write_driver dut (
        .clk, .reset,
        .released_write_valid(in_valid),
        .released_write_ready(in_ready),
        .released_write_address(in_address),
        .released_write_access(in_access),
        .released_write_data(in_data),
        .source_protocol_error(source_error),
        .shadow_cpu_request(request),
        .shadow_cpu_is_arm9(cpu_arm9),
        .shadow_cpu_write(cpu_write),
        .shadow_cpu_address(cpu_address),
        .shadow_cpu_access(cpu_access),
        .shadow_cpu_write_data(cpu_data),
        .shadow_cpu_done(done),
        .shadow_cpu_rejected(rejected),
        .busy, .protocol_error
    );

    task automatic clear_inputs;
        begin
            in_valid = 0;
            in_address = 0;
            in_access = 0;
            in_data = 0;
            source_error = 0;
            done = 0;
            rejected = 0;
        end
    endtask

    task automatic apply_reset;
        begin
            clear_inputs();
            reset = 1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset = 0;
            @(posedge clk);
            #1;
            if (!in_ready || request || busy || protocol_error)
                $fatal(1, "bad reset exit");
        end
    endtask

    task automatic send_and_complete(
        input logic [31:0] address,
        input logic [1:0] access,
        input logic [31:0] data,
        input integer delay_cycles
    );
        integer i;
        begin
            @(negedge clk);
            in_valid = 1;
            in_address = address;
            in_access = access;
            in_data = data;
            @(posedge clk);
            #1;
            if (!request || in_ready || !busy)
                $fatal(1, "request was not retained");
            if (cpu_address !== address || cpu_access !== access ||
                cpu_data !== data || cpu_arm9 || !cpu_write)
                $fatal(1, "payload/qualifier mismatch");

            // Mutating the upstream payload cannot affect the held request.
            @(negedge clk);
            in_valid = 0;
            in_address = 32'hdeadbeef;
            in_access = 2'b11;
            in_data = 32'hcafef00d;
            for (i = 0; i < delay_cycles; i = i + 1) begin
                @(posedge clk);
                #1;
                if (!request || cpu_address !== address ||
                    cpu_access !== access || cpu_data !== data)
                    $fatal(1, "request changed while waiting");
            end

            @(negedge clk);
            done = 1;
            @(posedge clk);
            #1;
            if (request || !busy || protocol_error)
                $fatal(1, "completion did not enter release bubble");
            @(negedge clk);
            done = 0;
            @(posedge clk);
            #1;
            if (request || busy || !in_ready || protocol_error)
                $fatal(1, "release bubble did not return idle");
        end
    endtask

    task automatic expect_fault(
        input logic [31:0] address,
        input logic [1:0] access
    );
        begin
            apply_reset();
            @(negedge clk);
            in_valid = 1;
            in_address = address;
            in_access = access;
            in_data = 32'h12345678;
            @(posedge clk);
            #1;
            if (!protocol_error || request || in_ready)
                $fatal(1, "invalid metadata did not fail closed");
        end
    endtask

    initial begin
        apply_reset();
        send_and_complete(32'h04000400, 2'b10, 32'h88776655, 0);
        send_and_complete(32'h04000403, 2'b00, 32'h000000aa, 5);
        send_and_complete(32'h0400051e, 2'b01, 32'h00001234, 2);

        expect_fault(32'h040003ff, 2'b00);
        expect_fault(32'h04000520, 2'b00);
        expect_fault(32'h04000401, 2'b01);
        expect_fault(32'h04000402, 2'b10);
        expect_fault(32'h04000400, 2'b11);

        apply_reset();
        @(negedge clk);
        done = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || in_ready)
            $fatal(1, "ownerless done did not fail closed");

        apply_reset();
        @(negedge clk);
        in_valid = 1;
        in_address = 32'h04000400;
        in_access = 2'b10;
        in_data = 32'h01020304;
        @(posedge clk);
        @(negedge clk);
        in_valid = 0;
        rejected = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || request || in_ready)
            $fatal(1, "wrapper rejection did not fail closed");

        apply_reset();
        @(negedge clk);
        source_error = 1;
        @(posedge clk);
        #1;
        if (!protocol_error || request || in_ready)
            $fatal(1, "source fault did not fail closed");

        $display("PASS: released sound writes are held exactly once through wrapper completion and a mandatory release bubble");
        $display("PASS: payload mutation, delayed completion, bad metadata, stale done/reject, and source faults fail closed");
        $finish;
    end
endmodule

