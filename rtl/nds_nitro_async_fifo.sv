// SPDX-License-Identifier: GPL-3.0-or-later
// Small dual-clock FIFO used only at the retained-shell/Nitro-island boundary.
// Gray pointers keep the console pixel stream independent of the 60 MHz shell
// DDR clock without making either side part of the other's timing cone.
module nds_nitro_async_fifo #(
    parameter integer WIDTH = 70,
    parameter integer LGDEPTH = 4
) (
    input  logic                 write_clk,
    input  logic                 write_reset,
    input  logic                 write_enable,
    input  logic [WIDTH-1:0]     write_data,
    output logic                 write_full,
    output logic                 write_overflow,
    input  logic                 read_clk,
    input  logic                 read_reset,
    input  logic                 read_enable,
    output logic [WIDTH-1:0]     read_data,
    output logic                 read_valid,
    output logic                 read_empty
);
    localparam integer DEPTH = 1 << LGDEPTH;
    logic [WIDTH-1:0] memory [0:DEPTH-1];
    logic [LGDEPTH:0] write_binary, write_gray;
    logic [LGDEPTH:0] read_binary, read_gray;
    (* async_reg = "true" *) logic [LGDEPTH:0] read_gray_w1, read_gray_w2;
    (* async_reg = "true" *) logic [LGDEPTH:0] write_gray_r1, write_gray_r2;

    wire [LGDEPTH:0] write_binary_next = write_binary +
        ((write_enable && !write_full) ? 1'b1 : 1'b0);
    wire [LGDEPTH:0] write_gray_next =
        (write_binary_next >> 1) ^ write_binary_next;
    wire [LGDEPTH:0] read_binary_next = read_binary +
        ((read_enable && !read_empty) ? 1'b1 : 1'b0);
    wire [LGDEPTH:0] read_gray_next =
        (read_binary_next >> 1) ^ read_binary_next;

    wire write_full_next = write_gray_next ==
        {~read_gray_w2[LGDEPTH:LGDEPTH-1],
         read_gray_w2[LGDEPTH-2:0]};
    always_comb read_empty = read_gray == write_gray_r2;

    always_ff @(posedge write_clk or posedge write_reset) begin
        if (write_reset) begin
            write_binary <= '0;
            write_gray <= '0;
            write_full <= 1'b0;
            read_gray_w1 <= '0;
            read_gray_w2 <= '0;
            write_overflow <= 1'b0;
        end else begin
            read_gray_w1 <= read_gray;
            read_gray_w2 <= read_gray_w1;
            write_full <= write_full_next;
            // Sticky in the producing domain.  A one-cycle pulse is not a
            // valid CDC event when the retained DDR clock samples it.
            if (write_enable && write_full) write_overflow <= 1'b1;
            if (write_enable && !write_full) begin
                memory[write_binary[LGDEPTH-1:0]] <= write_data;
                write_binary <= write_binary_next;
                write_gray <= write_gray_next;
            end
        end
    end

    always_ff @(posedge read_clk or posedge read_reset) begin
        if (read_reset) begin
            read_binary <= '0;
            read_gray <= '0;
            write_gray_r1 <= '0;
            write_gray_r2 <= '0;
            read_data <= '0;
            read_valid <= 1'b0;
        end else begin
            write_gray_r1 <= write_gray;
            write_gray_r2 <= write_gray_r1;
            read_valid <= 1'b0;
            if (read_enable && !read_empty) begin
                read_data <= memory[read_binary[LGDEPTH-1:0]];
                read_binary <= read_binary_next;
                read_gray <= read_gray_next;
                read_valid <= 1'b1;
            end
        end
    end
endmodule
