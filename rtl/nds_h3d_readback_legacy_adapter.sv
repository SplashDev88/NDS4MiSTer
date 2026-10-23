// Uncached legacy DDR channel3 adapter. Preserve/drain ownership across guest
// and H3D resets because the legacy DDR controller itself has no reset input.
module nds_h3d_readback_legacy_adapter #(
    parameter bit BURST_ENABLE = 0
) (
    input logic clk, boot_reset, cancel,
    input logic read,
    input logic [28:0] address,
    input logic [7:0] burst_count,
    output logic busy, command_accepted,
    output logic [63:0] read_data,
    output logic read_data_ready,
    output logic ch_request,
    output logic [27:1] ch_address,
    output logic [7:0] ch_burst,
    input logic ch_valid,
    input logic ch_ready,
    input logic [63:0] ch_data
);
    logic pending=0, canceled=0, response_pending=0, first_beat=0;
    assign busy=pending || response_pending || cancel || boot_reset;
    always_ff @(posedge clk) begin
        ch_request<=0;
        command_accepted<=0;
        read_data_ready<=0;
        if(boot_reset) begin
            pending<=0;canceled<=0;response_pending<=0;first_beat<=0;
        end else begin
            if(cancel && pending) canceled<=1;
            if(response_pending) begin
                response_pending<=0;
                if(!cancel) read_data_ready<=1;
            end
            if(read && !busy) begin
                // Legacy adds0x30000000 and uses a halfword-address port.
                ch_address<={address[24:0],2'b00};
                ch_burst<=BURST_ENABLE && burst_count!=0 ? burst_count : 8'd1;
                ch_request<=1;pending<=1;canceled<=0;first_beat<=1;
            end
            // The legacy controller owns the complete burst until ch_ready.
            // Forward every accepted beat; cancellation suppresses delivery
            // but retains ownership until the old tail has drained.
            if(BURST_ENABLE && pending && ch_valid && !canceled && !cancel) begin
                command_accepted<=first_beat;
                first_beat<=0;
                read_data<=ch_data;
                read_data_ready<=1;
            end
            if(pending && ch_ready) begin
                pending<=0;
                if(!BURST_ENABLE && !canceled && !cancel) begin
                    // Completion proves physical acceptance; deliver data on
                    // the following edge so a normal accepted/response FSM works.
                    command_accepted<=1;read_data<=ch_data;response_pending<=1;
                end
            end
        end
    end
endmodule
