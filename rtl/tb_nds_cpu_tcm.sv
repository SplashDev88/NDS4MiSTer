module tb_nds_cpu_tcm;
    logic clk = 0;
    logic reset = 1;
    logic seed_valid = 0;
    logic [31:0] seed_data = 0;
    logic request = 0;
    logic [31:0] address = 0;
    logic read_not_write = 1;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] read_data;
    logic done;

    always #5 clk = ~clk;

    nds_cpu_tcm #(.ADDRESS_BITS(14)) dut (
        .clk, .reset, .seed_valid, .seed_data, .request, .address,
        .read_not_write, .access, .write_data, .read_data, .done
    );

    task automatic transact(
        input logic        transaction_read,
        input logic [1:0]  transaction_access,
        input logic [31:0] transaction_address,
        input logic [31:0] transaction_data,
        input logic [31:0] expected_read
    );
        begin
            @(negedge clk);
            address = transaction_address;
            read_not_write = transaction_read;
            access = transaction_access;
            write_data = transaction_data;
            request = 1;
            @(posedge clk);
            #1;
            if (done)
                $fatal(1, "TCM completed before synchronous RAM response");
            wait (done);
            #1;
            if (transaction_read && read_data !== expected_read)
                $fatal(1, "TCM read %h expected %h at %h",
                    read_data, expected_read, transaction_address);

            // The CPU may advance its address on the completion edge.  The
            // completed read value must remain stable until the request is
            // released.
            if (transaction_read) begin
                address = 32'h027e0000;
                #1;
                if (read_data !== expected_read)
                    $fatal(1, "TCM completion value followed live address");
            end
            @(negedge clk);
            request = 0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Reproduce the important history missing from the older production
        // cosim: an earlier scratch-buffer copy first occupies the same DTCM
        // words, followed by the nine-byte BUILDTIME copy.
        transact(0, 2'b10, 32'h027e37e0, 32'h00000000, 0);
        transact(0, 2'b01, 32'h027e37d8, 32'h00003030, 0);
        transact(0, 2'b01, 32'h027e37da, 32'h00003837, 0);
        transact(0, 2'b01, 32'h027e37dc, 32'h00003635, 0);
        transact(0, 2'b00, 32'h027e37de, 32'h00000034, 0);

        transact(0, 2'b01, 32'h027e37d8, 32'h00005542, 0);
        transact(0, 2'b01, 32'h027e37da, 32'h00004c49, 0);
        transact(0, 2'b01, 32'h027e37dc, 32'h00005444, 0);
        transact(0, 2'b01, 32'h027e37de, 32'h00004d49, 0);
        transact(0, 2'b00, 32'h027e37e0, 32'h00000045, 0);

        transact(1, 2'b10, 32'h027e37d8, 0, 32'h4c495542);
        transact(1, 2'b10, 32'h027e37dc, 0, 32'h4d495444);
        transact(1, 2'b01, 32'h027e37e0, 0, 32'h00000045);
        transact(1, 2'b00, 32'h027e37d8, 0, 32'h00000042);
        transact(1, 2'b00, 32'h027e37d9, 0, 32'h00000055);
        transact(1, 2'b00, 32'h027e37da, 0, 32'h00000049);
        transact(1, 2'b00, 32'h027e37db, 0, 32'h0000004c);

        $display("PASS: synchronous byte-lane TCM preserves two-copy BUILDTIME data");
        $finish;
    end
endmodule
