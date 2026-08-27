module nds_arm7_bios_rom (
    input  logic        request,
    input  logic [31:0] address,
    input  logic [1:0]  access,
    output logic [31:0] read_data,
    output logic        done
);
    logic [31:0] words [0:4095];
    logic [31:0] selected;

    initial begin
`include "nds_arm7_bios_init.svh"
    end

    always_comb begin
        selected = words[address[13:2]];
        case (access)
            2'b00: read_data = (selected >> (address[1:0] * 8)) &
                                32'h000000ff;
            2'b01: read_data = (selected >> (address[1] * 16)) &
                                32'h0000ffff;
            default: read_data = selected;
        endcase
        done = request;
    end
endmodule
