module tb_nds_sound_sample_memory_router;
    localparam logic [28:0] MAIN_BASE   = 29'h05820000;
    localparam logic [28:0] SHARED_BASE = 29'h05802000;
    localparam logic [28:0] ARM7_BASE   = 29'h05804000;

    logic clk = 0;
    logic reset = 1;
    logic sound_request = 0;
    logic [31:0] sound_address = 0;
    logic [1:0] wramcnt = 0;
    logic sound_done;
    logic [31:0] sound_data;
    logic sound_busy;
    logic protocol_error;
    logic unsupported_request;
    logic [3:0] unsupported_reason;
    logic [31:0] unsupported_address;
    logic ddram_read;
    logic [7:0] ddram_burst_count;
    logic [28:0] ddram_address;
    logic ddram_command_accepted = 0;
    logic [63:0] ddram_read_data = 0;
    logic ddram_read_data_ready = 0;
    logic ddram_epoch_quiescent = 1;

    integer completed_reads = 0;
    integer mirror_index;
    integer lane_index;
    integer mode_index;
    logic [31:0] test_address;
    logic [28:0] test_ddram_address;

    always #5 clk = ~clk;

    nds_sound_sample_memory_router #(
        .MAIN_RAM_BASE_WORD(MAIN_BASE),
        .SHARED_WRAM_BASE_WORD(SHARED_BASE),
        .ARM7_WRAM_BASE_WORD(ARM7_BASE)
    ) dut (.*);

    task automatic pulse_request(input logic [31:0] address);
        begin
            @(negedge clk);
            sound_address = address;
            sound_request = 1;
            @(negedge clk);
            sound_request = 0;
        end
    endtask

    task automatic mapped_read(
        input logic [31:0] address,
        input logic [28:0] expected_ddram_address,
        input logic delayed_response
    );
        logic [63:0] response;
        logic [31:0] expected_data;
        logic [1:0] request_wramcnt;
        begin
            request_wramcnt = wramcnt;
            response = {
                (32'hc3000000 ^ address),
                (32'h3c000000 ^ address)
            };
            expected_data = address[2] ?
                response[63:32] : response[31:0];
            pulse_request(address);
            if (!ddram_read ||
                ddram_burst_count != 8'd1 ||
                ddram_address != expected_ddram_address)
                $fatal(1,
                    "mapping mismatch wramcnt=%0d address=%08x got=%08x expected=%08x read=%0b burst=%0d",
                    wramcnt, address, ddram_address,
                    expected_ddram_address, ddram_read,
                    ddram_burst_count);

            // Inputs are pulse-qualified, not level-qualified. Mutate both the
            // address and live WRAMCNT while the command is stalled to prove
            // that the translated beat and lane were captured atomically.
            sound_address = 32'h06000000;
            wramcnt = request_wramcnt ^ 2'b11;
            #1;
            if (!ddram_read ||
                ddram_address != expected_ddram_address)
                $fatal(1,
                    "stalled request followed live address/WRAMCNT inputs");

            if (delayed_response) begin
                ddram_command_accepted = 1;
                @(posedge clk);
                @(negedge clk);
                ddram_command_accepted = 0;
                if (ddram_read || !sound_busy || sound_done)
                    $fatal(1,
                        "delayed-response wait setup failed address=%08x",
                        address);
                repeat (2) @(negedge clk);
                ddram_read_data = response;
                ddram_read_data_ready = 1;
                @(posedge clk);
                #1;
                if (!sound_done || sound_data != expected_data)
                    $fatal(1,
                        "delayed response mismatch address=%08x got=%08x expected=%08x",
                        address, sound_data, expected_data);
            end else begin
                ddram_read_data = response;
                ddram_read_data_ready = 1;
                ddram_command_accepted = 1;
                @(posedge clk);
                #1;
                if (!sound_done || sound_data != expected_data)
                    $fatal(1,
                        "same-edge response mismatch address=%08x got=%08x expected=%08x",
                        address, sound_data, expected_data);
            end

            @(negedge clk);
            ddram_command_accepted = 0;
            ddram_read_data_ready = 0;
            sound_address = 32'd0;
            wramcnt = request_wramcnt;
            completed_reads = completed_reads + 1;
        end
    endtask

    task automatic unsupported_read(
        input logic [31:0] address,
        input logic [3:0] expected_reason
    );
        begin
            pulse_request(address);
            if (!sound_done || sound_data != 0 ||
                !protocol_error || !unsupported_request ||
                unsupported_reason != expected_reason ||
                unsupported_address != address || ddram_read)
                $fatal(1,
                    "unsupported route mismatch address=%08x done=%0b data=%08x protocol=%0b pulse=%0b reason=%0d captured=%08x ddr=%0b",
                    address, sound_done, sound_data, protocol_error,
                    unsupported_request, unsupported_reason,
                    unsupported_address, ddram_read);
            @(posedge clk);
            #1;
            if (sound_done || unsupported_request || ddram_read)
                $fatal(1,
                    "unsupported completion was not a one-cycle local pulse");
        end
    endtask

    initial begin
        // A stale-high quiescence level across reset cannot release the DDR
        // epoch quarantine.
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 0;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!sound_busy || ddram_read || sound_done)
                $fatal(1,
                    "stale-high DDR epoch escaped reset quarantine");
        end

        // Robert's block has no request-ready input. Prove that a one-cycle
        // sample pulse during quarantine is retained, rather than dropped
        // while Robert waits forever for req_done.
        pulse_request(32'h02000004);
        if (!sound_busy || ddram_read || sound_done || protocol_error)
            $fatal(1,
                "new-epoch request was not buffered cleanly in quarantine");
        @(negedge clk);
        ddram_epoch_quiescent = 0;
        @(posedge clk);
        @(negedge clk);
        ddram_epoch_quiescent = 1;
        @(posedge clk);
        #1;
        if (!sound_busy || !ddram_read ||
            ddram_address != MAIN_BASE || protocol_error)
            $fatal(1,
                "buffered quarantine request did not issue after release");
        @(negedge clk);
        ddram_read_data = 64'h11112222_33334444;
        ddram_read_data_ready = 1;
        ddram_command_accepted = 1;
        @(posedge clk);
        #1;
        if (!sound_done || sound_data != 32'h11112222)
            $fatal(1,
                "buffered quarantine response mismatch");
        @(negedge clk);
        ddram_read_data_ready = 0;
        ddram_command_accepted = 0;
        completed_reads = completed_reads + 1;

        // Every one of the four 4 MiB main-RAM mirrors, both 32-bit lanes,
        // and both boundary beats.
        for (mirror_index = 0; mirror_index < 4;
             mirror_index = mirror_index + 1) begin
            test_address =
                32'h02000000 + (mirror_index * 32'h00400000);
            mapped_read(test_address, MAIN_BASE,
                (mirror_index & 1) != 0);
            mapped_read(test_address + 32'h4, MAIN_BASE,
                (mirror_index & 1) == 0);
            mapped_read(test_address + 32'h003ffff8,
                MAIN_BASE + 29'h0007ffff,
                (mirror_index & 1) == 0);
            mapped_read(test_address + 32'h003ffffc,
                MAIN_BASE + 29'h0007ffff,
                (mirror_index & 1) != 0);
        end

        // Exhaust all WRAMCNT partitions. For each mode cover the low
        // aperture's bank boundary/mirror and the always-private high
        // aperture's 64 KiB boundary/mirrors.
        for (mode_index = 0; mode_index < 4;
             mode_index = mode_index + 1) begin
            wramcnt = mode_index[1:0];
            case (mode_index)
                0: begin
                    mapped_read(32'h03000000, ARM7_BASE, 0);
                    mapped_read(32'h0300fffc,
                        ARM7_BASE + 29'h00001fff, 1);
                    mapped_read(32'h03010000, ARM7_BASE, 0);
                    mapped_read(32'h037ffffc,
                        ARM7_BASE + 29'h00001fff, 1);
                end
                1: begin
                    mapped_read(32'h03000000, SHARED_BASE, 0);
                    mapped_read(32'h03003ffc,
                        SHARED_BASE + 29'h000007ff, 1);
                    mapped_read(32'h03004000, SHARED_BASE, 0);
                    mapped_read(32'h037ffffc,
                        SHARED_BASE + 29'h000007ff, 1);
                end
                2: begin
                    mapped_read(32'h03000000,
                        SHARED_BASE + 29'h00000800, 0);
                    mapped_read(32'h03003ffc,
                        SHARED_BASE + 29'h00000fff, 1);
                    mapped_read(32'h03004000,
                        SHARED_BASE + 29'h00000800, 0);
                    mapped_read(32'h037ffffc,
                        SHARED_BASE + 29'h00000fff, 1);
                end
                default: begin
                    mapped_read(32'h03000000, SHARED_BASE, 0);
                    mapped_read(32'h03007ffc,
                        SHARED_BASE + 29'h00000fff, 1);
                    mapped_read(32'h03008000, SHARED_BASE, 0);
                    mapped_read(32'h037ffffc,
                        SHARED_BASE + 29'h00000fff, 1);
                end
            endcase

            mapped_read(32'h03800000, ARM7_BASE, 0);
            mapped_read(32'h03800004, ARM7_BASE, 1);
            mapped_read(32'h0380fff8,
                ARM7_BASE + 29'h00001fff, 1);
            mapped_read(32'h0380fffc,
                ARM7_BASE + 29'h00001fff, 0);
            mapped_read(32'h03810000, ARM7_BASE, 1);
            mapped_read(32'h03fffffc,
                ARM7_BASE + 29'h00001fff, 0);
        end

        if (protocol_error)
            $fatal(1, "valid mapping tests raised protocol_error");

        // Reset after physical acceptance but before data. The retired
        // response is ignored until an explicit new low-to-high quiescence
        // transition, after which the same address works normally.
        pulse_request(32'h02000100);
        if (!ddram_read)
            $fatal(1, "reset-quarantine setup did not issue");
        @(negedge clk);
        ddram_command_accepted = 1;
        @(posedge clk);
        @(negedge clk);
        ddram_command_accepted = 0;
        ddram_epoch_quiescent = 0;
        reset = 1;
        @(posedge clk);
        @(negedge clk);
        reset = 0;
        ddram_read_data = 64'hbad0bad0_bad1bad1;
        ddram_read_data_ready = 1;
        @(posedge clk);
        #1;
        if (sound_done || !sound_busy || ddram_read)
            $fatal(1, "retired DDR response escaped reset quarantine");
        @(negedge clk);
        ddram_read_data_ready = 0;
        ddram_epoch_quiescent = 1;
        @(posedge clk);
        #1;
        if (sound_busy)
            $fatal(1, "post-reset low-to-high quarantine did not release");
        mapped_read(32'h02000100,
            MAIN_BASE + 29'h00000020, 0);

        // All four low address residues are covered for each supported region:
        // residue zero succeeded above; residues 1..3 must fail closed.
        for (lane_index = 1; lane_index < 4;
             lane_index = lane_index + 1) begin
            unsupported_read(
                32'h02001000 + lane_index, 4'd1);
            unsupported_read(
                32'h03001000 + lane_index, 4'd1);
            unsupported_read(
                32'h03801000 + lane_index, 4'd1);
        end

        // Classified unsupported ARM7-view regions never issue DDR.
        unsupported_read(32'h00000000, 4'd2);
        unsupported_read(32'h04000000, 4'd3);
        unsupported_read(32'h04800000, 4'd5);
        unsupported_read(32'h06000000, 4'd4);
        unsupported_read(32'h00004000, 4'd6);
        unsupported_read(32'h05000000, 4'd6);
        unsupported_read(32'h08000000, 4'd6);
        unsupported_read(32'hffffffff, 4'd1);

        if (completed_reads != 58)
            $fatal(1, "mapped read coverage count mismatch: %0d",
                completed_reads);

        $display(
            "PASS: ARM7-view sound samples exhaust main/WRAM mirrors, WRAMCNT partitions, lanes, faults, response timing, and reset quarantine");
        $display("INFO: mapped_reads=%0d final_fault=%08x/%0d",
            completed_reads, unsupported_address, unsupported_reason);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "sound sample memory router timeout");
    end
endmodule
