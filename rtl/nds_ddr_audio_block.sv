module nds_ddr_audio_block #(
    parameter integer AUDIO_DIVIDE=1250,
    parameter integer MAX_FRAMES=1024
) (
    input  logic clk,input logic reset_n,
    input  logic start,input logic [28:0] base_addr,
    input  logic fetch_bank,input logic [10:0] fetch_frames,
    output logic busy,output logic done,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input  logic ddram_busy,input logic [63:0] ddram_dout,
    input  logic ddram_dout_ready,output logic ddram_rd,
    input  logic activate,input logic activate_bank,
    input  logic [10:0] activate_frames,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic queue_overflow
);
    localparam integer MAX_WORDS=(MAX_FRAMES+1)/2;
    typedef enum logic [1:0] {IDLE,ISSUE,RECEIVE} fetch_state_t;
    fetch_state_t state;
    logic active_fetch_bank;
    logic [9:0] word_index,words_remaining,receive_index;
    logic [7:0] burst_words;
    logic [63:0] bank0[0:MAX_WORDS-1],bank1[0:MAX_WORDS-1];

    logic [63:0] audio_read_data;
    logic audio_half_read,audio_pending;
    logic play_bank,next_bank,next_pending,audio_valid;
    logic [10:0] play_frames,next_frames,audio_index;
    logic [$clog2(AUDIO_DIVIDE)-1:0] audio_divider;
    wire audio_tick=audio_divider==AUDIO_DIVIDE-1;
    wire audio_request=audio_tick&&audio_valid&&(audio_index<play_frames);

    assign busy=state!=IDLE;
    assign ddram_addr=base_addr+word_index;
    assign ddram_burstcnt=burst_words;

    always_comb begin
        if(words_remaining>128)burst_words=8'd128;
        else burst_words=words_remaining[7:0];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            state<=IDLE;done<=0;ddram_rd<=0;active_fetch_bank<=0;
            word_index<=0;words_remaining<=0;receive_index<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: begin
                    ddram_rd<=0;
                    if(start)begin
                        active_fetch_bank<=fetch_bank;word_index<=0;
                        words_remaining<=(fetch_frames+1'b1)>>1;
                        if(fetch_frames==0)done<=1;
                        else begin ddram_rd<=1;state<=ISSUE;end
                    end
                end
                // Hold the read command asserted until the controller actually
                // accepts it. The old code sampled !ddram_busy and only then
                // registered ddram_rd, so the command reached the port a cycle
                // later -- by which time another DDR client may have taken it.
                // That command is simply lost, no data ever returns, and
                // RECEIVE waits forever. The stalled DDR_AUDIO owner then
                // wedges the whole video FSM, which is the black screen.
                ISSUE: if(!ddram_busy)begin
                    ddram_rd<=0;
                    // A legal DDR endpoint may return beat zero on the command
                    // acceptance edge.  Consume it here instead of entering
                    // RECEIVE one beat late and waiting forever for an extra
                    // response that will never arrive.
                    if(ddram_dout_ready)begin
                        if(active_fetch_bank)bank1[word_index]<=ddram_dout;
                        else bank0[word_index]<=ddram_dout;
                        if(burst_words==1)begin
                            word_index<=word_index+1'b1;
                            words_remaining<=words_remaining-1'b1;
                            done<=1;state<=IDLE;
                        end else begin
                            receive_index<=1;state<=RECEIVE;
                        end
                    end else begin
                        receive_index<=0;state<=RECEIVE;
                    end
                end
                RECEIVE: if(ddram_dout_ready)begin
                    if(active_fetch_bank)bank1[word_index+receive_index]<=ddram_dout;
                    else bank0[word_index+receive_index]<=ddram_dout;
                    if(receive_index==burst_words-1'b1)begin
                        word_index<=word_index+burst_words;
                        words_remaining<=words_remaining-burst_words;
                        if(words_remaining==burst_words)begin done<=1;state<=IDLE;end
                        else begin ddram_rd<=1;state<=ISSUE;end
                    end else receive_index<=receive_index+1'b1;
                end
                default:begin state<=IDLE;ddram_rd<=0;end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if(audio_request)begin
            audio_read_data<=play_bank?bank1[audio_index[10:1]]:
                                       bank0[audio_index[10:1]];
            audio_half_read<=audio_index[0];
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            audio_l<=0;audio_r<=0;audio_index<=0;audio_divider<=0;
            audio_pending<=0;play_bank<=0;next_bank<=0;next_pending<=0;
            audio_valid<=0;play_frames<=0;next_frames<=0;queue_overflow<=0;
        end else begin
            if(activate)begin
                if(!audio_valid||
                   (audio_index>=play_frames&&!audio_pending))begin
                    play_bank<=activate_bank;play_frames<=activate_frames;
                    audio_index<=0;audio_valid<=activate_frames!=0;
                    next_pending<=0;
                end else if(!next_pending&&activate_bank!=play_bank)begin
                    next_bank<=activate_bank;next_frames<=activate_frames;
                    next_pending<=activate_frames!=0;
                end else if(activate_frames!=0)queue_overflow<=1;
            end
            if(audio_pending)begin
                if(audio_half_read)begin
                    audio_l<=audio_read_data[47:32];
                    audio_r<=audio_read_data[63:48];
                end else begin
                    audio_l<=audio_read_data[15:0];
                    audio_r<=audio_read_data[31:16];
                end
                audio_pending<=0;
            end
            if(audio_valid&&audio_index>=play_frames&&
               next_pending&&!audio_pending)begin
                play_bank<=next_bank;play_frames<=next_frames;
                audio_index<=0;next_pending<=0;
            end
            if(audio_tick)begin
                audio_divider<=0;
                if(audio_valid&&audio_index<play_frames)begin
                    audio_index<=audio_index+1'b1;audio_pending<=1;
                end else if(!next_pending&&
                            !(activate&&activate_frames!=0))begin
                    audio_valid<=0;audio_l<=0;audio_r<=0;
                end
            end else audio_divider<=audio_divider+1'b1;
        end
    end
endmodule
