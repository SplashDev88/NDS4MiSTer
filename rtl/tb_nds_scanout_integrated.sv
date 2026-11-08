// SPDX-License-Identifier: GPL-3.0-or-later
// Real dual-output scanout, line cache, legacy DDR controller and H3D fabric.
// Saturated cartridge misses and accelerator reads must not repeat stale rows.
`timescale 1ns/1ps
module tb_nds_scanout_integrated #(parameter MATCHED=1, PRIORITY=1, OUTER_PRIORITY=1, EVENTS=1);
    localparam [27:1] FB_BASE=27'h7f00000, EXT_BASE=27'h7ec0000;
    reg clk=0, dclk=0;
    always #5 clk=~clk;
    always #3 dclk=~dclk;
    reg reset=1, session_reset=1;
    reg [1:0] layout=2, gap=0;
    reg order=0, analog_screen=1, split=1;
    reg external_enable=1, touch_pressed=0;
    reg published=0, external_toggle=0, external_screen=1;
    reg [1:0] normal_bank=0, external_bank=1;
    wire split_frame_toggle;
    wire split_active, analog_active, pf_tgl,pf_scr,pf_bank,pf_external,pf_slot,pf_ticket;
    wire [7:0] pf_line;
    wire [1:0] pf_frame_bank;
    wire [3:0] pf_completed,lb_acquire,lb_hold,lb_selected_slot;
    wire [8:0] lb_raddr;
    wire [35:0] lb_q;
    wire lb_valid,ce,de,hs,vs,ace,ade,ahs,avs;
    wire [7:0] r,g,b,ar,ag,ab;
    wire [27:1] read_addr;
    wire read_req;
    wire [63:0] read_data;
    wire read_valid,read_ready;

    nds_nitro_video_scanout dut (
        .clk_video(clk),.reset,.session_reset,.layout_select(layout),
        .screen_order_select(order),.gap_select(gap),.fps_select(1'b0),.crt_select(1'b1),
        .split_select(split),.analog_screen_select(analog_screen),
        .split_active,.analog_screen_active(analog_active),.crt_active(),
        .touch_pressed,.touch_x(8'd128),.touch_y(8'd96),
        .layout_active(),.screen_order_active(),.gap_active(),.fps_active(),
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,.pf_slot,.pf_ticket,.split_frame_toggle,
        .pf_completed,.lb_acquire,.lb_hold,.lb_selected_slot,
        .published_frame_toggle(published),.published_frame_bank(normal_bank),
        .external_screen_toggle(external_toggle),.external_screen_bank(external_bank),
        .external_screen_select(external_screen),.external_screen_adopted_toggle(),
        .external_enable,.external_quiescent(),.effective_3d_frame_toggle(1'b0),
        .lb_raddr,.lb_q,.lb_valid,.ce_pixel(ce),.de,.hsync(hs),.vsync(vs),
        .red(r),.green(g),.blue(b),.analog_ce(ace),.analog_de(ade),
        .analog_hs(ahs),.analog_vs(avs),.analog_r(ar),.analog_g(ag),.analog_b(ab)
    );
    nds_nitro_fb_ddr3 #(.FB_HW_BASE(FB_BASE),.ENGINE_B_HW_BASE(EXT_BASE),
                           .FB_BURST(128),.RUNTIME_TELEMETRY(0)) fb (
        .clk_sys(dclk),.CLK_VIDEO(clk),.reset_sys(session_reset),.reset_video(reset),
        .reset_read(reset),.external_enable,.external_quiescent(),
        .pix_x(8'd0),.pix_y(8'd0),.pix_d(18'd0),.pix_we(1'b0),
        .pixb_x(8'd0),.pixb_y(8'd0),.pixb_d(18'd0),.pixb_we(1'b0),
        .source_fault(1'b0),.telemetry_session(32'd0),
        .external_frame_mode(MATCHED!=0),.external_frame_publish(1'b0),
        .external_frame_bank(2'd0),.external_frame_adopted(),
        .dbg0(18'd0),.dbg1(18'd0),.dbg2(18'd0),.dbg3(18'd0),
        .dbg4(18'd0),.dbg5(18'd0),.dbg6(18'd0),.dbg7(18'd0),
        .dbg8(18'd0),.dbg9(18'd0),.dbg10(18'd0),.dbg11(18'd0),
        .pf_tgl,.pf_scr,.pf_line,.pf_bank,.pf_frame_bank,.pf_external,
        .split_mode(split_active),.pf_slot,.pf_ticket,.split_frame_toggle,.pf_completed,
        .lb_acquire,.lb_hold,.lb_selected_slot,.lb_raddr,.lb_q,.lb_valid,
        .published_frame_toggle(),.published_frame_bank(),.scanout_late_count(),
        .runtime_fault_flags(),.bank_diagnostic(),
        .fb5_addr(),.fb5_din(),.fb5_req(),.fb5_next(1'b0),.fb5_ready(1'b0),
        .fb6_addr(read_addr),.fb6_req(read_req),.fb6_dout(read_data),
        .fb6_valid(read_valid),.fb6_ready(read_ready)
    );

    function automatic [17:0] pixel(input integer x,y,scr,bank,ext);
        pixel={ext[0],bank[0],scr[0],y[7:6],1'b1,y[5:0],x[5:0]};
    endfunction
    function automatic [23:0] rgb(input [17:0] p);
        rgb={p[5:0],p[5:4],p[11:6],p[11:10],p[17:12],p[17:16]};
    endfunction
    reg cart_req=0; wire scan_req=read_req;
    reg [27:1] cart_addr=0; wire [27:1] scan_addr=read_addr;
    wire cart_ready, scan_ready, scan_valid;
    wire scan_pending;
    wire [31:0] cart_data;
    wire [63:0] scan_data;
    wire legacy_rd,legacy_we,legacy_busy,legacy_valid;
    wire [7:0] legacy_burst,legacy_be;
    wire [28:0] legacy_addr;
    wire [63:0] legacy_din,legacy_dout;
    ddram #(.CART_WIDE_BANK(1),.SCANOUT_READ_PRIORITY(PRIORITY)) legacy (
        .DDRAM_CLK(dclk),.DDRAM_BUSY(legacy_busy),.DDRAM_BURSTCNT(legacy_burst),
        .DDRAM_ADDR(legacy_addr),.DDRAM_DOUT(legacy_dout),
        .DDRAM_DOUT_READY(legacy_valid),.DDRAM_RD(legacy_rd),
        .DDRAM_DIN(legacy_din),.DDRAM_BE(legacy_be),.DDRAM_WE(legacy_we),
        .ch1_addr(27'd0),.ch1_req(1'b0),.ch1_rnw(1'b1),.ch1_din(16'd0),
        .ch1_dout(),.ch1_ready(),
        .ch2_addr(cart_addr),.ch2_altbank(1'b0),.ch2_req(cart_req),
        .ch2_rnw(1'b1),.ch2_din(32'd0),.ch2_dout(cart_data),.ch2_ready(cart_ready),
        .ch3_addr(27'd0),.ch3_req(1'b0),.ch3_rnw(1'b1),.ch3_be(8'd0),
        .ch3_din(64'd0),.ch3_dout(),.ch3_ready(),.ch3_burst(8'd1),.ch3_valid(),
        .ch4_addr(27'd0),.ch4_req(1'b0),.ch4_rnw(1'b1),.ch4_be(8'd0),
        .ch4_din(64'd0),.ch4_dout(),.ch4_ready(),
        .ch5_addr(27'd0),.ch5_req(1'b0),.ch5_burst(8'd128),
        .ch5_din(64'd0),.ch5_next(),.ch5_ready(),
        .ch6_addr(scan_addr),.ch6_req(scan_req),.ch6_burst(8'd128),
        .ch6_dout(scan_data),.ch6_valid(scan_valid),.ch6_ready(scan_ready),
        .ch6_pending(scan_pending)
    );
    reg accelerator_pending=1, accelerator_receiving=0;
    wire accelerator_busy,accelerator_valid;
    wire [63:0] accelerator_data;
    integer accelerator_beat=0,accelerator_completed=0;
    reg event_pending=1, event_stream=0;
    wire event_busy, event_accepted;
    integer event_completed=0, event_beat=0, event_words=0;
    wire [63:0] event_data=64'(event_completed*8+event_beat);

    wire rd,wr,protocol_error;
    wire [7:0] burst,be;
    wire [28:0] addr;
    wire [63:0] din;
    reg busy=1,valid=0;
    reg [63:0] dout=0;
    nds_h3d_ddr_fabric fabric (
        .clk(dclk),.reset,.legacy_scanout_pending(OUTER_PRIORITY && scan_pending),
        .legacy_read(legacy_rd),.legacy_write(legacy_we),
        .legacy_burst_count(legacy_burst),.legacy_address(legacy_addr),
        .legacy_write_data(legacy_din),.legacy_byte_enable(legacy_be),
        .legacy_busy,.legacy_command_accepted(),.legacy_read_data(legacy_dout),
        .legacy_read_data_ready(legacy_valid),
        .plane_read(1'b0),.plane_write(1'b0),.plane_burst_count(8'd1),
        .plane_address(29'd0),.plane_write_data(64'd0),.plane_byte_enable(8'd0),
        .plane_busy(),.plane_command_accepted(),.plane_read_data(),.plane_read_data_ready(),
        .event_read(1'b0),.event_write(EVENTS && (event_pending || event_stream)),.event_burst_count(8'd8),
        .event_address(29'h07f01000),.event_write_data(event_data),.event_byte_enable(8'hff),
        .event_busy(event_busy),.event_command_accepted(event_accepted),.event_read_data(),.event_read_data_ready(),
        .control_read(accelerator_pending),.control_write(1'b0),
        .control_burst_count(8'd128),.control_address(29'h07f80000),
        .control_write_data(64'd0),.control_byte_enable(8'hff),
        .control_busy(accelerator_busy),.control_command_accepted(),
        .control_read_data(accelerator_data),.control_read_data_ready(accelerator_valid),
        .ddram_read(rd),.ddram_write(wr),.ddram_burst_count(burst),
        .ddram_address(addr),.ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),.ddram_read_data_ready(valid),
        .epoch_quiescent(),.protocol_error,.debug_state()
    );
    integer cycles=0,left=0,delay_count=0,cart_completed=0;
    reg [28:0] response_addr;
    reg [31:0] rng=32'hb15ca17;
    function automatic [63:0] word_at(input [28:0] a);
        begin
            if(a >= 29'h07fc0000) word_at={14'd0,pixel(2*(a&127)+1,(a>>7)&255,(a>>15)&1,(a>>16)&3,0),14'd0,pixel(2*(a&127),(a>>7)&255,(a>>15)&1,(a>>16)&3,0)};
            else word_at={3'b0,a,3'b0,a};
        end
    endfunction
    always @(posedge dclk) begin
        cycles<=cycles+1;
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        busy<=reset || rng[2:0]==0;
        valid<=0;
        if(!reset) begin
            if(protocol_error) $fatal(1,"fabric protocol error");
            if(event_pending && !event_busy) begin event_pending<=0;event_stream<=1;end
            if(event_accepted) begin
                event_beat<=event_beat+1;
                if(event_beat==7) begin
                    event_completed<=event_completed+1;event_beat<=0;
                    event_pending<=1;event_stream<=0;
                end
            end
            if(wr && !busy) begin
                if(left || addr!=29'h07f01000 || burst!=8 || be!=8'hff || din!=64'(event_words))
                    $fatal(1,"event burst ownership/data corrupted");
                event_words<=event_words+1;
            end
            if(rd && !busy) begin
                if(left) $fatal(1,"read response ownership overlap");
                left<=burst;response_addr<=addr;delay_count<=12+(rng[7:3]);
            end else if(delay_count) delay_count<=delay_count-1;
            else if(left) begin
                dout<=word_at(response_addr);valid<=1;
                response_addr<=response_addr+1'b1;left<=left-1;
                delay_count<=rng[2:0]==0 ? 3 : 0;
            end
            if(accelerator_pending && !accelerator_busy) begin
                accelerator_pending<=0;accelerator_receiving<=1;accelerator_beat<=0;
            end
            if(accelerator_valid) begin
                if(!accelerator_receiving || accelerator_data!==word_at(29'h07f80000+accelerator_beat))
                    $fatal(1,"accelerator response corrupted");
                accelerator_beat<=accelerator_beat+1;
                if(accelerator_beat==127) begin
                    accelerator_pending<=1;accelerator_receiving<=0;
                    accelerator_completed<=accelerator_completed+1;
                end
            end
        end
    end
    // Keep the next miss queued while the previous four-beat refill drains.
    always @(negedge dclk) begin
        cart_req=0;
        if(!reset && (cycles==20 || cart_ready)) begin
            if(cart_ready) begin
                if(cart_data!==(32'h06000000+{7'b0,cart_addr[27:3]}))
                    $fatal(1,"cartridge response corrupted");
                cart_completed=cart_completed+1;
                cart_addr=cart_addr+27'd16;
            end
            cart_req=1;
        end
    end

    assign read_data=scan_data; assign read_valid=scan_valid; assign read_ready=scan_ready;
    reg checking=0, exact=1;
    integer comparisons=0,clock_count=0,last_analog_frame=0,analog_frames=0;
    reg [15:0] line_tag[0:2];
    reg line_black[0:2];
    task automatic check_pixel(input integer consumer,x,y,scr,input [23:0] actual);
        reg [23:0] wanted;
        integer dx,dy;
        begin
            wanted=rgb(pixel(x,y,scr,dut.active_screen_bank[scr],dut.active_screen_external[scr]));
            dx=x-128;dy=y-96;
            if(scr==1 && touch_pressed) begin
                if((dx==0 && dy>=-4 && dy<=4) || (dy==0 && dx>=-4 && dx<=4)) wanted=24'hff0000;
                else if((dx>=-1 && dx<=1 && dy>=-5 && dy<=5) ||
                        (dy>=-1 && dy<=1 && dx>=-5 && dx<=5)) wanted=0;
            end
            if(exact && actual!==wanted)
                $fatal(1,"pixel c=%0d layout=%0d x=%0d y=%0d scr=%0d actual=%h wanted=%h hc=%0d vc=%0d slot=%b busy=%b",
                    consumer,layout,x,y,scr,actual,wanted,dut.hcount,dut.vcount,lb_selected_slot,lb_hold);
            if(x==0) begin
                line_tag[consumer]=actual[15:0];
                line_black[consumer]=actual==0;
            end
            if(!exact && (actual[15:0]!==line_tag[consumer] ||
                (line_black[consumer] ? actual!=0 : actual[23:16]!==wanted[23:16])))
                $fatal(1,"partial line exposed c=%0d x=%0d y=%0d actual=%h tag=%h",consumer,x,y,actual,line_tag[consumer]);
            comparisons=comparisons+1;
        end
    endtask
    integer x,y,scr,sx,sy,second_x,second_y;
    reg in_panel;
    always @(negedge clk) begin
        clock_count=clock_count+1;
        if(split_active && dut.analog_hcount==0 && dut.analog_vcount==0 && dut.analog_divider==0) begin
            if(checking && last_analog_frame && clock_count-last_analog_frame!=3840*262)
                $fatal(1,"analog frame duration %0d",clock_count-last_analog_frame);
            last_analog_frame=clock_count;
            analog_frames=analog_frames+1;
        end
        // Writer and visible slots may never alias while a split burst owns DDR.
        if(split_active && fb.rbusy && fb.r_split && !fb.r_session_cancel &&
           (fb.rslot==lb_selected_slot[{fb.rbank,fb.rscr}] ||
            (fb.active_line_valid[{fb.rbank,fb.rscr}] &&
             fb.rslot==fb.active_line_slot[{fb.rbank,fb.rscr}])) && checking)
            $fatal(1,"visible line slot overwritten");
        if(checking && ce) begin
            x=dut.hcount==0 ? dut.horizontal_total-1 : dut.hcount-1;
            y=dut.hcount==0 ? (dut.vcount==0 ? dut.vertical_total+dut.frame_extra-1 : dut.vcount-1) : dut.vcount;
            in_panel=0;sx=0;sy=0;scr=0;
            second_x=256+8*dut.gap_active;
            second_y=192+8*dut.gap_active;
            if(dut.crt_active) begin
                in_panel=x>=32 && x<288 && y>=24 && y<216;
                sx=x-32;sy=y-24;
                scr=dut.screen_order_active ^ (dut.layout_active==3);
            end else if(dut.layout_active==0) begin
                in_panel=y<192 && (x<256 || (x>=second_x && x<second_x+256));
                sx=x<256 ? x : x-second_x;sy=y;
                scr=dut.screen_order_active ^ (x>=second_x);
            end else begin
                in_panel=x<256 && (y<192 || (y>=second_y && y<second_y+192));
                sx=x;sy=y<192 ? y : y-second_y;
                scr=dut.screen_order_active ^ (y>=second_y);
            end
            if(in_panel) check_pixel(scr,sx,sy,scr,{r,g,b});
            else if({r,g,b}!==0) $fatal(1,"digital border not black");
        end
        if(checking && ace) begin
            x=dut.analog_hcount==0 ? 383 : dut.analog_hcount-1;
            y=dut.analog_hcount==0 ? (dut.analog_vcount==0 ? 261 : dut.analog_vcount-1) : dut.analog_vcount;
            if(x>=32 && x<288 && y>=24 && y<216)
                check_pixel(2,x-32,y-24,analog_active,{ar,ag,ab});
            else if({ar,ag,ab}!==0) $fatal(1,"analog border not black");
            if(ade!==(x<320 && y<240) || ahs!==!(x>=328 && x<356) || avs!==!(y>=243 && y<246))
                $fatal(1,"analog sync/DE changed with digital layout");
        end
    end
    task automatic frame;
        begin
            @(negedge clk);
            while(!(dut.hcount==0 && dut.vcount==0 && dut.pixel_divider==0)) @(negedge clk);
        end
    endtask
    initial begin
        repeat(12) @(negedge clk); reset=0;session_reset=0;published=1;
        for(integer k=0;k<16;k=k+1) begin
            checking=0;
            layout=k%4;analog_screen=(k/4)%2;order=k/8;gap=k%2 ? 3 : 0;
            frame();frame();frame();
            checking=1;frame();checking=0;
            $display("PASS layout=%0d analog=%0d order=%0d gap=%0d",layout,analog_screen,order,gap);
        end
        if(cart_completed<4 || accelerator_completed<48 || (EVENTS && event_completed<48)) $fatal(1,"peer failed to progress");
        $display("PASS integrated scanout under saturated cartridge and accelerator: pixels=%0d cart=%0d accelerator=%0d events=%0d",comparisons,cart_completed,accelerator_completed,event_completed);
        $finish;
    end
    initial begin #2000000000; $fatal(1,"integrated timeout"); end
endmodule
