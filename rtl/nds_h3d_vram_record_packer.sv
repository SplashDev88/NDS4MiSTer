// SPDX-License-Identifier: GPL-3.0-or-later
// Original VRAM packing implementation supplied by InsaneFriend (saneFriend).
`timescale 1ns/1ps

// Ordered VRAM-write packer between the record CDC and the H3B1 writer.
//
// Every mirrored ARM9 VRAM write used to be its own 16-byte record, so a
// 16-bit DMA upload cost eight record bytes per data byte. The DDR port the
// writer shares with the ARM and the scanout is slow per beat, and on the
// board that transport was what bounded VRAM DMA: Mega Man ZX's VBlank uploads
// (~10,000 writes) ran past the end of VBlank while its handler still held
// forced blank, and the top of every frame showed white.
//
// This stage folds consecutive writes before they reach the writer:
//   * writes to the same word merge their byte lanes (two 16-bit DMA units
//     become one 32-bit write), a later lane overwriting an earlier one;
//   * a full word followed by a write to the next word starts a pair, and a
//     pair whose second word is also full is emitted as one VramWritePair
//     record: {word1, word0, address, scanline tag, be=F, 32-bit, kind 11}.
// Anything else is emitted as an ordinary VramWrite, so the HPS applies the
// same final bytes in the same order. Only ARM9 writes with the same frame and
// the same scanline tag are combined, so a write can never move across a line
// the ARM renderer orders against. A held write is released ahead of any other
// record or boundary, at FRAME_END, and after LINGER_CYCLES without input.
module nds_h3d_vram_record_packer_core #(
    parameter integer LINGER_CYCLES = 16
) (
    input  logic         clk,
    input  logic         reset,

    input  logic         in_record_valid,
    output logic         in_record_ready,
    input  logic [127:0] in_record,
    input  logic [31:0]  in_record_frame,
    input  logic         in_record_frame_end,
    input  logic         in_boundary_valid,
    output logic         in_boundary_ready,
    input  logic [31:0]  in_boundary_frame,

    output logic         out_record_valid,
    input  logic         out_record_ready,
    output logic [127:0] out_record,
    output logic [31:0]  out_record_frame,
    output logic         out_record_frame_end,
    output logic         out_boundary_valid,
    input  logic         out_boundary_ready,
    output logic [31:0]  out_boundary_frame
);
    localparam logic [7:0] KIND_VRAM_WRITE = 8'd3;
    localparam logic [7:0] KIND_VRAM_PAIR = 8'd11;
    localparam logic [1:0] ACCESS_8 = 2'd0;
    localparam logic [1:0] ACCESS_16 = 2'd1;
    localparam logic [1:0] ACCESS_32 = 2'd2;

    function automatic logic [1:0] access_of(input logic [3:0] be);
        access_of = be == 4'hf ? ACCESS_32 :
            (be == 4'h3 || be == 4'hc) ? ACCESS_16 : ACCESS_8;
    endfunction

    function automatic logic [31:0] lanes(
        input logic [31:0] old_data, input logic [31:0] new_data,
        input logic [3:0] be);
        for (int j = 0; j < 4; j++)
            lanes[j*8 +: 8] = be[j] ? new_data[j*8 +: 8] : old_data[j*8 +: 8];
    endfunction

    // incoming record fields (see nds_h3d_frame_record_cdc pack_record)
    wire [7:0]  in_kind = in_record[7:0];
    wire [7:0]  in_tag  = in_record[15:8];
    wire [3:0]  in_be   = in_record[19:16];
    wire [11:0] in_hi   = in_record[31:20];   // scanline tag
    wire [31:0] in_addr = in_record[63:32];
    wire [31:0] in_data = in_record[95:64];
    wire in_candidate = in_kind == KIND_VRAM_WRITE && !in_tag[2] &&
        in_be != 0 && !in_record_frame_end && in_record[127:96] == 0;

    // held group
    logic        h_valid;
    logic        h_two;             // second word started
    logic [29:0] h_word;            // word address of word 0
    logic [31:0] h_d0, h_d1;
    logic [3:0]  h_be0, h_be1;
    logic [11:0] h_hi;
    logic [31:0] h_frame;
    logic [7:0]  h_linger;

    wire same_group = h_valid && in_record_frame == h_frame && in_hi == h_hi;
    wire merge_w0 = same_group && !h_two && in_addr[31:2] == h_word;
    wire start_w1 = same_group && !h_two && h_be0 == 4'hf &&
        in_addr[31:2] == h_word + 30'd1;
    wire merge_w1 = same_group && h_two && in_addr[31:2] == h_word + 30'd1;
    wire absorbs = in_record_valid && in_candidate &&
        (merge_w0 || start_w1 || merge_w1);
    wire pair_full = h_valid && h_two && h_be1 == 4'hf;
    wire emit = h_valid &&
        (pair_full || in_boundary_valid ||
         (in_record_valid && !absorbs) ||
         h_linger >= 8'(LINGER_CYCLES));
    wire emit_pair = h_two && h_be1 == 4'hf;

    always_comb begin
        in_record_ready = 1'b0;
        in_boundary_ready = 1'b0;
        out_record_valid = 1'b0;
        out_record = in_record;
        out_record_frame = in_record_frame;
        out_record_frame_end = in_record_frame_end;
        out_boundary_valid = 1'b0;
        out_boundary_frame = in_boundary_frame;

        if (emit) begin
            out_record_valid = 1'b1;
            out_record_frame = h_frame;
            out_record_frame_end = 1'b0;
            if (emit_pair)
                out_record = {h_d1, h_d0, h_word, 2'b00, h_hi, 4'hf,
                              6'd0, ACCESS_32, KIND_VRAM_PAIR};
            else
                out_record = {32'd0, h_d0, h_word, 2'b00, h_hi, h_be0,
                              6'd0, access_of(h_be0), KIND_VRAM_WRITE};
        end else if (h_valid) begin
            // absorbing, or waiting for more input
            in_record_ready = absorbs;
        end else if (in_record_valid && in_candidate) begin
            in_record_ready = 1'b1;              // captured below
        end else begin
            out_record_valid = in_record_valid;
            in_record_ready = out_record_ready;
            out_boundary_valid = in_boundary_valid;
            in_boundary_ready = out_boundary_ready;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            h_valid <= 1'b0;
            h_two <= 1'b0;
            h_linger <= '0;
        end else if (emit) begin
            if (out_record_ready) begin
                h_linger <= '0;
                if (h_two && !emit_pair) begin
                    // word 0 went out alone; word 1 is the new group
                    h_two <= 1'b0;
                    h_word <= h_word + 30'd1;
                    h_d0 <= h_d1;
                    h_be0 <= h_be1;
                end else begin
                    h_valid <= 1'b0;
                    h_two <= 1'b0;
                end
            end
        end else if (h_valid) begin
            if (absorbs) begin
                h_linger <= '0;
                if (merge_w0) begin
                    h_d0 <= lanes(h_d0, in_data, in_be);
                    h_be0 <= h_be0 | in_be;
                end else if (start_w1) begin
                    h_two <= 1'b1;
                    h_d1 <= in_data;
                    h_be1 <= in_be;
                end else begin
                    h_d1 <= lanes(h_d1, in_data, in_be);
                    h_be1 <= h_be1 | in_be;
                end
            end else if (h_linger != 8'hff) begin
                h_linger <= h_linger + 1'b1;
            end
        end else if (in_record_valid && in_candidate) begin
            h_valid <= 1'b1;
            h_two <= 1'b0;
            h_word <= in_addr[31:2];
            h_d0 <= in_data;
            h_be0 <= in_be;
            h_hi <= in_hi;
            h_frame <= in_record_frame;
            h_linger <= '0;
        end
    end
endmodule

// One-deep registered stage (with a skid entry) for the ordered record /
// boundary stream. Records and boundaries share the one stage, so their order
// is kept; every output and the ready are registers.
module nds_h3d_record_skid (
    input  logic         clk,
    input  logic         reset,
    input  logic         in_record_valid,
    output logic         in_record_ready,
    input  logic [127:0] in_record,
    input  logic [31:0]  in_record_frame,
    input  logic         in_record_frame_end,
    input  logic         in_boundary_valid,
    output logic         in_boundary_ready,
    input  logic [31:0]  in_boundary_frame,
    output logic         out_record_valid,
    input  logic         out_record_ready,
    output logic [127:0] out_record,
    output logic [31:0]  out_record_frame,
    output logic         out_record_frame_end,
    output logic         out_boundary_valid,
    input  logic         out_boundary_ready,
    output logic [31:0]  out_boundary_frame
);
    // {is_boundary, frame, frame_end, record}
    typedef logic [161:0] entry_t;
    entry_t main_q, skid_q;
    logic main_v, skid_v;

    wire in_valid = in_record_valid || in_boundary_valid;
    wire in_fire = in_valid && !skid_v;
    entry_t in_entry;
    assign in_entry = in_boundary_valid && !in_record_valid ?
        {1'b1, in_boundary_frame, 1'b0, 128'd0} :
        {1'b0, in_record_frame, in_record_frame_end, in_record};
    wire main_is_bnd = main_q[161];
    wire out_fire = main_v &&
        (main_is_bnd ? out_boundary_ready : out_record_ready);

    assign in_record_ready = !skid_v;
    assign in_boundary_ready = !skid_v && !in_record_valid;
    assign out_record_valid = main_v && !main_is_bnd;
    assign out_boundary_valid = main_v && main_is_bnd;
    assign out_record = main_q[127:0];
    assign out_record_frame = main_q[160:129];
    assign out_record_frame_end = main_q[128];
    assign out_boundary_frame = main_q[160:129];

    always_ff @(posedge clk) begin
        if (reset) begin
            main_v <= 1'b0;
            skid_v <= 1'b0;
        end else if (!main_v || out_fire) begin
            if (skid_v) begin
                main_q <= skid_q;
                main_v <= 1'b1;
                skid_v <= 1'b0;
            end else if (in_fire) begin
                main_q <= in_entry;
                main_v <= 1'b1;
            end else begin
                main_v <= 1'b0;
            end
        end else if (in_fire) begin
            skid_q <= in_entry;
            skid_v <= 1'b1;
        end
    end
endmodule

// Deep ordered FIFO for the same record / boundary stream, in block RAM.
//
// The DDR packet writer cannot always keep up with a VBlank burst of VRAM
// writes, and every record the mirror cannot take holds the DMA that made it.
// On Mega Man ZX's dialog frames that pushed the VBlank handler past the end
// of VBlank by a few lines, a start-of-frame interrupt then ran between its
// two DISPCNT stores, and the bottom screen showed forced-blank white for ten
// lines. The writer has the whole visible frame to catch up, so the burst only
// needs somewhere to wait. The packer instantiates it 4096 deep: the writer
// shares DDR with the MiSTer framebuffer, and with video rotation on that
// framebuffer takes enough bandwidth that 2048 was not always enough.
// Records and boundaries share the one queue, so their order is kept.
//
// The RAM read is registered (M10K), with one output register behind it: two
// cycles from an empty queue to the output, one entry per cycle after that.
// in_ready depends only on registers, and every output is a register.
module nds_h3d_record_fifo #(
    parameter integer LGDEPTH = 11
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         in_record_valid,
    output logic         in_record_ready,
    input  logic [127:0] in_record,
    input  logic [31:0]  in_record_frame,
    input  logic         in_record_frame_end,
    input  logic         in_boundary_valid,
    output logic         in_boundary_ready,
    input  logic [31:0]  in_boundary_frame,
    output logic         out_record_valid,
    input  logic         out_record_ready,
    output logic [127:0] out_record,
    output logic [31:0]  out_record_frame,
    output logic         out_record_frame_end,
    output logic         out_boundary_valid,
    input  logic         out_boundary_ready,
    output logic [31:0]  out_boundary_frame
);
    localparam integer DEPTH = 1 << LGDEPTH;
    // {is_boundary, frame, frame_end, record}
    typedef logic [161:0] entry_t;
    (* ramstyle = "M10K, no_rw_check" *) entry_t mem [0:DEPTH-1];

    logic [LGDEPTH:0] wptr, rptr;     // rptr: next entry to fetch from the RAM
    logic [LGDEPTH:0] wptr_n, rptr_n, stored_n;
    entry_t ram_q, out_q;
    logic ram_v, out_v;
    logic not_full;

    wire [LGDEPTH:0] stored = wptr - rptr;
    wire in_valid = in_record_valid || in_boundary_valid;
    wire in_fire = in_valid && not_full;
    entry_t in_entry;
    assign in_entry = in_boundary_valid && !in_record_valid ?
        {1'b1, in_boundary_frame, 1'b0, 128'd0} :
        {1'b0, in_record_frame, in_record_frame_end, in_record};

    wire out_is_bnd = out_q[161];
    wire out_fire = out_v && (out_is_bnd ? out_boundary_ready : out_record_ready);
    wire move = ram_v && (!out_v || out_fire);
    wire fetch = (stored != 0) && (!ram_v || move);

    assign in_record_ready = not_full;
    assign in_boundary_ready = not_full && !in_record_valid;
    assign out_record_valid = out_v && !out_is_bnd;
    assign out_boundary_valid = out_v && out_is_bnd;
    assign out_record = out_q[127:0];
    assign out_record_frame = out_q[160:129];
    assign out_record_frame_end = out_q[128];
    assign out_boundary_frame = out_q[160:129];

    always_comb begin
        wptr_n = wptr + (in_fire ? 1'b1 : 1'b0);
        rptr_n = rptr + (fetch ? 1'b1 : 1'b0);
        stored_n = wptr_n - rptr_n;
    end

    // RAM: plain write port, registered read that holds when not fetching
    always_ff @(posedge clk) begin
        if (in_fire)
            mem[wptr[LGDEPTH-1:0]] <= in_entry;
        if (fetch)
            ram_q <= mem[rptr[LGDEPTH-1:0]];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            wptr <= '0;
            rptr <= '0;
            ram_v <= 1'b0;
            out_v <= 1'b0;
            not_full <= 1'b1;
        end else begin
            wptr <= wptr_n;
            rptr <= rptr_n;
            // registered full flag, one slot in reserve for the entry that
            // may still arrive on the cycle it is being computed for
            not_full <= stored_n < (LGDEPTH+1)'(DEPTH - 1);
            if (move) begin
                out_q <= ram_q;
                out_v <= 1'b1;
            end else if (out_fire) begin
                out_v <= 1'b0;
            end
            if (fetch)
                ram_v <= 1'b1;
            else if (move)
                ram_v <= 1'b0;
        end
    end
endmodule

// The packer between two registered stages, so the CDC's FIFO read mux, the
// merge decision and the writer's acceptance logic are each timed on their
// own: chained combinationally they missed the 60 MHz DDR clock by 4.4 ns.
module nds_h3d_vram_record_packer #(
    parameter integer LINGER_CYCLES = 16,
    parameter integer FIFO_LGDEPTH = 12
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         in_record_valid,
    output logic         in_record_ready,
    input  logic [127:0] in_record,
    input  logic [31:0]  in_record_frame,
    input  logic         in_record_frame_end,
    input  logic         in_boundary_valid,
    output logic         in_boundary_ready,
    input  logic [31:0]  in_boundary_frame,
    output logic         out_record_valid,
    input  logic         out_record_ready,
    output logic [127:0] out_record,
    output logic [31:0]  out_record_frame,
    output logic         out_record_frame_end,
    output logic         out_boundary_valid,
    input  logic         out_boundary_ready,
    output logic [31:0]  out_boundary_frame
);
    logic a_rv, a_rr, a_fe, a_bv, a_br;
    logic [127:0] a_r;
    logic [31:0] a_rf, a_bf;
    logic b_rv, b_rr, b_fe, b_bv, b_br;
    logic [127:0] b_r;
    logic [31:0] b_rf, b_bf;

    nds_h3d_record_skid in_stage (
        .clk, .reset,
        .in_record_valid, .in_record_ready, .in_record,
        .in_record_frame, .in_record_frame_end,
        .in_boundary_valid, .in_boundary_ready, .in_boundary_frame,
        .out_record_valid(a_rv), .out_record_ready(a_rr), .out_record(a_r),
        .out_record_frame(a_rf), .out_record_frame_end(a_fe),
        .out_boundary_valid(a_bv), .out_boundary_ready(a_br),
        .out_boundary_frame(a_bf));

    nds_h3d_vram_record_packer_core #(.LINGER_CYCLES(LINGER_CYCLES)) core (
        .clk, .reset,
        .in_record_valid(a_rv), .in_record_ready(a_rr), .in_record(a_r),
        .in_record_frame(a_rf), .in_record_frame_end(a_fe),
        .in_boundary_valid(a_bv), .in_boundary_ready(a_br),
        .in_boundary_frame(a_bf),
        .out_record_valid(b_rv), .out_record_ready(b_rr), .out_record(b_r),
        .out_record_frame(b_rf), .out_record_frame_end(b_fe),
        .out_boundary_valid(b_bv), .out_boundary_ready(b_br),
        .out_boundary_frame(b_bf));

    // the registered output stage is also the queue the VBlank burst waits in
    nds_h3d_record_fifo #(.LGDEPTH(FIFO_LGDEPTH)) out_stage (
        .clk, .reset,
        .in_record_valid(b_rv), .in_record_ready(b_rr), .in_record(b_r),
        .in_record_frame(b_rf), .in_record_frame_end(b_fe),
        .in_boundary_valid(b_bv), .in_boundary_ready(b_br),
        .in_boundary_frame(b_bf),
        .out_record_valid, .out_record_ready, .out_record,
        .out_record_frame, .out_record_frame_end,
        .out_boundary_valid, .out_boundary_ready, .out_boundary_frame);
endmodule