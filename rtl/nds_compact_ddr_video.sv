module nds_compact_ddr_video #(
    parameter integer H_ACTIVE=512,H_FRONT=16,H_SYNC=48,H_TOTAL=640,
    parameter integer V_ACTIVE=192,V_FRONT=3,V_SYNC=6,V_TOTAL=261,
    parameter integer V_EXTRA_STEP=11379,
    parameter integer PIXEL_DIVIDE=6,
    parameter integer FRAME_WORDS=25088,FETCH_BURST_WORDS=128
)(
    input logic clk,input logic reset,input logic [28:0] control_addr,input logic [31:0] joystick,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,output logic ddram_we,output logic [63:0] ddram_din,
    output logic ce_pixel,output logic de,output logic hblank,output logic vblank,
    output logic hsync,output logic vsync,
    output logic [7:0] red,output logic [7:0] green,output logic [7:0] blue,
    output logic ready,output logic format_error,
    output logic signed [15:0] audio_l,output logic signed [15:0] audio_r,
    output logic [3:0] debug_progress
);
    typedef enum logic [1:0] {OWNER_IDLE,OWNER_HEADER,OWNER_FRAME,OWNER_INPUT} owner_t;
    owner_t owner;logic reset_n;logic [2:0] divider;logic [9:0] x;logic [8:0] y;
    logic [15:0] frame_phase;logic frame_extra;
    logic pub_start,pub_done,pub_valid,pub_compact,pub_rd;
    logic [7:0] pub_burst;logic [28:0] pub_addr,published_addr;logic [63:0] published_sequence;
    logic [10:0] published_audio_frames,fetch_audio_frames,active_audio_frames;
    logic fetch_start,fetch_done,fetch_rd,fetch_write;logic [7:0] fetch_burst;
    logic [28:0] fetch_addr;logic [14:0] fetch_write_addr;logic [63:0] fetch_write_data;
    logic active_bank,fetch_bank,pending_swap,initial_started;logic [63:0] fetch_sequence,loaded_sequence;
    logic store_read;logic [14:0] store_read_addr;logic [63:0] store_read_data;
    logic [15:0] pixel;logic [4:0] r5,g5,b5;
    logic [63:0] audio_bank0[0:511],audio_bank1[0:511];
    logic [63:0] audio_read_data;logic audio_half_read;
    logic [10:0] audio_index;logic [10:0] audio_divider;logic audio_pending,audio_bank_seen;
    logic audio_play_bank,audio_next_bank,audio_next_pending,audio_valid;
    logic [10:0] audio_play_frames,audio_next_frames;logic [8:0] audio_gap_ticks;
    logic [31:0] published_joystick;
    wire audio_request=(audio_divider==1249)&&audio_valid&&(audio_index<audio_play_frames);

    // Keep a valid raster running from reset.  MiSTer's scaler must be able to
    // lock before the first DDR frame arrives; gating CE_PIXEL with `ready`
    // leaves HDMI without a measurable mode when the ARM receiver is starting.
    assign reset_n=!reset;assign ce_pixel=(divider==PIXEL_DIVIDE-1);
    // DE must describe a complete active picture even before DDR contains the
    // first frame.  MiSTer's scaler uses DE to measure the source dimensions;
    // sync-only startup is rejected by some TVs as an unsupported mode.
    assign hblank=(x>=H_ACTIVE);
    assign vblank=(y>=V_ACTIVE);
    assign de=!hblank&&!vblank;
    assign hsync=!((x>=H_ACTIVE+H_FRONT)&&(x<H_ACTIVE+H_FRONT+H_SYNC));
    assign vsync=!((y>=V_ACTIVE+V_FRONT)&&(y<V_ACTIVE+V_FRONT+V_SYNC));
    assign store_read=ready&&(divider==0)&&(x<H_ACTIVE)&&(y<V_ACTIVE);
    assign store_read_addr=(y*H_ACTIVE+x)>>2;
    always_comb begin
        case(x[1:0])
            0:pixel=store_read_data[15:0];1:pixel=store_read_data[31:16];
            2:pixel=store_read_data[47:32];default:pixel=store_read_data[63:48];
        endcase
    end
    assign r5=pixel[4:0];assign g5=pixel[9:5];assign b5=pixel[14:10];
    assign red=(ready&&de)?{r5,r5[4:2]}:0;
    assign green=(ready&&de)?{g5,g5[4:2]}:0;
    assign blue=(ready&&de)?{b5,b5[4:2]}:0;
    assign ddram_burstcnt=owner==OWNER_HEADER?pub_burst:(owner==OWNER_INPUT?8'd1:fetch_burst);
    assign ddram_addr=owner==OWNER_HEADER?pub_addr:(owner==OWNER_INPUT?control_addr+29'd8:fetch_addr);
    assign ddram_rd=owner==OWNER_HEADER?pub_rd:(owner==OWNER_FRAME?fetch_rd:1'b0);
    // Like reads, writes must remain asserted while the arbiter reports busy.
    // Gating WE with busy delayed the pulse until after an expiring grant.
    assign ddram_we=owner==OWNER_INPUT;
    assign ddram_din={32'h4a53444e,joystick};

    nds_frame_publication_reader publication(
        .clk(clk),.reset_n(reset_n),.start(pub_start),.control_addr(control_addr),
        .busy(),.done(pub_done),.valid(pub_valid),.compact(pub_compact),.frame_addr(published_addr),
        .frame_sequence(published_sequence),.audio_frames(published_audio_frames),.ddram_burstcnt(pub_burst),.ddram_addr(pub_addr),
        .ddram_busy(ddram_busy),.ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready&&(owner==OWNER_HEADER)),.ddram_rd(pub_rd));
    nds_compact_frame_fetch #(.FRAME_WORDS(FRAME_WORDS),.BURST_WORDS(FETCH_BURST_WORDS)) fetch(
        .clk(clk),.reset_n(reset_n),.start(fetch_start),.base_addr(published_addr),.busy(),.done(fetch_done),
        .ddram_burstcnt(fetch_burst),.ddram_addr(fetch_addr),.ddram_busy(ddram_busy),
        .ddram_dout(ddram_dout),.ddram_dout_ready(ddram_dout_ready&&(owner==OWNER_FRAME)),.ddram_rd(fetch_rd),
        .write_enable(fetch_write),.write_addr(fetch_write_addr),.write_data(fetch_write_data));
    nds_compact_frame_store store(
        .clk(clk),.write_enable(fetch_write&&fetch_write_addr<24576),.write_bank(fetch_bank),.write_addr(fetch_write_addr),.write_data(fetch_write_data),
        .read_enable(store_read),.read_bank(active_bank),.read_addr(store_read_addr),.read_data(store_read_data));

    always_ff @(posedge clk)begin
        if(fetch_write&&fetch_write_addr>=24576)begin
            if(fetch_bank)audio_bank1[fetch_write_addr-24576]<=fetch_write_data;
            else audio_bank0[fetch_write_addr-24576]<=fetch_write_data;
        end
        if(audio_request)begin
            audio_read_data<=audio_play_bank?audio_bank1[audio_index[9:1]]:audio_bank0[audio_index[9:1]];
            audio_half_read<=audio_index[0];
        end
    end

    always_ff @(posedge clk)begin
        if(reset)begin audio_l<=0;audio_r<=0;audio_index<=0;audio_divider<=0;
            audio_pending<=0;audio_bank_seen<=0;audio_play_bank<=0;audio_next_bank<=0;
            audio_next_pending<=0;audio_valid<=0;audio_play_frames<=0;
            audio_next_frames<=0;audio_gap_ticks<=0;end
        else begin
            // Video publication and audio consumption run at nearly, but not
            // instantaneously, the same cadence. Queue the next audio bank and
            // drain the current block completely instead of truncating it at a
            // video swap. The 48 kHz divider remains free-running throughout.
            if(active_bank!=audio_bank_seen)begin
                audio_bank_seen<=active_bank;
                if(!audio_valid)begin
                    audio_play_bank<=active_bank;audio_play_frames<=active_audio_frames;
                    audio_index<=0;audio_valid<=1;audio_gap_ticks<=0;
                end else if(!audio_next_pending&&active_bank!=audio_play_bank)begin
                    audio_next_bank<=active_bank;audio_next_frames<=active_audio_frames;
                    audio_next_pending<=1;
                end
            end
            if(audio_pending)begin
                if(audio_half_read)begin audio_l<=audio_read_data[47:32];audio_r<=audio_read_data[63:48];end
                else begin audio_l<=audio_read_data[15:0];audio_r<=audio_read_data[31:16];end
                audio_pending<=0;audio_gap_ticks<=0;
            end
            if(audio_valid&&audio_index>=audio_play_frames&&audio_next_pending&&!audio_pending)begin
                audio_play_bank<=audio_next_bank;audio_play_frames<=audio_next_frames;
                audio_index<=0;audio_next_pending<=0;audio_gap_ticks<=0;
            end
            if(audio_divider==1249)begin
                audio_divider<=0;
                if(audio_valid&&audio_index<audio_play_frames)begin
                    audio_index<=audio_index+1'b1;audio_pending<=1;
                end else if(audio_gap_ticks<9'd479)audio_gap_ticks<=audio_gap_ticks+1'b1;
                else begin audio_l<=0;audio_r<=0;end
            end else audio_divider<=audio_divider+1'b1;
        end
    end

    always_ff @(posedge clk)begin
        if(reset)begin divider<=0;x<=0;y<=0;owner<=OWNER_IDLE;pub_start<=0;fetch_start<=0;
            active_bank<=0;fetch_bank<=1;pending_swap<=0;initial_started<=0;ready<=0;
            fetch_sequence<=0;loaded_sequence<=~64'd0;format_error<=0;
            fetch_audio_frames<=0;active_audio_frames<=0;
            published_joystick<=~32'd0;frame_phase<=0;frame_extra<=0;
            debug_progress<=0;
        end else begin
            pub_start<=0;fetch_start<=0;
            if(!initial_started)begin initial_started<=1;pub_start<=1;owner<=OWNER_HEADER;end
            if(pub_done)begin
                owner<=OWNER_IDLE;
                if(pub_valid&&pub_compact&&published_sequence!=loaded_sequence)begin
                    fetch_bank<=~active_bank;fetch_sequence<=published_sequence;fetch_audio_frames<=published_audio_frames;
                    fetch_start<=1;owner<=OWNER_FRAME;
                    debug_progress[1:0]<=2'b11;
                end else if(pub_valid&&!pub_compact)format_error<=1;
            end
            if(fetch_done)begin owner<=OWNER_IDLE;pending_swap<=1;debug_progress[2]<=1;end
            if(initial_started&&owner==OWNER_IDLE&&joystick!=published_joystick&&
                !(ready&&ce_pixel&&x==0&&y==V_ACTIVE))begin owner<=OWNER_INPUT;end
            if(owner==OWNER_INPUT&&!ddram_busy)begin
                published_joystick<=joystick;owner<=OWNER_IDLE;
                debug_progress[3]<=1;
            end
            if(ce_pixel)begin
                divider<=0;
                if(x==H_TOTAL-1)begin
                    x<=0;
                    if(y==V_TOTAL-1+frame_extra)begin
                        y<=0;
                        // 261 lines is slightly fast and 262 is slightly slow.
                        // Dither the extra line with a fixed-point accumulator so
                        // the long-term raster rate is 59.8261 Hz, matching DS.
                        if(frame_phase+V_EXTRA_STEP>=65536)begin
                            frame_phase<=frame_phase+V_EXTRA_STEP-65536;frame_extra<=1;
                        end else begin frame_phase<=frame_phase+V_EXTRA_STEP;frame_extra<=0;end
                        if(pending_swap)begin active_bank<=fetch_bank;active_audio_frames<=fetch_audio_frames;
                            loaded_sequence<=fetch_sequence;pending_swap<=0;ready<=1;end
                    end else y<=y+1'b1;
                end else x<=x+1'b1;
                if(ready&&x==0&&y==V_ACTIVE&&owner==OWNER_IDLE)begin pub_start<=1;owner<=OWNER_HEADER;end
            end else divider<=divider+1'b1;
        end
    end
endmodule
