module nds_compact_frame_fetch #(
    parameter integer FRAME_WORDS=24576,
    parameter integer BURST_WORDS=128
)(
    input logic clk,input logic reset_n,input logic start,input logic [28:0] base_addr,
    output logic busy,output logic done,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,
    output logic write_enable,output logic [14:0] write_addr,output logic [63:0] write_data
);
    typedef enum logic [1:0] {IDLE,ISSUE,RECEIVE} state_t;
    state_t state;logic [7:0] burst_index;logic [14:0] word_index;
    assign busy=state!=IDLE;
    assign ddram_burstcnt=BURST_WORDS;
    // Hold the command visible until the shared arbiter grants and accepts it.
    assign ddram_rd=state==ISSUE;
    always_ff @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin state<=IDLE;done<=0;ddram_addr<=0;
            write_enable<=0;write_addr<=0;write_data<=0;burst_index<=0;word_index<=0;end
        else begin
            done<=0;write_enable<=0;
            case(state)
                IDLE:if(start)begin ddram_addr<=base_addr;word_index<=0;state<=ISSUE;end
                ISSUE:if(!ddram_busy)begin burst_index<=0;state<=RECEIVE;end
                RECEIVE:if(ddram_dout_ready)begin
                    write_enable<=1;write_addr<=word_index;write_data<=ddram_dout;
                    word_index<=word_index+1'b1;
                    if(burst_index==BURST_WORDS-1)begin
                        if(word_index==FRAME_WORDS-1)begin done<=1;state<=IDLE;end
                        else begin ddram_addr<=ddram_addr+BURST_WORDS;state<=ISSUE;end
                    end else burst_index<=burst_index+1'b1;
                end
            endcase
        end
    end
endmodule

module nds_compact_frame_store(
    input logic clk,input logic write_enable,input logic write_bank,
    input logic [14:0] write_addr,input logic [63:0] write_data,
    input logic read_enable,input logic read_bank,input logic [14:0] read_addr,
    output logic [63:0] read_data
);
    logic [63:0] bank0[0:24575];logic [63:0] bank1[0:24575];
    logic [63:0] bank0_read,bank1_read;logic read_bank_delayed;
    always_ff @(posedge clk)begin
        if(write_enable&&!write_bank)bank0[write_addr]<=write_data;
        if(write_enable&&write_bank)bank1[write_addr]<=write_data;
        if(read_enable)begin
            bank0_read<=bank0[read_addr];bank1_read<=bank1[read_addr];read_bank_delayed<=read_bank;
        end
    end
    assign read_data=read_bank_delayed?bank1_read:bank0_read;
endmodule
