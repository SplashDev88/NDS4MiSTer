module nds_frame_publication_reader (
    input logic clk,input logic reset_n,input logic start,input logic [28:0] control_addr,
    output logic busy,output logic done,output logic valid,output logic compact,
    output logic [28:0] frame_addr,output logic [63:0] frame_sequence,output logic [10:0] audio_frames,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd
);
    localparam logic [63:0] MAGIC=64'h315542504c53444e;
    typedef enum logic [1:0] {IDLE,ISSUE,RECEIVE,VALIDATE} state_t;
    state_t state;logic [2:0] beat;logic [511:0] header;
    logic [63:0] generation,generation_check;
    logic [31:0] slot;

    assign busy=state!=IDLE;
    assign ddram_burstcnt=8;
    assign ddram_addr=control_addr;
    // Present the request throughout ISSUE. The shared arbiter may grant this
    // client on any cycle; registering a one-cycle pulse only after observing
    // busy low lets the arbiter rotate away before that pulse becomes visible.
    assign ddram_rd=state==ISSUE;
    assign generation=header[191:128];
    assign slot=header[223:192];
    assign generation_check=header[447:384];

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin state<=IDLE;done<=0;valid<=0;compact<=0;beat<=0;header<=0;frame_addr<=0;frame_sequence<=0;audio_frames<=0;end
        else begin
            done<=0;
            case(state)
                IDLE: if(start)begin valid<=0;compact<=0;state<=ISSUE;end
                ISSUE: if(!ddram_busy)begin beat<=0;state<=RECEIVE;end
                RECEIVE: if(ddram_dout_ready)begin
                    header[beat*64 +: 64]<=ddram_dout;
                    if(beat==7)state<=VALIDATE;else beat<=beat+1'b1;
                end
                VALIDATE: begin
                    valid<=header[63:0]==MAGIC&&(header[95:64]==1||header[95:64]==2)&&header[127:96]==64&&
                        generation==generation_check&&!generation[0]&&slot<2&&
                        ((header[95:64]==1&&header[255:224]==32'd3932160&&header[287:256]==40&&header[319:288]==98304)||
                         (header[95:64]==2&&header[255:224]==32'd196608&&header[287:256]==2&&header[319:288]==98304));
                    compact<=header[95:64]==2;
                    if(header[63:0]==MAGIC&&(header[95:64]==1||header[95:64]==2)&&header[127:96]==64&&
                        generation==generation_check&&!generation[0]&&slot<2&&
                        ((header[95:64]==1&&header[255:224]==32'd3932160&&header[287:256]==40&&header[319:288]==98304)||
                         (header[95:64]==2&&header[255:224]==32'd196608&&header[287:256]==2&&header[319:288]==98304)))begin
                        frame_addr<=control_addr+(slot+1)*29'h80000;
                        frame_sequence<=header[383:320];
                        audio_frames<=header[479:448]>1024?11'd1024:header[458:448];
                    end
                    done<=1;state<=IDLE;
                end
            endcase
        end
    end
endmodule
