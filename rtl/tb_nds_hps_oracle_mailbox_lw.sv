`timescale 1ns/1ps
// End-to-end check of the lightweight-bridge mailbox: a stalled CPU request
// must become visible to the HPS through the AXI slave, and the HPS's response
// write must release the CPU with the right payload and flags.
//
// The AXI stimulus mirrors what the bridge primitive emits for a single ARM
// load or store: awlen/arlen are zero, one data beat, and the master holds
// bready/rready high.
module tb_nds_hps_oracle_mailbox_lw;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;

    // CPU side
    logic        request = 0, cpu_is_arm9 = 0, read_not_write = 0;
    logic [1:0]  access = 0;
    logic [31:0] address = 0, write_data = 0, elapsed_cycles = 0, fence_sequence = 0;
    logic [31:0] read_data;
    logic        irq_arm9, irq_arm7, halt_arm9, halt_arm7, done;
    logic [31:0] completed_fence_sequence;
    logic [31:0] completed_fence_epoch;
    logic [3:0]  debug_state;
    logic        request_pending_irq;
    logic        posted_commit = 0;
    logic [31:0] posted_commit_sequence = 0;
    logic        transport_fault = 0;
    logic        posted_ack;
    logic [31:0] posted_ack_epoch;
    logic [31:0] posted_ack_sequence;
    logic        doorbell_protocol_error;
    logic        transport_ready;
    logic [31:0] active_session_epoch;
    logic [31:0] active_session_capabilities;

    // AXI side
    logic [11:0] awid = 0; logic [20:0] awaddr = 0; logic awvalid = 0; logic awready;
    logic [31:0] wdata = 0; logic [3:0] wstrb = 4'hf; logic wvalid = 0; logic wready;
    logic [11:0] bid; logic [1:0] bresp; logic bvalid; logic bready = 1;
    logic [11:0] arid = 0; logic [20:0] araddr = 0; logic arvalid = 0; logic arready;
    logic [11:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid;
    logic rready = 1;

    // register file interconnect
    logic [18:0] reg_raddr, reg_waddr;
    logic [31:0] reg_rdata, reg_wdata;
    logic [3:0]  reg_be;
    logic        reg_write;

    nds_hps_lw_slave slave(
        .clk(clk), .reset(reset),
        .awid(awid), .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .reg_waddr(reg_waddr), .reg_wdata(reg_wdata),
        .reg_be(reg_be), .reg_write(reg_write));

    nds_hps_oracle_mailbox_lw dut_mailbox(
        .clk(clk), .reset(reset), .request(request), .cpu_is_arm9(cpu_is_arm9),
        .elapsed_cycles(elapsed_cycles), .fence_sequence(fence_sequence),
        .address(address), .read_not_write(read_not_write), .access(access),
        .write_data(write_data), .read_data(read_data),
        .irq_arm9(irq_arm9), .irq_arm7(irq_arm7),
        .halt_arm9(halt_arm9), .halt_arm7(halt_arm7),
        .done(done), .completed_fence_sequence(completed_fence_sequence),
        .completed_fence_epoch(completed_fence_epoch),
        .debug_state(debug_state), .request_pending_irq(request_pending_irq),
        .posted_commit(posted_commit),
        .posted_commit_sequence(posted_commit_sequence),
        .transport_fault(transport_fault),
        .posted_ack(posted_ack), .posted_ack_epoch(posted_ack_epoch),
        .posted_ack_sequence(posted_ack_sequence),
        .doorbell_protocol_error(doorbell_protocol_error),
        .transport_ready(transport_ready),
        .active_session_epoch(active_session_epoch),
        .active_session_capabilities(active_session_capabilities),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .reg_waddr(reg_waddr), .reg_wdata(reg_wdata),
        .reg_be(reg_be), .reg_write(reg_write));

    integer errors = 0;
    integer posted_ack_pulses = 0;
    always @(posedge clk) if (posted_ack) posted_ack_pulses <= posted_ack_pulses + 1;
    task check_eq(input string what, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got %08x want %08x", what, got, want);
            errors = errors + 1;
        end
    endtask

    // One ARM load through the bridge.
    task axi_read(input [20:0] byte_addr, output [31:0] value);
        begin
            @(negedge clk); araddr = byte_addr; arvalid = 1;
            wait (arready == 1); @(negedge clk); arvalid = 0;
            wait (rvalid == 1);
            value = rdata;
            if (rlast !== 1'b1) begin
                $display("FAIL rlast not set on single-beat read"); errors = errors + 1;
            end
            if (rresp !== 2'b00) begin
                $display("FAIL rresp not OKAY"); errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    // One ARM store through the bridge.
    task axi_write_be(
        input [20:0] byte_addr,
        input [31:0] value,
        input [3:0] byte_enable
    );
        begin
            @(negedge clk); awaddr = byte_addr; awvalid = 1;
            wait (awready == 1); @(negedge clk); awvalid = 0;
            wdata = value; wstrb = byte_enable; wvalid = 1;
            wait (wready == 1); @(negedge clk); wvalid = 0;
            wait (bvalid == 1); @(negedge clk);
            wstrb = 4'hf;
        end
    endtask

    task axi_write(input [20:0] byte_addr, input [31:0] value);
        begin
            axi_write_be(byte_addr, value, 4'hf);
        end
    endtask

    task advertise_posted(input [31:0] sequence_value);
        begin
            @(negedge clk);
            posted_commit_sequence = sequence_value;
            posted_commit = 1;
            @(negedge clk);
            posted_commit = 0;
        end
    endtask

    logic [31:0] v;

    task reset_and_claim(input [31:0] cookie);
        begin
            @(negedge clk);
            request = 0;
            reset = 1;
            repeat (3) @(negedge clk);
            reset = 0;
            repeat (3) @(negedge clk);
            axi_read(21'h30, v);
            check_eq("reset clears session claim", v, 32'h0);
            axi_read(21'h60, v);
            check_eq("reset clears session arm", v, 32'h0);
            axi_read(21'h28, v);
            check_eq("reset disarmed transport", v, 32'h11);
            axi_write(21'h30, cookie);
            axi_read(21'h30, v);
            check_eq("fresh session claim", v, cookie);
            axi_read(21'h60, v);
            check_eq("claim does not arm", v, 32'h0);
            axi_read(21'h28, v);
            check_eq("claimed transport remains disarmed", v, 32'h11);
        end
    endtask

    task reset_and_arm(input [31:0] cookie);
        begin
            reset_and_claim(cookie);
            axi_write(21'h60, cookie);
            axi_read(21'h60, v);
            check_eq("fresh session arm", v, cookie);
            axi_read(21'h28, v);
            check_eq("fresh session ready", v, 32'h0);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        repeat (2) @(negedge clk);

        // A new/reset transport session starts disarmed. The level IRQ tells
        // HPS to initialize the DDR ring and install a fresh cookie before any
        // posted write may be admitted.
        axi_read(21'h00, v);
        check_eq("idle pending bit", {31'h0, v[0]}, 32'h0);
        axi_read(21'h2c, v);
        check_eq("LW ABI identity", v, 32'h4e445332);
        axi_read(21'h5c, v);
        check_eq("default-off LW capabilities", v, 32'h0000000d);
        axi_read(21'h28, v);
        check_eq("session-required doorbell", v, 32'h11);
        if (transport_ready)
            $fatal(1, "transport armed before HPS session handshake");
        axi_write(21'h30, 32'h51a7c0de);
        axi_read(21'h30, v);
        check_eq("session claim cookie", v, 32'h51a7c0de);
        axi_read(21'h60, v); check_eq("claim stays disarmed", v, 32'h0);
        axi_read(21'h28, v);
        check_eq("claimed idle remains session-required", v, 32'h11);
        if (transport_ready || active_session_epoch != 0 ||
            active_session_capabilities != 0)
            $fatal(1, "SESSION claim exposed an active transport");
        axi_write(21'h60, 32'h51a7c0de);
        axi_read(21'h60, v); check_eq("session arm cookie", v, 32'h51a7c0de);
        axi_read(21'h28, v); check_eq("armed idle doorbell", v, 32'h0);
        check_eq("active session epoch", active_session_epoch,
                 32'h51a7c0de);
        check_eq("active session caps", active_session_capabilities,
                 32'h0000000d);

        // Posted work is counted by producer/consumer sequence, never by IRQ
        // edges. Multiple commits may coalesce under one asserted level.
        advertise_posted(1);
        advertise_posted(2);
        if (request_pending_irq !== 1'b1) begin
            $display("FAIL posted work did not raise IRQ"); errors = errors + 1;
        end
        axi_read(21'h20, v); check_eq("coalesced producer", v, 32'd2);
        axi_read(21'h24, v); check_eq("initial consumer", v, 32'd0);
        axi_read(21'h28, v); check_eq("posted doorbell", v, 32'h9);

        axi_write(21'h24, 32'd1);
        repeat (2) @(negedge clk);
        check_eq("validated ACK pulse count", posted_ack_pulses, 32'd1);
        check_eq("validated ACK sequence", posted_ack_sequence, 32'd1);
        check_eq("validated ACK epoch", posted_ack_epoch, 32'h51a7c0de);
        axi_read(21'h24, v); check_eq("partial consumer advance", v, 32'd1);
        if (request_pending_irq !== 1'b1) begin
            $display("FAIL partial sequence ACK hid later work"); errors = errors + 1;
        end
        axi_write(21'h24, 32'd2);
        repeat (2) @(negedge clk);
        check_eq("second validated ACK pulse", posted_ack_pulses, 32'd2);
        if (request_pending_irq !== 1'b0) begin
            $display("FAIL complete sequence ACK did not clear IRQ"); errors = errors + 1;
        end

        // A partial-width ACK is not a sequence update and must fail closed.
        advertise_posted(3);
        axi_write_be(21'h24, 32'd3, 4'b0001);
        repeat (2) @(negedge clk);
        check_eq("partial ACK rejected", posted_ack_pulses, 32'd2);
        axi_read(21'h24, v); check_eq("consumer unchanged", v, 32'd2);
        if (!request_pending_irq || !doorbell_protocol_error) begin
            $display("FAIL malformed ACK did not fail closed"); errors = errors + 1;
        end
        axi_write(21'h24, 32'd3);
        repeat (2) @(negedge clk);
        check_eq("post-fault ACK rejected", posted_ack_pulses, 32'd2);
        axi_read(21'h24, v); check_eq("fault held consumer", v, 32'd2);
        axi_read(21'h28, v);
        check_eq("sticky malformed-write fault remains visible", v, 32'h1b);
        if (request_pending_irq !== 1'b1) begin
            $display("FAIL sticky protocol fault did not hold IRQ"); errors = errors + 1;
        end

        // Only a transport-session reset clears a sticky protocol fault.
        reset_and_arm(32'h6e657732);

        // SESSION is a one-shot ownership claim, not an idempotent control
        // register. Repeating either the same or a different claim is a
        // sticky protocol fault while still disarmed.
        reset_and_claim(32'h6e657740);
        axi_write(21'h30, 32'h6e657740);
        axi_read(21'h28, v);
        check_eq("repeated SESSION claim faults", v, 32'h13);
        if (transport_ready)
            $fatal(1, "repeated claim armed transport");

        reset_and_claim(32'h6e657741);
        axi_write(21'h30, 32'h6e657742);
        axi_read(21'h28, v);
        check_eq("different SESSION claim faults", v, 32'h13);

        // ARM is legal exactly once, with the claimed nonzero cookie. A
        // mismatch or repeated arm cannot silently steal/restart a session.
        reset_and_claim(32'h6e657743);
        axi_write(21'h60, 32'h6e657744);
        axi_read(21'h60, v);
        check_eq("mismatched ARM preserves disarmed value", v, 32'h0);
        axi_read(21'h28, v);
        check_eq("mismatched ARM faults", v, 32'h13);

        reset_and_arm(32'h6e657745);
        axi_write(21'h60, 32'h6e657745);
        axi_read(21'h28, v);
        check_eq("repeated ARM faults", v, 32'h13);

        // Every store outside the exact writable ABI/state is a sticky fault.
        // Test each class from a clean session so no earlier error can mask it.
        axi_write(21'h2c, 32'hffffffff); // ABI is read-only.
        axi_read(21'h28, v);
        check_eq("read-only write faults", v, 32'h13);
        if (transport_ready || !doorbell_protocol_error)
            $fatal(1, "read-only write did not revoke transport");

        reset_and_arm(32'h6e657733);
        axi_write(21'h5c, 32'hffffffff); // CAPS is read-only.
        axi_read(21'h28, v);
        check_eq("CAPS write faults", v, 32'h13);

        reset_and_arm(32'h6e657734);
        axi_write(21'h18, 32'hcafebabe); // RDATA is invalid while IDLE.
        axi_read(21'h28, v);
        check_eq("idle RDATA write faults", v, 32'h13);
        check_eq("idle RDATA preserved payload",
                 dut_mailbox.response_data, 32'h0);

        reset_and_arm(32'h6e657735);
        axi_write(21'h1c, 32'hf); // FLAGS is invalid while IDLE.
        axi_read(21'h28, v);
        check_eq("idle FLAGS write faults", v, 32'h13);
        if (done || debug_state != 4'd0)
            $fatal(1, "idle FLAGS write changed mailbox state");

        reset_and_arm(32'h6e657736);

        // ---- transaction 1: an ARM9 halfword read ----
        @(negedge clk);
        address = 32'h04000006; write_data = 32'hdeadbeef;
        read_not_write = 1; access = 2'b01; cpu_is_arm9 = 1;
        elapsed_cycles = 32'd1234; fence_sequence = 32'd77;
        request = 1;
        repeat (3) @(negedge clk);

        if (request_pending_irq !== 1'b1) begin
            $display("FAIL request_pending_irq not raised"); errors = errors + 1;
        end

        axi_read(21'h00, v);
        check_eq("pending bit set", {31'h0, v[0]}, 32'h1);
        check_eq("sequence is 1", {1'h0, v[31:1]}, 32'h1);
        axi_read(21'h04, v); check_eq("address", v, 32'h04000006);
        axi_read(21'h08, v); check_eq("write data", v, 32'hdeadbeef);
        axi_read(21'h0c, v); check_eq("control", v, {28'h0, 1'b1, 2'b01, 1'b1});
        axi_read(21'h10, v); check_eq("cycles", v, 32'd1234);
        axi_read(21'h14, v); check_eq("fence", v, 32'd77);
        axi_read(21'h64, v);
        check_eq("fence epoch captured with request", v, 32'h6e657736);

        if (done !== 1'b0) begin
            $display("FAIL done asserted before response"); errors = errors + 1;
        end

        // Partial response and completion writes are ABI violations. They may
        // neither alter the payload nor release the CPU, and the sticky fault
        // forbids a later full-width write from recovering this transaction.
        axi_write_be(21'h18, 32'hffffffff, 4'b0011);
        axi_write_be(21'h1c, 32'b1111, 4'b0001);
        repeat (2) @(negedge clk);
        if (done !== 1'b0 || debug_state != 4'd1) begin
            $display("FAIL partial response write released mailbox"); errors = errors + 1;
        end
        check_eq("partial response preserved payload",
                 dut_mailbox.response_data, 32'h0);
        axi_read(21'h28, v);
        check_eq("pending response fault doorbell", v, 32'h17);
        axi_write(21'h18, 32'h0000a5a5);
        axi_write(21'h1c, 32'b0101); // irq_arm9 + halt_arm9
        repeat (3) @(negedge clk);
        if (done !== 1'b0 || debug_state != 4'd1)
            $fatal(1, "post-fault full response recovered without reset");

        // Reset is the sole recovery boundary. Reissue the same transaction
        // in a fresh session, then publish a clean full-width response.
        reset_and_arm(32'h6e657737);
        @(negedge clk);
        address = 32'h04000006; write_data = 32'hdeadbeef;
        read_not_write = 1; access = 2'b01; cpu_is_arm9 = 1;
        elapsed_cycles = 32'd1234; fence_sequence = 32'd77;
        request = 1;
        repeat (3) @(negedge clk);
        axi_read(21'h00, v);
        check_eq("reissued pending bit", {31'h0, v[0]}, 32'h1);
        check_eq("reissued sequence is 1", {1'h0, v[31:1]}, 32'h1);
        axi_write(21'h18, 32'h0000a5a5);
        if (done !== 1'b0) begin
            $display("FAIL done asserted on payload write alone"); errors = errors + 1;
        end
        axi_write(21'h1c, 32'b0101); // irq_arm9 + halt_arm9

        // done is a single pulse, so sample it as it goes by.
        begin : wait_done
            integer guard;
            guard = 0;
            while (done !== 1'b1 && guard < 20) begin
                @(posedge clk); guard = guard + 1;
            end
            if (done !== 1'b1) begin
                $display("FAIL done never pulsed"); errors = errors + 1;
            end
        end
        check_eq("read data", read_data, 32'h0000a5a5);
        check_eq("irq_arm9", {31'h0, irq_arm9}, 32'h1);
        check_eq("irq_arm7", {31'h0, irq_arm7}, 32'h0);
        check_eq("halt_arm9", {31'h0, halt_arm9}, 32'h1);
        check_eq("halt_arm7", {31'h0, halt_arm7}, 32'h0);
        check_eq("fence returned", completed_fence_sequence, 32'd77);
        check_eq("fence epoch returned", completed_fence_epoch,
                 32'h6e657737);

        // Release, and confirm the mailbox re-arms.
        @(negedge clk); request = 0;
        repeat (3) @(negedge clk);
        axi_read(21'h00, v);
        check_eq("pending clear after release", {31'h0, v[0]}, 32'h0);

        // ---- transaction 2: sequence must advance so the HPS can tell a new
        // request from a re-read of the previous one ----
        @(negedge clk);
        address = 32'h04000180; read_not_write = 0; access = 2'b10;
        cpu_is_arm9 = 0; fence_sequence = 32'd78; request = 1;
        repeat (3) @(negedge clk);
        axi_read(21'h00, v);
        check_eq("second pending", {31'h0, v[0]}, 32'h1);
        check_eq("sequence advanced", {1'h0, v[31:1]}, 32'h2);
        axi_read(21'h0c, v); check_eq("arm7 control", v, {28'h0, 1'b0, 2'b10, 1'b0});
        axi_write(21'h18, 32'h11223344);
        axi_write(21'h1c, 32'b0000);
        repeat (2) @(posedge clk);
        check_eq("second read data", read_data, 32'h11223344);
        check_eq("no spurious irq", {31'h0, irq_arm9 | irq_arm7}, 32'h0);
        @(negedge clk); request = 0;
        repeat (3) @(negedge clk);

        if (errors == 0)
            $display("PASS: strict NDS2 LW ABI, two-phase session, epoch fence, fail-stop mailbox/doorbell, validated ACKs, and reset re-arm");
        else
            $display("FAILURES: %0d", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL timeout");
        $finish;
    end
endmodule
