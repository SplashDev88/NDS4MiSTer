`timescale 1ns/1ps

// Gray-pointer ready/valid asynchronous FIFO for fixed H3D event records.
// The payload RAM is written before its Gray pointer crosses to the read
// clock.  The read side exposes a first-word-fall-through entry only after two
// synchronizer stages.
module nds_h3d_event_async_fifo #(
    parameter integer WIDTH = 192,
    parameter integer LGDEPTH = 4
) (
    input  logic             write_clk,
    input  logic             write_reset,
    input  logic             write_valid,
    output logic             write_ready,
    input  logic [WIDTH-1:0] write_data,
    input  logic             read_clk,
    input  logic             read_reset,
    output logic             read_valid,
    input  logic             read_ready,
    output logic [WIDTH-1:0] read_data
);
    localparam integer DEPTH = 1 << LGDEPTH;
    logic [WIDTH-1:0] memory [0:DEPTH-1];
    logic [LGDEPTH:0] write_binary;
    logic [LGDEPTH:0] write_gray;
    logic [LGDEPTH:0] read_binary;
    logic [LGDEPTH:0] read_gray;
    (* async_reg = "true" *) logic [LGDEPTH:0] read_gray_write_meta;
    (* async_reg = "true" *) logic [LGDEPTH:0] read_gray_write_sync;
    (* async_reg = "true" *) logic [LGDEPTH:0] write_gray_read_meta;
    (* async_reg = "true" *) logic [LGDEPTH:0] write_gray_read_sync;

    wire write_fire = write_valid && write_ready;
    wire read_fire = read_valid && read_ready;
    wire [LGDEPTH:0] write_binary_next =
        write_binary + {{LGDEPTH{1'b0}}, write_fire};
    wire [LGDEPTH:0] read_binary_next =
        read_binary + {{LGDEPTH{1'b0}}, read_fire};
    wire [LGDEPTH:0] write_gray_next =
        (write_binary_next >> 1) ^ write_binary_next;
    wire [LGDEPTH:0] read_gray_next =
        (read_binary_next >> 1) ^ read_binary_next;
    wire fifo_full = write_gray == {
        ~read_gray_write_sync[LGDEPTH:LGDEPTH-1],
        read_gray_write_sync[LGDEPTH-2:0]
    };
    wire fifo_empty = read_gray == write_gray_read_sync;

    assign write_ready = !write_reset && !fifo_full;
    assign read_valid = !read_reset && !fifo_empty;
    assign read_data = memory[read_binary[LGDEPTH-1:0]];

    always_ff @(posedge write_clk or posedge write_reset) begin
        if (write_reset) begin
            write_binary <= '0;
            write_gray <= '0;
            read_gray_write_meta <= '0;
            read_gray_write_sync <= '0;
        end else begin
            read_gray_write_meta <= read_gray;
            read_gray_write_sync <= read_gray_write_meta;
            if (write_fire) begin
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
            write_gray_read_meta <= '0;
            write_gray_read_sync <= '0;
        end else begin
            write_gray_read_meta <= write_gray;
            write_gray_read_sync <= write_gray_read_meta;
            if (read_fire) begin
                read_binary <= read_binary_next;
                read_gray <= read_gray_next;
            end
        end
    end
endmodule
