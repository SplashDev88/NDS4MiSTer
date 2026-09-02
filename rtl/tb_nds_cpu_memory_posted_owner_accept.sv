module tb_nds_cpu_memory_posted_owner_accept;
    localparam logic [28:0] MAIN = 29'h00100000;
    localparam logic [28:0] SHARED = 29'h00180000;
    localparam logic [28:0] ARM7 = 29'h001a0000;
    localparam logic [28:0] ORACLE = 29'h00200000;
    localparam logic [28:0] POSTED = 29'h00300000;

    logic clk = 0;
    logic reset = 1;
    logic request = 0;
    logic cpu_is_arm9 = 1;
    logic [31:0] address = 0;
    logic read_not_write = 0;
    logic [1:0] access = 2'b10;
    logic [31:0] write_data = 0;
    logic [31:0] read_data;
    logic done;
    logic cpu_pause;

    logic mem_read;
    logic mem_write;
    logic [7:0] mem_burst;
    logic [28:0] mem_address;
    logic [63:0] mem_write_data;
    logic [7:0] mem_be;
    logic mem_busy;
    logic [63:0] mem_read_data;
    logic mem_read_ready;
    logic mem_command_accepted;

    logic physical_read;
    logic physical_write;
    logic [7:0] physical_burst;
    logic [28:0] physical_address;
    logic [63:0] physical_write_data;
    logic [7:0] physical_be;
    logic physical_busy = 1;

    logic [28:0] accepted_address [0:4];
    integer physical_write_accepts = 0;

    always #5 clk = ~clk;

    nds_cpu_memory_system #(
        .MAIN_RAM_BASE_WORD(MAIN),
        .SHARED_WRAM_BASE_WORD(SHARED),
        .ARM7_WRAM_BASE_WORD(ARM7),
        .ORACLE_BASE_WORD(ORACLE),
        .POSTED_RING_BASE_WORD(POSTED),
        .ORACLE_POLL_DELAY_CYCLES(1),
        .TIME_FLUSH_CYCLES(8192)
    ) memory (
        .clk, .reset, .transport_reset(reset), .request, .cpu_is_arm9,
        .arm9_cycles(8'd0), .arm9_cycles_valid(1'b0),
        .arm7_cycles(8'd0), .arm7_cycles_valid(1'b0),
        .arm9_debug_pc(32'h02001000),
        .arm7_debug_pc(32'h037f8000),
        .request_debug_pc(32'h02001000),
        .arm9_dtcm_region(32'h0300000a),
        .arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(1'b1),
        .arm9_dtcm_irq_vector(32'h01ffd5ec),
        .address, .read_not_write, .access, .write_data,
        .read_data, .done,
        .irq_arm9(), .irq_arm7(), .halt_arm9(), .halt_arm7(),
        .cpu_pause,
        .debug_oracle_request(),
        .debug_mailbox_request(),
        .debug_mailbox_done(),
        .ddram_read(mem_read), .ddram_write(mem_write),
        .ddram_burst_count(mem_burst), .ddram_address(mem_address),
        .ddram_write_data(mem_write_data),
        .ddram_byte_enable(mem_be),
        .ddram_busy(mem_busy),
        .ddram_command_accepted(mem_command_accepted),
        .ddram_read_data(mem_read_data),
        .ddram_read_data_ready(mem_read_ready)
    );

    nds_ddram_arbiter outer (
        .clk, .reset,
        .a_rd(mem_read), .a_we(mem_write),
        .a_burstcnt(mem_burst), .a_addr(mem_address),
        .a_din(mem_write_data), .a_be(mem_be),
        .a_busy(mem_busy), .a_dout(mem_read_data),
        .a_dout_ready(mem_read_ready),
        .a_command_accepted(mem_command_accepted),
        .b_rd(1'b0), .b_we(1'b0), .b_burstcnt(8'd1),
        .b_addr(29'd0), .b_din(64'd0), .b_be(8'hff),
        .b_busy(), .b_dout(), .b_dout_ready(),
        .b_command_accepted(),
        .ddram_rd(physical_read), .ddram_we(physical_write),
        .ddram_burstcnt(physical_burst),
        .ddram_addr(physical_address),
        .ddram_din(physical_write_data), .ddram_be(physical_be),
        .ddram_busy(physical_busy),
        .ddram_dout(64'h0), .ddram_dout_ready(1'b0)
    );

    always_ff @(posedge clk) begin
        if (physical_write && !physical_busy) begin
            accepted_address[physical_write_accepts] <= physical_address;
            physical_write_accepts <= physical_write_accepts + 1;
        end
    end

    initial begin : timeout_guard
        repeat (500) @(posedge clk);
        $fatal(1,
            "timeout accepts=%0d owner_pending=%0d posted_state=%0d",
            physical_write_accepts,
            memory.ddram_owner_pending,
            memory.posted_write_ring.state);
    end

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;

        // Admit a normal main-RAM write into the outer queue while physical
        // DDR remains stalled. The local client is allowed to complete at
        // queue admission, so a newer CPU request can already be visible.
        @(negedge clk);
        address = 32'h02000000;
        write_data = 32'h11223344;
        access = 2'b10;
        request = 1;
        wait (done);
        @(negedge clk);
        request = 0;
        wait (!done);
        if (!memory.ddram_owner_pending ||
            memory.ddram_pending_owner_posted)
            $fatal(1, "local DDR command owner was not tagged");

        // Start a posted VRAM write before the older local command reaches
        // physical DDR. It must not consume that older acceptance pulse.
        @(negedge clk);
        address = 32'h0600c000;
        write_data = 32'h000055aa;
        access = 2'b01;
        request = 1;
        wait (memory.posted_write_ring.state == 4);

        @(negedge clk);
        physical_busy = 0;
        wait (physical_write_accepts == 1);
        #1;
        if (accepted_address[0] != MAIN)
            $fatal(1, "first physical command was not the older local write");
        if (memory.posted_write_ring.state != 4 ||
            memory.posted_write_ring.producer_sequence != 0)
            $fatal(1,
                "stale local acceptance falsely retired posted address/data");

        // The first posted command emitted after the stale acceptance must
        // still be address/data, followed by cycles/control and commit.
        wait (physical_write &&
              physical_address >= POSTED + 8);
        if (physical_address != POSTED + 8)
            $fatal(1,
                "first posted DDR beat skipped after stale owner accept: %h",
                physical_address);
        wait (done);
        #1;
        if (physical_write_accepts != 4)
            $fatal(1, "posted entry did not produce exactly three writes");
        if (accepted_address[1] != POSTED + 8 ||
            accepted_address[2] != POSTED + 9 ||
            accepted_address[3] != POSTED + 10)
            $fatal(1, "posted beats were not accepted in atomic order");

        @(negedge clk);
        request = 0;
        $display("PASS: physical DDR acceptance is returned only to its tagged CPU sub-owner");
        $finish;
    end
endmodule
