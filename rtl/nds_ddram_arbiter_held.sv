// Candidate queued MiSTer DDR arbiter for r34 validation. Tests may alias it
// to the production name; it is not referenced by the active r33 QSF.
`ifdef DDRAM_ARBITER_HELD_PRODUCTION_NAME
module nds_ddram_arbiter (
`else
module nds_ddram_arbiter_held (
`endif
    input  logic        clk,
    input  logic        reset,

    input  logic        a_rd,
    input  logic        a_we,
    input  logic [7:0]  a_burstcnt,
    input  logic [28:0] a_addr,
    input  logic [63:0] a_din,
    input  logic [7:0]  a_be,
    output logic        a_busy,
    output logic [63:0] a_dout,
    output logic        a_dout_ready,
    output logic        a_command_accepted,

    input  logic        b_rd,
    input  logic        b_we,
    input  logic [7:0]  b_burstcnt,
    input  logic [28:0] b_addr,
    input  logic [63:0] b_din,
    input  logic [7:0]  b_be,
    output logic        b_busy,
    output logic [63:0] b_dout,
    output logic        b_dout_ready,
    output logic        b_command_accepted,
    output logic [17:0] debug_state,

    output logic        ddram_rd,
    output logic        ddram_we,
    output logic [7:0]  ddram_burstcnt,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready
);
    logic selected_b;
    logic grant_dwell;

    logic command_pending;
    logic command_owner_b;
    logic command_read;
    logic command_write;
    logic [7:0] command_burst;
    logic [28:0] command_addr;
    logic [63:0] command_din;
    logic [7:0] command_be;

    logic read_pending;
    logic read_owner_b;
    logic [7:0] beats_remaining;

    wire selected_rd = selected_b ? b_rd : a_rd;
    wire selected_we = selected_b ? b_we : a_we;
    wire selected_request = selected_rd || selected_we;

    always_comb begin
        // A client is accepted into the one-entry command queue on the edge
        // where it is selected and observes busy low. Once queued, both
        // clients remain stalled until the external command is accepted.
        a_busy = read_pending || command_pending || selected_b || ddram_busy;
        b_busy = read_pending || command_pending || !selected_b || ddram_busy;

        // Avalon-style request signals and payload remain stable for the
        // entire waitrequest interval.
        ddram_rd = command_pending && command_read;
        ddram_we = command_pending && command_write;
        ddram_burstcnt = command_burst;
        ddram_addr = command_addr;
        ddram_din = command_din;
        ddram_be = command_be;

        a_dout = ddram_dout;
        b_dout = ddram_dout;
        a_dout_ready = ddram_dout_ready && read_pending && !read_owner_b;
        b_dout_ready = ddram_dout_ready && read_pending && read_owner_b;
        a_command_accepted =
            command_pending && !ddram_busy && !command_owner_b;
        b_command_accepted =
            command_pending && !ddram_busy && command_owner_b;
        debug_state = {
            beats_remaining,
            ddram_busy,
            ddram_dout_ready,
            selected_b,
            grant_dwell,
            command_pending,
            command_owner_b,
            command_read,
            command_write,
            read_pending,
            read_owner_b
        };
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            selected_b <= 1'b0;
            grant_dwell <= 1'b1;
            command_pending <= 1'b0;
            command_owner_b <= 1'b0;
            command_read <= 1'b0;
            command_write <= 1'b0;
            command_burst <= 8'd1;
            command_addr <= 29'd0;
            command_din <= 64'd0;
            command_be <= 8'hff;
            read_pending <= 1'b0;
            read_owner_b <= 1'b0;
            beats_remaining <= 8'd0;
        end else begin
            if (command_pending) begin
                if (!ddram_busy) begin
                    command_pending <= 1'b0;
                    if (command_read) begin
                        read_pending <= 1'b1;
                        read_owner_b <= command_owner_b;
                        beats_remaining <= command_burst == 0
                            ? 8'd1 : command_burst;
                    end else begin
                        selected_b <= ~command_owner_b;
                        grant_dwell <= 1'b1;
                    end
                end
            end else if (read_pending) begin
                if (ddram_dout_ready) begin
                    if (beats_remaining <= 1) begin
                        read_pending <= 1'b0;
                        beats_remaining <= 0;
                        selected_b <= ~read_owner_b;
                        grant_dwell <= 1'b1;
                    end else begin
                        beats_remaining <= beats_remaining - 1'b1;
                    end
                end
            end else if (selected_request) begin
                command_pending <= 1'b1;
                command_owner_b <= selected_b;
                command_read <= selected_rd;
                command_write <= selected_we && !selected_rd;
                command_burst <= selected_b ? b_burstcnt : a_burstcnt;
                command_addr <= selected_b ? b_addr : a_addr;
                command_din <= selected_b ? b_din : a_din;
                command_be <= selected_b ? b_be : a_be;
                grant_dwell <= 1'b0;
            end else if (grant_dwell) begin
                grant_dwell <= 1'b0;
            end else begin
                selected_b <= ~selected_b;
                grant_dwell <= 1'b1;
            end
        end
    end
endmodule
