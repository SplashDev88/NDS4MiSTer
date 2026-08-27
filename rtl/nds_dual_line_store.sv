module nds_line_ram (
    input logic clk,input logic write_enable,input logic [8:0] write_addr,
    input logic [319:0] write_data,input logic read_enable,input logic [8:0] read_addr,
    output logic [319:0] read_data
);
    logic [319:0] memory[0:511];
    always_ff @(posedge clk)begin
        if(write_enable)memory[write_addr]<=write_data;
        if(read_enable)read_data<=memory[read_addr];
    end
endmodule

module nds_dual_line_store (
    input logic clk,input logic reset_n,
    output logic [1:0] bank_free,
    input logic write_valid,output logic write_ready,input logic write_bank,
    input logic [8:0] write_addr,input logic [319:0] write_data,
    input logic publish,input logic publish_bank,input logic [31:0] publish_sequence,
    input logic acquire,input logic acquire_bank,input logic [31:0] acquire_sequence,
    output logic acquire_ready,
    input logic read_enable,input logic read_bank,input logic [8:0] read_addr,
    output logic read_valid,output logic [319:0] read_data,
    input logic release_valid,input logic release_bank
);
    logic [319:0] bank0_data,bank1_data;
    logic read_bank_delayed;
    logic [1:0] ready;
    logic [31:0] sequence0,sequence1;

    assign bank_free=~ready;
    assign write_ready=!ready[write_bank];
    assign acquire_ready=acquire&&ready[acquire_bank]&&
        (acquire_bank ? sequence1 : sequence0)==acquire_sequence;
    assign read_data=read_bank_delayed ? bank1_data : bank0_data;

    nds_line_ram bank0(
        .clk(clk),.write_enable(write_valid&&write_ready&&!write_bank),
        .write_addr(write_addr),.write_data(write_data),
        .read_enable(read_enable&&!read_bank),.read_addr(read_addr),.read_data(bank0_data)
    );
    nds_line_ram bank1(
        .clk(clk),.write_enable(write_valid&&write_ready&&write_bank),
        .write_addr(write_addr),.write_data(write_data),
        .read_enable(read_enable&&read_bank),.read_addr(read_addr),.read_data(bank1_data)
    );

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin ready<=0;sequence0<=0;sequence1<=0;read_valid<=0;read_bank_delayed<=0;end
        else begin
            read_valid<=read_enable;
            if(read_enable)read_bank_delayed<=read_bank;
            if(release_valid)ready[release_bank]<=0;
            if(publish)begin
                ready[publish_bank]<=1;
                if(publish_bank)sequence1<=publish_sequence;else sequence0<=publish_sequence;
            end
        end
    end
endmodule
