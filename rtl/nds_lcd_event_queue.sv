// SPDX-License-Identifier: GPL-3.0-or-later
// Nonblocking FPGA-to-HPS LCD event queue. A full queue drops only renderer
// records. It never stops the local LCD owner, DMA, IRQ, or either CPU.

`timescale 1ns/1ps
`default_nettype none

module nds_lcd_event_queue #(
    parameter bit ENABLED = 1'b0,
    parameter integer DEPTH = 64,
    parameter integer BASE_WORD = 63
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,

    input  logic        push_valid,
    input  logic [31:0] push_sequence,
    input  logic [63:0] push_timestamp,
    input  logic [1:0]  push_kind,
    input  logic [8:0]  push_line,
    input  logic [8:0]  push_vcount,
    input  logic [15:0] push_dispstat9,
    input  logic [15:0] push_dispstat7,
    input  logic [31:0] push_frame_sequence,
    output logic        push_accepted,
    output logic        push_dropped,

    input  logic [18:0] reg_raddr,
    output logic [31:0] reg_rdata,
    output logic        reg_read_select,
    input  logic [18:0] reg_waddr,
    input  logic [31:0] reg_wdata,
    input  logic [3:0]  reg_be,
    input  logic        reg_write,
    output logic        reg_write_select,
    output logic        work_pending_irq,

    output logic [$clog2(DEPTH + 1)-1:0] queue_level,
    output logic [31:0] producer_sequence,
    output logic [31:0] consumer_sequence,
    output logic [31:0] dropped_count,
    output logic        protocol_error
);
    localparam integer PTR_W = DEPTH <= 2 ? 1 : $clog2(DEPTH);
    localparam integer RECORD_W = 180;
    localparam logic [31:0] MAGIC = 32'h4c434451; // "LCDQ"
    localparam logic [31:0] ACK_MAGIC = 32'h4c41434b; // "LACK"

    localparam integer REG_MAGIC = BASE_WORD + 0;
    localparam integer REG_STATUS = BASE_WORD + 1;
    localparam integer REG_PRODUCER = BASE_WORD + 2;
    localparam integer REG_HEAD_SEQUENCE = BASE_WORD + 3;
    localparam integer REG_HEAD_TS_LO = BASE_WORD + 4;
    localparam integer REG_HEAD_TS_HI = BASE_WORD + 5;
    localparam integer REG_HEAD_META = BASE_WORD + 6;
    localparam integer REG_HEAD_DISPSTAT = BASE_WORD + 7;
    localparam integer REG_HEAD_FRAME = BASE_WORD + 8;
    localparam integer REG_DROPPED = BASE_WORD + 9;
    localparam integer REG_ACK_SEQUENCE = BASE_WORD + 10;
    localparam integer REG_ACK_COMMIT = BASE_WORD + 11;

    // Keep the packed store in M10K. The two visible cache slots preserve an
    // immediate, stable LW head while the synchronous port reads entry three
    // one clock before an ACK can promote it.
    (* ramstyle = "M10K" *)
    logic [RECORD_W-1:0] record_mem [0:DEPTH-1];
    logic [RECORD_W-1:0] head_record;
    logic [RECORD_W-1:0] next_record;
    logic [RECORD_W-1:0] prefetch_ram_q;
    logic prefetch_bypass_valid;
    logic [RECORD_W-1:0] prefetch_bypass_data;
    logic [PTR_W-1:0] write_pointer, read_pointer;
    logic [31:0] ack_sequence_hold;
    logic ack_sequence_valid;
    logic pop_accepted;
    logic push_can_accept;

    function automatic logic [PTR_W-1:0] increment_pointer(
        input logic [PTR_W-1:0] pointer
    );
        if (pointer == DEPTH - 1)
            increment_pointer = '0;
        else
            increment_pointer = pointer + 1'b1;
    endfunction

    wire [RECORD_W-1:0] push_record = {
        push_frame_sequence, push_dispstat7, push_dispstat9,
        push_vcount, push_line, push_kind, push_timestamp, push_sequence
    };
    wire [31:0] head_sequence = head_record[31:0];
    wire [63:0] head_timestamp = head_record[95:32];
    wire [1:0] head_kind = head_record[97:96];
    wire [8:0] head_line = head_record[106:98];
    wire [8:0] head_vcount = head_record[115:107];
    wire [15:0] head_dispstat9 = head_record[131:116];
    wire [15:0] head_dispstat7 = head_record[147:132];
    wire [31:0] head_frame = head_record[179:148];

    wire empty = queue_level == 0;
    wire full = queue_level == DEPTH;
    wire [PTR_W-1:0] read_pointer_plus_one =
        increment_pointer(read_pointer);
    wire [PTR_W-1:0] read_pointer_plus_two =
        increment_pointer(read_pointer_plus_one);
    wire [PTR_W-1:0] read_pointer_plus_three =
        increment_pointer(read_pointer_plus_two);
    // Without a pop, keep logical entry three warm. A pop consumes that entry
    // into next_record, so request logical entry four for the following ACK.
    wire [PTR_W-1:0] prefetch_read_address = pop_accepted
        ? read_pointer_plus_three : read_pointer_plus_two;
    wire record_store = !reset && push_can_accept;
    wire prefetch_write_collision = record_store &&
        write_pointer == prefetch_read_address;
    wire [RECORD_W-1:0] prefetch_record = prefetch_bypass_valid
        ? prefetch_bypass_data : prefetch_ram_q;
    wire address_read_hit = reg_raddr >= REG_MAGIC &&
                            reg_raddr <= REG_ACK_COMMIT;
    wire address_write_hit = reg_waddr == REG_ACK_SEQUENCE ||
                             reg_waddr == REG_ACK_COMMIT;
    wire ack_sequence_write = reg_write_select &&
                              reg_waddr == REG_ACK_SEQUENCE;
    wire ack_commit_write = reg_write_select &&
                            reg_waddr == REG_ACK_COMMIT;
    wire ack_shape_legal = reg_be == 4'hf;
    wire ack_commit_matches = ack_sequence_valid && !empty &&
        ack_sequence_hold == head_sequence &&
        reg_wdata == ACK_MAGIC;

    // A compiled queue exposes its read-only identity and reset state before
    // the transport session is armed. This lets HPS reject an old core and
    // prove a clean epoch before its first device write. Runtime enable still
    // gates all ACK writes, event admission, and the work interrupt.
    assign reg_read_select = ENABLED && address_read_hit;
    assign reg_write_select = ENABLED && enable && reg_write &&
                              address_write_hit;
    assign pop_accepted = ack_commit_write && ack_shape_legal &&
                          ack_commit_matches && !protocol_error;
    assign push_can_accept = ENABLED && enable && push_valid &&
                             (!full || pop_accepted);
    assign push_accepted = push_can_accept;
    assign push_dropped = ENABLED && enable && push_valid &&
                          !push_can_accept;
    assign work_pending_irq = ENABLED && enable &&
                              (!empty || protocol_error);

    // Keep write forwarding outside the RAM-q assignment. This leaves a
    // canonical synchronous simple-dual-port inference form while preserving
    // a newly accepted third entry during a same-address read/write clock.
    always_ff @(posedge clk) begin
        if (record_store)
            record_mem[write_pointer] <= push_record;
        prefetch_ram_q <= record_mem[prefetch_read_address];
    end

    always_ff @(posedge clk) begin
        if (reset || !ENABLED) begin
            prefetch_bypass_valid <= 1'b0;
        end else begin
            prefetch_bypass_valid <= prefetch_write_collision;
            if (prefetch_write_collision)
                prefetch_bypass_data <= push_record;
        end
    end

    always_comb begin
        reg_rdata = 32'd0;
        if (reg_read_select) begin
            case (reg_raddr)
                REG_MAGIC: reg_rdata = MAGIC;
                REG_STATUS: begin
                    reg_rdata[15:0] = queue_level;
                    reg_rdata[16] = empty;
                    reg_rdata[17] = full;
                    reg_rdata[30] = enable;
                    reg_rdata[31] = protocol_error;
                end
                REG_PRODUCER: reg_rdata = producer_sequence;
                REG_HEAD_SEQUENCE: reg_rdata = empty ? 32'd0 :
                    head_sequence;
                REG_HEAD_TS_LO: reg_rdata = empty ? 32'd0 :
                    head_timestamp[31:0];
                REG_HEAD_TS_HI: reg_rdata = empty ? 32'd0 :
                    head_timestamp[63:32];
                REG_HEAD_META: if (!empty) begin
                    reg_rdata[8:0] = head_line;
                    reg_rdata[17:9] = head_vcount;
                    reg_rdata[19:18] = head_kind;
                end
                REG_HEAD_DISPSTAT: reg_rdata = empty ? 32'd0 :
                    {head_dispstat7, head_dispstat9};
                REG_HEAD_FRAME: reg_rdata = empty ? 32'd0 :
                    head_frame;
                REG_DROPPED: reg_rdata = dropped_count;
                REG_ACK_SEQUENCE: reg_rdata = consumer_sequence;
                REG_ACK_COMMIT: reg_rdata = ack_sequence_valid
                    ? ack_sequence_hold : 32'd0;
                default: reg_rdata = 32'd0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset || !ENABLED) begin
            write_pointer <= '0;
            read_pointer <= '0;
            queue_level <= '0;
            producer_sequence <= 32'd0;
            consumer_sequence <= 32'd0;
            dropped_count <= 32'd0;
            ack_sequence_hold <= 32'd0;
            ack_sequence_valid <= 1'b0;
            protocol_error <= 1'b0;
        end else if (enable) begin
            if (push_valid)
                producer_sequence <= push_sequence;
            if (push_dropped)
                dropped_count <= dropped_count + 32'd1;

            if (ack_sequence_write) begin
                if (!ack_shape_legal || protocol_error) begin
                    protocol_error <= 1'b1;
                end else begin
                    ack_sequence_hold <= reg_wdata;
                    ack_sequence_valid <= 1'b1;
                end
            end
            if (ack_commit_write) begin
                if (!ack_shape_legal || !ack_commit_matches ||
                    protocol_error) begin
                    protocol_error <= 1'b1;
                end else begin
                    consumer_sequence <= ack_sequence_hold;
                    ack_sequence_valid <= 1'b0;
                end
            end

            if (push_can_accept)
                write_pointer <= increment_pointer(write_pointer);
            if (pop_accepted) begin
                read_pointer <= increment_pointer(read_pointer);
                if (queue_level > 1) begin
                    head_record <= next_record;
                    if (queue_level > 2)
                        next_record <= prefetch_record;
                    else if (push_can_accept)
                        next_record <= push_record;
                end else if (push_can_accept) begin
                    head_record <= push_record;
                end
            end else if (push_can_accept) begin
                if (empty)
                    head_record <= push_record;
                else if (queue_level == 1)
                    next_record <= push_record;
            end

            case ({push_can_accept, pop_accepted})
                2'b10: queue_level <= queue_level + 1'b1;
                2'b01: queue_level <= queue_level - 1'b1;
                default: queue_level <= queue_level;
            endcase
        end
    end
endmodule

`default_nettype wire
