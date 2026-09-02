module nds_ddr_video #(
    parameter integer H_ACTIVE=512,H_FRONT=16,H_SYNC=48,H_TOTAL=640,
    parameter integer V_ACTIVE=192,V_FRONT=3,V_SYNC=6,V_TOTAL=260,
    parameter integer PIXEL_DIVIDE=6,AUDIO_DIVIDE=1250,
    parameter integer LAYER_RECORDS_PER_BURST=16,
    parameter bit VIDEO_DEBUG_INPUT_TELEMETRY=0,
    // The sticky debug flags only say a fault ever happened, so they cannot
    // tell an ongoing starvation apart from one transient event at startup.
    // These counters are per-frame and non-sticky: each completed frame
    // latches its own underrun and tag-error totals and the next frame starts
    // from zero, which makes "is the raster still starving, and how badly"
    // directly measurable from the published word.
    parameter bit VIDEO_DEBUG_FRAME_COUNTERS=0
) (
    input logic clk,input logic reset,input logic [28:0] base_addr,
    input logic published,input logic [28:0] control_addr,input logic [31:0] joystick,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,output logic ddram_we,output logic [63:0] ddram_din,
    output logic ce_pixel,output logic de,output logic hsync,output logic vsync,
    output logic [7:0] red,output logic [7:0] green,output logic [7:0] blue,
    output logic underrun,output logic tag_error,
    output logic signed [15:0] audio_l,output logic signed [15:0] audio_r,
    output logic display_ready
);
    logic reset_n;logic [3:0] divider;logic [9:0] x;logic [8:0] y;
    logic cache_start,cache_busy,frame_fetched,acquire,acquire_ready,line_acquired;
    logic acquire_bank,read_enable,read_bank,read_valid,release_valid,release_bank;
    logic [1:0] bank_free;logic [8:0] read_addr;logic [31:0] acquire_sequence,fetch_sequence,display_sequence;
    logic [319:0] read_data;logic pixel_valid,pixel_ready;logic [18:0] pixel_tag;logic [31:0] raw_pixel;logic [7:0] pixel_r,pixel_g,pixel_b;
    logic initial_started,display_started,pixel_pending;
    logic [8:0] acquire_line;
    logic read_priming;
    typedef enum logic [2:0] {DDR_IDLE,DDR_HEADER,DDR_FRAME,DDR_AUDIO,DDR_INPUT} ddr_owner_t;
    ddr_owner_t ddr_owner;
    logic pub_start,pub_busy,pub_done,pub_valid,pub_compact,pub_rd,cache_rd;
    logic audio_start,audio_done,audio_rd,audio_activate,audio_fetch_bank,audio_active_bank;
    logic audio_overflow;
    logic [10:0] published_audio_frames,audio_fetch_frames;
    logic [7:0] pub_burst,cache_burst,audio_burst;
    logic [28:0] pub_addr,cache_addr,audio_addr,published_frame_addr,active_base_addr;
    logic [63:0] published_frame_sequence;
    logic [31:0] published_joystick;
    logic debug_frame_response,debug_read_valid,debug_read_nonzero;
    logic debug_pixel_valid,debug_pixel_nonzero,debug_active_pending;
    logic debug_active_nonzero,debug_tag_match;
    // Per-frame, non-sticky fault counters. Both saturate rather than wrap so
    // a heavily starved frame cannot read back as a healthy one.
    logic [7:0] underrun_running,tag_error_running;
    logic [7:0] underrun_frame,tag_error_frame;
    wire frame_last_pixel=(x==H_TOTAL-1)&&(y==V_TOTAL-1);
    // Marker 0xe distinguishes this from the 0xd sticky-flag layout. The low
    // twelve bits stay the live joystick: the HPS consumes them as input.
    //
    // A zero fault count is ambiguous on its own -- it reads the same whether
    // the raster is healthy or has never started a frame at all. Publish
    // display_started and a rolling per-frame tick alongside the counts so the
    // two cases are distinguishable: if the tick advances between reads the
    // raster is genuinely running.
    logic [2:0] frame_tick;
    // r229: display_started never latches, so publish the exact inputs to that
    // decision. Both set sites need BOTH banks full (!bank_free[1]) and the
    // first also needs acquire_ready, which additionally demands an exact
    // sequence match. These bits separate "the cache never filled the banks"
    // from "the banks filled but the sequence never matched".
    logic ever_acquire_ready,ever_pub_valid,ever_frame_fetched;
    // r230: the published word is only written while ddr_owner==DDR_IDLE, so a
    // stuck FSM freezes its own telemetry and every field read back is stale.
    // Break that with a watchdog. No legitimate DDR operation here takes
    // anywhere near 2^21 cycles (~35 ms at 60 MHz), so a non-IDLE owner that
    // survives that long is wedged: return it to IDLE, record which state it
    // was stuck in, and count the recoveries. The raster free-runs once
    // display_started is set, so a released owner sees the next vblank and
    // re-issues pub_start -> cache_start, refilling the banks on its own.
    localparam integer OWNER_STALL_LIMIT = 21;
    logic [OWNER_STALL_LIMIT:0] owner_stall_count;
    logic [2:0] stuck_owner;
    logic [7:0] owner_recoveries;
    logic owner_recovered;
    wire owner_stalled=owner_stall_count[OWNER_STALL_LIMIT];
    // r232: the DDR_AUDIO wedge is fixed (recoveries stay 0), but the picture
    // still strobes, now much faster. That is the signature of per-frame
    // starvation rather than a stuck FSM, so bring the underrun and tag-error
    // counts back alongside a single bit saying whether the watchdog ever had
    // to fire. frame_tick proves the raster is still completing frames.
    // r233: the raster reports zero underruns yet the picture strobes, so
    // measure the publication handshake instead of guessing. An invalid
    // publication makes the FSM retry the header and skip cache_start
    // entirely, so count rejected headers per frame and record whether the
    // frame got a refill at all. Widths are exact: 4+6+6+3+1+12 = 32.
    logic [5:0] pub_invalid_running,pub_invalid_frame;
    logic cache_started_running,cache_started_frame;
    // r234: fetch, refill and tags all measure perfect, so the question is no
    // longer whether pixels arrive but whether they are BLACK. Count non-black
    // active pixels per frame, saturating at 4095. A frame with real picture
    // saturates almost immediately (98304 active pixels); a blanked frame
    // reads 0. Alternating 0 / 4095 means the FPGA is faithfully displaying
    // black frames and the fault is in the published content. All frames
    // saturating means the FPGA always drives picture and the strobe is
    // downstream of this module, in the top-level mux or HDMI timing.
    logic [11:0] nonzero_running,nonzero_frame;
    // r239: the non-black counter above saturates at 4095 -- only 4.2% of a
    // 98304-pixel frame -- so a frame that is 95% black still reads
    // "saturated" and looks healthy. That flaw is why every frame appeared
    // fine while the screen strobed. Count the pixels actually forced black
    // instead (de asserted but pixel_pending low), with range to cover a
    // whole frame. Published as a count of 4-pixel units so 98304 fits in 16.
    logic [17:0] black_running,black_frame;
    // r240: the published word is only rewritten when the payload CHANGES
    // (see the input_payload!=published_joystick gate below). r239 published
    // only the blank count and the idle joystick, so once both settled the
    // word stopped updating and every read returned the same stale value --
    // which reads as a healthy zero whether frames are perfect or entirely
    // black. Keep frame_tick in the payload so a fresh write is forced every
    // frame, and so a tick that advances between reads proves the word is
    // live rather than stale. Blank count is in 32-pixel units: a whole
    // 98304-pixel frame is 3072, which fits in 13 bits.
    // Widths: 4+13+3+12 = 32.
    wire [31:0] frame_counter_payload=
        {4'h5,black_frame[17:5],frame_tick,joystick[11:0]};
    wire [31:0] input_payload=VIDEO_DEBUG_FRAME_COUNTERS ?
        frame_counter_payload :
        VIDEO_DEBUG_INPUT_TELEMETRY ?
        {4'hd,display_started,underrun,tag_error,debug_frame_response,
         debug_read_valid,debug_read_nonzero,debug_pixel_valid,
         debug_pixel_nonzero,debug_active_pending,debug_active_nonzero,
         debug_tag_match,5'd0,joystick[11:0]} : joystick;

    assign reset_n=!reset;
    assign display_ready=display_started;
    assign ce_pixel=divider==PIXEL_DIVIDE-1;
    assign de=(x<H_ACTIVE)&&(y<V_ACTIVE);
    assign hsync=!((x>=H_ACTIVE+H_FRONT)&&(x<H_ACTIVE+H_FRONT+H_SYNC));
    assign vsync=!((y>=V_ACTIVE+V_FRONT)&&(y<V_ACTIVE+V_FRONT+V_SYNC));
    assign red=de&&pixel_pending ? pixel_r : 0;
    assign green=de&&pixel_pending ? pixel_g : 0;
    assign blue=de&&pixel_pending ? pixel_b : 0;
    assign ddram_burstcnt=ddr_owner==DDR_HEADER?pub_burst:
                          ddr_owner==DDR_AUDIO?audio_burst:
                          ddr_owner==DDR_INPUT?8'd1:cache_burst;
    assign ddram_addr=ddr_owner==DDR_HEADER?pub_addr:
                      ddr_owner==DDR_AUDIO?audio_addr:
                      ddr_owner==DDR_INPUT?control_addr+29'd8:cache_addr;
    assign ddram_rd=ddr_owner==DDR_HEADER?pub_rd:
                    ddr_owner==DDR_FRAME?cache_rd:
                    ddr_owner==DDR_AUDIO?audio_rd:1'b0;
    assign ddram_we=ddr_owner==DDR_INPUT&&!ddram_busy;
    assign ddram_din={32'h4a53444e,input_payload};

    // Release a line at the end of active pixels, then acquire the following
    // line during horizontal blank. Waiting until x=0 makes the first pixel
    // race the synchronous acquire handshake under realistic DDR stalls.
    assign acquire_line=y>=V_ACTIVE?9'd0:
                        (x>=H_ACTIVE&&y<V_ACTIVE-1)?y+1'b1:y;
    assign acquire=!line_acquired&&
                   ((y<V_ACTIVE&&(x<H_ACTIVE||y<V_ACTIVE-1))||y>=V_ACTIVE);
    assign acquire_bank=acquire_line[0];
    // Before the first raster starts there is no displayed sequence yet.
    // Acquire the lines belonging to the first fetched publication directly;
    // a live HPS publisher normally starts at a non-zero frame sequence.
    // Requiring reset-valued display_sequence here leaves both full banks
    // permanently unacquirable and keeps the video output black.
    assign acquire_sequence=(!display_started||y>=V_ACTIVE?
                            fetch_sequence:display_sequence)+acquire_line;
    // Prime pixel zero before a line becomes visible, then launch each
    // following synchronous RAM read on the preceding CE edge. The complete
    // RAM/unpack/compositor pipeline otherwise reaches pixel N on the same
    // edge that consumes it, which is one hardware cycle too late.
    assign read_priming=!display_started||x>=H_ACTIVE||y>=V_ACTIVE;
    assign read_enable=line_acquired&&
        ((read_priming&&divider==0&&!pixel_pending&&!pixel_valid&&pixel_ready)||
         (!read_priming&&x<H_ACTIVE-1&&divider==PIXEL_DIVIDE-1&&pixel_ready));
    assign read_bank=read_priming?acquire_line[0]:y[0];
    assign read_addr=read_priming?9'd0:x[8:0]+1'b1;
    assign release_valid=ce_pixel&&line_acquired&&(y<V_ACTIVE)&&(x==H_ACTIVE-1);
    assign release_bank=y[0];

    nds_ddr_line_cache #(
        .LINE_PIXELS(H_ACTIVE),.FRAME_LINES(V_ACTIVE),
        .RECORDS_PER_BURST(LAYER_RECORDS_PER_BURST)) cache(
        .clk(clk),.reset_n(reset_n),.start(cache_start),.base_addr(active_base_addr),
        .sequence_base(fetch_sequence),.busy(cache_busy),.frame_fetched(frame_fetched),
        .ddram_burstcnt(cache_burst),.ddram_addr(cache_addr),.ddram_busy(ddram_busy),
        .ddram_dout(ddram_dout),.ddram_dout_ready(ddram_dout_ready&&(ddr_owner==DDR_FRAME)),.ddram_rd(cache_rd),
        .acquire(acquire),.acquire_bank(acquire_bank),.acquire_sequence(acquire_sequence),
        .acquire_ready(acquire_ready),.read_enable(read_enable),.read_bank(read_bank),
        .read_addr(read_addr),.read_valid(read_valid),.read_data(read_data),
        .release_valid(release_valid),.release_bank(release_bank),.bank_free(bank_free)
    );
    nds_frame_publication_reader publication(
        .clk(clk),.reset_n(reset_n),.start(pub_start),.control_addr(control_addr),
        .busy(pub_busy),.done(pub_done),.valid(pub_valid),.compact(pub_compact),.frame_addr(published_frame_addr),
        .frame_sequence(published_frame_sequence),.audio_frames(published_audio_frames),
        .ddram_burstcnt(pub_burst),.ddram_addr(pub_addr),
        .ddram_busy(ddram_busy),.ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready&&(ddr_owner==DDR_HEADER)),.ddram_rd(pub_rd)
    );
    nds_ddr_audio_block #(.AUDIO_DIVIDE(AUDIO_DIVIDE)) audio(
        .clk(clk),.reset_n(reset_n),.start(audio_start),
        .base_addr(active_base_addr+29'h78000),.fetch_bank(audio_fetch_bank),
        .fetch_frames(audio_fetch_frames),.busy(),.done(audio_done),
        .ddram_burstcnt(audio_burst),.ddram_addr(audio_addr),
        .ddram_busy(ddram_busy),.ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready&&(ddr_owner==DDR_AUDIO)),
        .ddram_rd(audio_rd),.activate(audio_activate),
        .activate_bank(audio_fetch_bank),.activate_frames(audio_fetch_frames),
        .audio_l(audio_l),.audio_r(audio_r),.queue_overflow(audio_overflow));
    nds_layer_record_stream records(
        .clk(clk),.reset_n(reset_n),.in_valid(read_valid),.in_ready(pixel_ready),
        .in_record(read_data),.out_valid(pixel_valid),.out_ready(1'b1),
        .out_tag(pixel_tag),.out_pixel(raw_pixel),.out_r(pixel_r),.out_g(pixel_g),.out_b(pixel_b)
    );

    always_ff @(posedge clk) begin
        if(reset)begin
            divider<=0;x<=0;y<=0;cache_start<=0;pub_start<=0;fetch_sequence<=0;display_sequence<=0;
            line_acquired<=0;initial_started<=0;display_started<=0;pixel_pending<=0;underrun<=0;tag_error<=0;
            ddr_owner<=DDR_IDLE;active_base_addr<=base_addr;audio_start<=0;audio_activate<=0;
            audio_fetch_bank<=1;audio_active_bank<=0;audio_fetch_frames<=0;
            published_joystick<=~32'd0;
            debug_frame_response<=0;debug_read_valid<=0;
            debug_read_nonzero<=0;debug_pixel_valid<=0;
            debug_pixel_nonzero<=0;debug_active_pending<=0;
            debug_active_nonzero<=0;debug_tag_match<=0;
            underrun_running<=0;tag_error_running<=0;
            underrun_frame<=0;tag_error_frame<=0;frame_tick<=0;
            ever_acquire_ready<=0;ever_pub_valid<=0;ever_frame_fetched<=0;
            owner_stall_count<=0;stuck_owner<=0;owner_recoveries<=0;
            owner_recovered<=0;
            pub_invalid_running<=0;pub_invalid_frame<=0;
            cache_started_running<=0;cache_started_frame<=0;
            nonzero_running<=0;nonzero_frame<=0;
            black_running<=0;black_frame<=0;
        end else begin
            cache_start<=0;pub_start<=0;audio_start<=0;audio_activate<=0;
            if(!initial_started)begin
                initial_started<=1;
                if(published)begin pub_start<=1;ddr_owner<=DDR_HEADER;end
                else begin active_base_addr<=base_addr;cache_start<=1;ddr_owner<=DDR_FRAME;end
            end
            // The line store holds two lines; one cache_start streams exactly
            // one frame of V_ACTIVE lines and then returns to idle. The raster
            // therefore needs a refill every displayed frame, not only when
            // the HPS publishes a new one. Gating this on a changed
            // publication sequence starves the store at every frame the HPS
            // did not publish, which blanks the raster.
            if(pub_done)begin
                ddr_owner<=DDR_IDLE;
                if(pub_valid)begin
                    active_base_addr<=published_frame_addr;
                    fetch_sequence<=published_frame_sequence[31:0]*V_ACTIVE;
                    audio_fetch_bank<=~audio_active_bank;
                    audio_fetch_frames<=published_audio_frames;
                    cache_start<=1;ddr_owner<=DDR_FRAME;
                end else if(ever_pub_valid)begin
                    // r241: the header was caught mid-update -- the publisher
                    // marks the generation odd for the ~6.15 ms it spends
                    // memcpying 3.9 MB, so any vblank landing in that window
                    // sees an invalid publication. Retrying the header alone
                    // skipped cache_start entirely, leaving the line store
                    // empty for the whole frame and rendering it 100% black.
                    // Measured on hardware as whole frames blanking at the
                    // publication rate, which is the flashing.
                    //
                    // Keep active_base_addr, fetch_sequence and the audio
                    // fields at their last valid values and refill anyway, so
                    // the raster simply redisplays the previous frame. The
                    // sequence tags still match because display_sequence
                    // tracks the unchanged fetch_sequence.
                    cache_start<=1;ddr_owner<=DDR_FRAME;
                end else begin
                    // There is no previous frame to redisplay yet.  Treating
                    // the reset-time control address as a frame base feeds the
                    // publication header into the pixel pipeline.  Retry until
                    // the first complete publication is visible; only then is
                    // the r241 previous-frame fallback meaningful.
                    pub_start<=1;ddr_owner<=DDR_HEADER;
                end
            end
            if(frame_fetched)begin
                if(published&&audio_fetch_frames!=0)begin audio_start<=1;ddr_owner<=DDR_AUDIO;end
                else ddr_owner<=DDR_IDLE;
            end
            if(audio_done)begin
                audio_active_bank<=audio_fetch_bank;audio_activate<=1;ddr_owner<=DDR_IDLE;
            end
            // Any owner change or completion is progress; only an owner that
            // sits non-IDLE with no progress at all trips the watchdog.
            if(ddr_owner==DDR_IDLE||pub_done||frame_fetched||audio_done)
                owner_stall_count<=0;
            else if(!owner_stalled)
                owner_stall_count<=owner_stall_count+1'b1;
            if(pub_done&&!pub_valid&&pub_invalid_running!=6'h3f)
                pub_invalid_running<=pub_invalid_running+1'b1;
            if(cache_start)cache_started_running<=1;
            if(acquire_ready)ever_acquire_ready<=1;
            if(pub_done&&pub_valid)ever_pub_valid<=1;
            if(frame_fetched)ever_frame_fetched<=1;
            if(audio_overflow)underrun<=1;
            if(ddram_dout_ready&&ddr_owner==DDR_FRAME)debug_frame_response<=1;
            if(read_valid)begin
                debug_read_valid<=1;
                if(|read_data)debug_read_nonzero<=1;
            end
            if(pixel_valid)begin
                debug_pixel_valid<=1;
                if(|{pixel_r,pixel_g,pixel_b})debug_pixel_nonzero<=1;
                if(pixel_tag=={y,x})debug_tag_match<=1;
            end
            if(ce_pixel&&de&&pixel_pending)begin
                debug_active_pending<=1;
                if(|{pixel_r,pixel_g,pixel_b})debug_active_nonzero<=1;
            end
            if(display_started&&published&&ddr_owner==DDR_IDLE&&input_payload!=published_joystick&&
               !(ce_pixel&&x==0&&y==V_ACTIVE))ddr_owner<=DDR_INPUT;
            if(ddr_owner==DDR_INPUT&&!ddram_busy)begin
                published_joystick<=input_payload;ddr_owner<=DDR_IDLE;
            end
            if(owner_stalled)begin
                if(!owner_recovered)begin
                    owner_recovered<=1;
                    stuck_owner<=ddr_owner;
                end
                if(owner_recoveries!=8'hff)
                    owner_recoveries<=owner_recoveries+1'b1;
                owner_stall_count<=0;
                ddr_owner<=DDR_IDLE;
            end
            // Begin the raster only after both initial line banks are full.
            // This gives the streaming cache one complete line of elasticity
            // instead of making line 1 race the first visible scanline.
            if(acquire_ready)begin
                line_acquired<=1;
                if(y==0&&!bank_free[1])begin
                    display_started<=1;
                    display_sequence<=fetch_sequence;
                end
            end
            if(!display_started&&y==0&&line_acquired&&!bank_free[1])begin
                display_started<=1;
                display_sequence<=fetch_sequence;
            end
            if(release_valid)line_acquired<=0;
            if(pixel_valid)pixel_pending<=1;
            if(!display_started)divider<=0;
            else if(ce_pixel)begin
                if(de&&(!line_acquired||(!pixel_pending&&!pixel_valid)))begin
                    underrun<=1;
                    if(underrun_running!=8'hff)
                        underrun_running<=underrun_running+1'b1;
                end
                if(de&&!pixel_pending&&black_running!=18'h3ffff)
                    black_running<=black_running+1'b1;
                if(de&&pixel_pending&&|{pixel_r,pixel_g,pixel_b}&&
                   nonzero_running!=12'hfff)
                    nonzero_running<=nonzero_running+1'b1;
                if(de&&pixel_pending&&(pixel_tag!={y,x}))begin
                    tag_error<=1;
                    if(tag_error_running!=8'hff)
                        tag_error_running<=tag_error_running+1'b1;
                end
                // Latch this frame's totals and restart the counters. The
                // increments above are on the same clock edge, so a fault on
                // the final pixel is carried into the next frame rather than
                // dropped.
                if(frame_last_pixel)begin
                    underrun_frame<=underrun_running;
                    tag_error_frame<=tag_error_running;
                    underrun_running<=0;tag_error_running<=0;
                    frame_tick<=frame_tick+1'b1;
                    pub_invalid_frame<=pub_invalid_running;
                    pub_invalid_running<=0;
                    cache_started_frame<=cache_started_running;
                    cache_started_running<=0;
                    nonzero_frame<=nonzero_running;
                    nonzero_running<=0;
                    black_frame<=black_running;
                    black_running<=0;
                end
                if(de)pixel_pending<=0;
                divider<=0;
                if(x==H_TOTAL-1)begin
                    x<=0;
                    if(y==V_TOTAL-1)begin y<=0;display_sequence<=fetch_sequence;end
                    else y<=y+1'b1;
                end else x<=x+1'b1;
                if(x==0&&y==V_ACTIVE)begin
                    if(published)begin
                        if(ddr_owner==DDR_IDLE)begin pub_start<=1;ddr_owner<=DDR_HEADER;end
                    end else begin
                        fetch_sequence<=fetch_sequence+V_ACTIVE;
                        active_base_addr<=base_addr;cache_start<=1;ddr_owner<=DDR_FRAME;
                    end
                end
            end else divider<=divider+1'b1;
        end
    end
endmodule
