// AXI-3 slave for the HPS lightweight HPS-to-FPGA bridge.
//
// The lightweight bridge appears to the ARM at physical 0xFF200000 and is the
// low-latency path for register access: a single ARM load or store completes in
// roughly a hundred nanoseconds without touching DDR, where the existing DDR
// mailbox costs a write burst, a poll loop, and contention with the video
// fetcher through the shared DDRAM arbiter.
//
// The HPS is always the master here, so the FPGA can only ever be polled -- it
// cannot push a request across this bridge. The mailbox on top of this slave is
// therefore structured as "HPS reads a pending flag, reads the request, writes
// the response".
//
// Only single-beat transfers are implemented, which is all an ARM load/store
// generates through this bridge (awlen/arlen are 0). Bursts are still answered
// correctly for the len==0 case by asserting rlast on the single data beat.
// Port directions below are from the *fabric* side: signals the bridge
// primitive drives out to us are inputs here.
module nds_hps_lw_slave (
    input  logic        clk,
    input  logic        reset,

    // AXI-3 write address channel
    input  logic [11:0] awid,
    input  logic [20:0] awaddr,
    input  logic        awvalid,
    output logic        awready,
    // AXI-3 write data channel
    input  logic [31:0] wdata,
    input  logic [3:0]  wstrb,
    input  logic        wvalid,
    output logic        wready,
    // AXI-3 write response channel
    output logic [11:0] bid,
    output logic [1:0]  bresp,
    output logic        bvalid,
    input  logic        bready,
    // AXI-3 read address channel
    input  logic [11:0] arid,
    input  logic [20:0] araddr,
    input  logic        arvalid,
    output logic        arready,
    // AXI-3 read data channel
    output logic [11:0] rid,
    output logic [31:0] rdata,
    output logic [1:0]  rresp,
    output logic        rlast,
    output logic        rvalid,
    input  logic        rready,

    // Register-file side. Reads are combinational on reg_raddr.
    output logic [18:0] reg_raddr,
    input  logic [31:0] reg_rdata,
    output logic [18:0] reg_waddr,
    output logic [31:0] reg_wdata,
    output logic [3:0]  reg_be,
    output logic        reg_write
);
    // OKAY on every response: this slave has no error cases, and returning
    // SLVERR for an unmapped offset would surface as a bus error on the ARM
    // rather than anything the responder could act on.
    localparam logic [1:0] RESP_OKAY = 2'b00;

    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
    typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_t;
    wstate_t wstate;
    rstate_t rstate;

    logic [11:0] awid_held;
    logic [18:0] awaddr_held;

    // Word-addressed: the low two bits of a byte address select bytes within
    // the word and are carried by wstrb instead.
    assign reg_raddr = araddr[20:2];
    assign reg_waddr = awaddr_held;
    assign bresp = RESP_OKAY;
    assign rresp = RESP_OKAY;
    // Every accepted transfer is single-beat, so the first data beat is last.
    assign rlast = 1'b1;

    always_ff @(posedge clk) begin
        if (reset) begin
            wstate <= W_IDLE;
            rstate <= R_IDLE;
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0;
            arready <= 1'b0; rvalid <= 1'b0;
            reg_write <= 1'b0; reg_wdata <= 32'h0; reg_be <= 4'h0;
            awid_held <= 12'h0; awaddr_held <= 19'h0;
            bid <= 12'h0; rid <= 12'h0; rdata <= 32'h0;
        end else begin
            reg_write <= 1'b0;

            // ---- write channel ----
            case (wstate)
                W_IDLE: begin
                    bvalid <= 1'b0;
                    if (awvalid && !awready) begin
                        awid_held <= awid;
                        awaddr_held <= awaddr[20:2];
                        awready <= 1'b1;
                        wstate <= W_DATA;
                    end
                end
                W_DATA: begin
                    awready <= 1'b0;
                    if (wvalid && !wready) begin
                        reg_wdata <= wdata;
                        reg_be <= wstrb;
                        reg_write <= 1'b1;
                        wready <= 1'b1;
                        wstate <= W_RESP;
                    end
                end
                W_RESP: begin
                    wready <= 1'b0;
                    bid <= awid_held;
                    bvalid <= 1'b1;
                    if (bvalid && bready) begin
                        bvalid <= 1'b0;
                        wstate <= W_IDLE;
                    end
                end
                default: wstate <= W_IDLE;
            endcase

            // ---- read channel ----
            case (rstate)
                R_IDLE: begin
                    rvalid <= 1'b0;
                    if (arvalid && !arready) begin
                        rid <= arid;
                        // reg_rdata is combinational on araddr, so capture it
                        // in the same cycle the address is accepted.
                        rdata <= reg_rdata;
                        arready <= 1'b1;
                        rstate <= R_DATA;
                    end
                end
                R_DATA: begin
                    arready <= 1'b0;
                    rvalid <= 1'b1;
                    if (rvalid && rready) begin
                        rvalid <= 1'b0;
                        rstate <= R_IDLE;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end
endmodule
