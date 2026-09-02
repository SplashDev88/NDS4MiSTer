// Level-triggered FPGA-to-HPS work doorbell.
//
// Linux interrupt delivery is only a notification: signals/IRQs may coalesce.
// Posted work is therefore represented by monotonic producer/acknowledgement
// sequences, not by counting interrupt edges.  The IRQ remains asserted until
// the HPS acknowledges every advertised commit.  A new commit wins over an ACK
// arriving on the same clock edge because its newer sequence remains pending.
// Blocking mailbox work remains asserted by its own PENDING level and is
// completed only by the mailbox response path.
module nds_hps_irq_doorbell (
    input  logic        clk,
    input  logic        reset,
    input  logic        mailbox_pending,
    input  logic        posted_commit,
    input  logic [31:0] posted_commit_sequence,
    input  logic        hps_ack,
    input  logic [31:0] hps_ack_sequence,
    input  logic        external_error,
    output logic        irq,
    output logic [31:0] advertised_sequence,
    output logic [31:0] acknowledged_sequence,
    output logic        ack_accepted,
    output logic        protocol_error
);
    // A sticky protocol fault is work too: keep the level asserted until the
    // transport session is reset so userspace cannot silently miss it.
    assign irq = mailbox_pending || protocol_error || external_error ||
                 (advertised_sequence != acknowledged_sequence);

    always_ff @(posedge clk) begin
        if (reset) begin
            advertised_sequence <= 32'h0;
            acknowledged_sequence <= 32'h0;
            ack_accepted <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            ack_accepted <= 1'b0;
            if (posted_commit) begin
                // Sequence zero is the ring's uncommitted marker, and the
                // current ABI is monotonic/non-wrapping.
                if (posted_commit_sequence == 0 ||
                    advertised_sequence == 32'hffffffff ||
                    posted_commit_sequence != advertised_sequence + 32'd1)
                    protocol_error <= 1'b1;
                else
                    advertised_sequence <= posted_commit_sequence;
            end

            if (hps_ack) begin
                // Never let a corrupt/stale userspace ACK hide work.  An ACK
                // may advance only through work already advertised before
                // this edge; a simultaneous newer commit therefore set-wins.
                if (hps_ack_sequence < acknowledged_sequence ||
                    hps_ack_sequence > advertised_sequence)
                    protocol_error <= 1'b1;
                else begin
                    acknowledged_sequence <= hps_ack_sequence;
                    ack_accepted <= 1'b1;
                end
            end
        end
    end
endmodule
