`timescale 1ns/1ps
module tb_nds_hps_irq_doorbell;
    logic clk = 0;
    logic reset = 1;
    logic mailbox_pending = 0;
    logic posted_commit = 0;
    logic [31:0] posted_commit_sequence = 0;
    logic hps_ack = 0;
    logic [31:0] hps_ack_sequence = 0;
    logic external_error = 0;
    logic irq;
    logic [31:0] advertised_sequence;
    logic [31:0] acknowledged_sequence;
    logic ack_accepted;
    logic protocol_error;

    always #5 clk = ~clk;

    nds_hps_irq_doorbell dut(.*);

    task automatic step;
        begin @(posedge clk); #1; end
    endtask

    task automatic check_true(input logic condition, input string message);
        if (!condition) $fatal(1, "FAIL: %s", message);
    endtask

    task automatic send_commit(input logic [31:0] seq_value);
        begin
            posted_commit = 1;
            posted_commit_sequence = seq_value;
            step();
            posted_commit = 0;
        end
    endtask

    task automatic send_ack(input logic [31:0] seq_value);
        begin
            hps_ack = 1;
            hps_ack_sequence = seq_value;
            step();
            hps_ack = 0;
        end
    endtask

    initial begin
        repeat (2) step();
        reset = 0;
        step();
        check_true(!irq && advertised_sequence == 0 &&
                acknowledged_sequence == 0 && !protocol_error,
                "reset state");

        mailbox_pending = 1;
        #1 check_true(irq, "mailbox level asserts IRQ without an edge counter");
        repeat (3) step();
        check_true(irq, "mailbox IRQ remains asserted while response is held");
        mailbox_pending = 0;
        #1 check_true(!irq, "mailbox completion clears its level");

        send_commit(1);
        check_true(irq && advertised_sequence == 1 &&
                acknowledged_sequence == 0,
                "first posted commit asserts IRQ");
        repeat (4) step();
        check_true(irq, "posted IRQ is sticky until sequence ACK");
        send_ack(1);
        check_true(!irq && acknowledged_sequence == 1 && ack_accepted,
                "matching ACK clears posted IRQ");
        step();
        check_true(!ack_accepted, "accepted ACK is a one-cycle pulse");

        send_commit(2);
        send_commit(3);
        check_true(irq && advertised_sequence == 3,
                "multiple commits coalesce at newest sequence");
        send_ack(2);
        check_true(irq && acknowledged_sequence == 2,
                "partial ACK cannot hide later work");
        send_ack(3);
        check_true(!irq, "ACK through producer clears coalesced work");

        // The HPS ACKs the old producer on the same edge a new entry commits.
        // Nonblocking updates must leave sequence four pending.
        posted_commit = 1;
        posted_commit_sequence = 4;
        hps_ack = 1;
        hps_ack_sequence = 3;
        step();
        posted_commit = 0;
        hps_ack = 0;
        check_true(irq && advertised_sequence == 4 &&
                acknowledged_sequence == 3 && !protocol_error,
                "new commit wins over simultaneous old ACK");

        // Fail closed: an ACK for unseen work must not clear the IRQ.
        send_ack(5);
        check_true(irq && acknowledged_sequence == 3 && protocol_error &&
                !ack_accepted,
                "future ACK is rejected without hiding pending work");

        reset = 1;
        step();
        reset = 0;
        step();
        check_true(!irq && !protocol_error && !ack_accepted,
                "session reset clears sequences and sticky fault");

        external_error = 1;
        #1 check_true(irq, "external transport fault holds IRQ level");
        external_error = 0;
        #1 check_true(!irq, "clearing external fault releases idle IRQ");

        // A zero/non-monotonic commit is an ABI violation and never advertises
        // fake work. The sticky fault itself keeps IRQ asserted so it cannot
        // be missed by an edge-coalescing userspace waiter.
        send_commit(0);
        check_true(irq && advertised_sequence == 0 && protocol_error,
                "commit zero rejected fail-closed");

        reset = 1;
        step();
        reset = 0;
        step();
        send_commit(1);
        send_ack(1);
        send_commit(3);
        check_true(irq && advertised_sequence == 1 &&
                acknowledged_sequence == 1 && protocol_error,
                "commit sequence gap rejected and reported");

        $display("PASS: HPS IRQ doorbell coalesces work, holds level, and preserves ACK/commit ordering");
        $finish;
    end
endmodule
