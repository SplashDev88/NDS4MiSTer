module nds_cpu_tcm #(
    parameter integer ADDRESS_BITS = 15
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        seed_valid,
    input  logic [31:0] seed_data,
    input  logic        request,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        done
);
    localparam integer WORDS = 1 << (ADDRESS_BITS - 2);
    localparam integer INDEX_BITS = ADDRESS_BITS - 2;

    // Keep each byte lane in its own synchronous RAM.  The previous
    // read/modify/write array inferred a registered M10K read port but
    // asserted done on the request edge.  RTL simulation treated that read
    // as combinational, so it could not reproduce the stale-word behavior
    // seen on Cyclone V hardware.  Independent lanes also avoid feeding an
    // old M10K read value back into the untouched bytes of a partial write.
    (* ramstyle = "M10K" *) logic [7:0] memory0 [0:WORDS-1];
    (* ramstyle = "M10K" *) logic [7:0] memory1 [0:WORDS-1];
    (* ramstyle = "M10K" *) logic [7:0] memory2 [0:WORDS-1];
    (* ramstyle = "M10K" *) logic [7:0] memory3 [0:WORDS-1];

    logic active;
    logic response_pending;
    logic response_read;
    logic [1:0] response_access;
    logic [1:0] response_lane;
    logic [31:0] ram_read_data;
    wire [INDEX_BITS-1:0] request_index =
        address[ADDRESS_BITS-1:2];

    always_ff @(posedge clk) begin
        // This is deliberately a synchronous read.  request_index is stable
        // throughout the accepted request, and the response is produced on
        // the following clock after these four registered lane values are
        // valid.
        ram_read_data[7:0]   <= memory0[request_index];
        ram_read_data[15:8]  <= memory1[request_index];
        ram_read_data[23:16] <= memory2[request_index];
        ram_read_data[31:24] <= memory3[request_index];

        if (reset) begin
            active <= 0;
            response_pending <= 0;
            response_read <= 0;
            response_access <= 0;
            response_lane <= 0;
            done <= 0;
            read_data <= 0;
            if (seed_valid) begin
                memory0[WORDS-1] <= seed_data[7:0];
                memory1[WORDS-1] <= seed_data[15:8];
                memory2[WORDS-1] <= seed_data[23:16];
                memory3[WORDS-1] <= seed_data[31:24];
            end
        end else begin
            done <= 0;
            if (!active && request) begin
                active <= 1;
                response_pending <= 1;
                response_read <= read_not_write;
                response_access <= access;
                response_lane <= address[1:0];
                if (!read_not_write) begin
                    case (access)
                        2'b00: begin
                            case (address[1:0])
                                0: memory0[request_index] <= write_data[7:0];
                                1: memory1[request_index] <= write_data[7:0];
                                2: memory2[request_index] <= write_data[7:0];
                                3: memory3[request_index] <= write_data[7:0];
                            endcase
                        end
                        2'b01: if (address[1]) begin
                            memory2[request_index] <= write_data[7:0];
                            memory3[request_index] <= write_data[15:8];
                        end else begin
                            memory0[request_index] <= write_data[7:0];
                            memory1[request_index] <= write_data[15:8];
                        end
                        default: begin
                            memory0[request_index] <= write_data[7:0];
                            memory1[request_index] <= write_data[15:8];
                            memory2[request_index] <= write_data[23:16];
                            memory3[request_index] <= write_data[31:24];
                        end
                    endcase
                end
            end else if (active && response_pending) begin
                if (response_read) begin
                    case (response_access)
                        2'b00: begin
                            case (response_lane)
                                0: read_data <= {24'd0, ram_read_data[7:0]};
                                1: read_data <= {24'd0, ram_read_data[15:8]};
                                2: read_data <= {24'd0, ram_read_data[23:16]};
                                3: read_data <= {24'd0, ram_read_data[31:24]};
                            endcase
                        end
                        2'b01: if (response_lane[1])
                            read_data <= {16'd0, ram_read_data[31:16]};
                        else
                            read_data <= {16'd0, ram_read_data[15:0]};
                        default: read_data <= ram_read_data;
                    endcase
                end
                done <= 1;
                response_pending <= 0;
            end else if (active && !request) begin
                active <= 0;
            end
        end
    end
endmodule
