// SPDX-License-Identifier: GPL-3.0-or-later
// Coherent RTC mailbox, independent of all guest/cart/media resets.
// IO 0x47: signature 0x5254; operation (0=read,1=request) returns 0x0100|ready;
// then four date words (seven BCD bytes + zero), then two write-sequence words.
// A request's immediate response is not its completion. Poll with operation 0.
// The per-transaction latch stays immutable, including across a new completion.
// Quartus otherwise merges even a 3-bit CDC chain into a RAM shift register
// shared with unrelated video delays. Keep this mailbox's pipelines as FFs.
(* altera_attribute="-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module nds_rtc_host_bridge (
    input wire clk, rtc_clk,
    input wire [55:0] rtc_datetime,
    input wire rtc_date_written,
    input wire io_enable, io_strobe,
    input wire [15:0] io_din,
    output wire io_override,
    output logic [15:0] io_dout = 0
);
    logic request = 0, acknowledge = 0, date_seen = 0;
    logic [31:0] write_sequence = 0;
    wire [31:0] current_sequence = write_sequence + {31'd0, rtc_date_written != date_seen};
    (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [2:0] request_sync = 0, ack_sync = 0;
    logic [87:0] snapshot_rtc = 0;
    (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [87:0] snapshot_meta = 0, snapshot_sync = 0;
    logic valid = 0, selected = 0;
    logic [3:0] io_count = 0;
    logic [95:0] transaction = 0;
    wire ready = valid && ack_sync[2] == request;
    assign io_override = io_enable && selected;

    always_ff @(posedge rtc_clk) begin
        request_sync <= {request_sync[1:0],request};
        date_seen <= rtc_date_written;
        write_sequence <= current_sequence;
        if(request_sync[2] != acknowledge) begin
            snapshot_rtc <= {current_sequence,rtc_datetime};
            acknowledge <= request_sync[2];
        end
    end
    always_ff @(posedge clk) begin
        ack_sync <= {ack_sync[1:0],acknowledge};
        snapshot_meta <= snapshot_rtc;
        snapshot_sync <= snapshot_meta;
        if(!io_enable) begin
            selected <= 0; io_count <= 0; io_dout <= 0;
        end else if(io_strobe) begin
            if(io_count != 15) io_count <= io_count + 1'b1;
            if(io_count == 0) begin
                selected <= io_din == 16'h47;
                io_dout <= io_din == 16'h47 ? 16'h5254 : 16'd0;
            end else if(selected) case(io_count)
                1: begin
                    io_dout <= {15'h0080,ready}; // version 1, bit0 ready
                    transaction <= {snapshot_sync[87:56],8'd0,snapshot_sync[55:0]};
                    if(io_din == 1 && ack_sync[2] == request) begin
                        request <= ~request;
                        valid <= 1;
                    end
                end
                2,3,4,5,6,7: begin
                    io_dout <= transaction[15:0];
                    transaction <= {16'd0,transaction[95:16]};
                end
                default: io_dout <= 0;
            endcase
        end
    end
endmodule
