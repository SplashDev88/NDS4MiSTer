`timescale 1ns/1ps
module tb_dv1_legacy_width;
    reg clk=0;
    always #5 clk=~clk;
    reg io_osd=0,io_strobe=0;
    reg [15:0] io_din=0;
    reg de=0,hs=0,vs=0,ce=0,native_enable=0;
    reg [23:0] rgb=0;
    wire [23:0] actual,reference;
    wire [9:0] sw=applied_rotation==0 ? w : h;
    wire [9:0] sh=applied_rotation==0 ? h : w;
    wire wide_enable=native_enable && (sw>320 || sh>240);
    wire [3:0] actual_ctl,reference_ctl;
    wire we,re,busy;
    wire [12:0] wa,ra;
    wire [7:0] wd,q;
    wire ar,scheduled;
    wire [12:0] aa;
    wire [7:0] aq;
    nds_native_osd_memory memory(.clk,.write_enable(we),.write_address(wa),.write_data(wd),
        .busy,.digital_read(re),.digital_address(ra),.digital_q(q),
        .analog_read(ar && scheduled),.analog_address(aa),.analog_q(aq));
    osd #(.OSD_COUNTER_BITS(14),.OSD_MAX_LINES(512),.OSD_EXTERNAL_BUFFER(1),.OSD_NATIVE_PIXELS(0),.OSD_DOUBLE_WIDTH(1)) dut (
        .clk_sys(clk),.clk_video(clk),.io_osd,.io_strobe,.io_din,
        .din(rgb),.de_in(de),.hs_in(hs),.vs_in(vs),.dout(actual),
        .de_out(actual_ctl[0]),.hs_out(actual_ctl[1]),.vs_out(actual_ctl[2]),.osd_status(actual_ctl[3]),
        .buffer_we(we),.buffer_waddr(wa),.buffer_wdata(wd),
        .buffer_re(re),.buffer_raddr(ra),.buffer_q(q),.buffer_scheduled(),
        .native_pixel_enable(native_enable),.native_pixel_ce(ce),.native_rotation(applied_rotation),.double_width(wide_enable));
    osd_reference #(.OSD_COUNTER_BITS(14),.OSD_MAX_LINES(512)) old (
        .clk_sys(clk),.clk_video(clk),.io_osd,.io_strobe,.io_din,
        .din(rgb),.de_in(de),.hs_in(hs),.vs_in(vs),.dout(reference),
        .de_out(reference_ctl[0]),.hs_out(reference_ctl[1]),.vs_out(reference_ctl[2]),.osd_status(reference_ctl[3]),.double_width(wide_enable));
    // Simultaneous independent analog output shares the same RAM while the
    // new digital reader runs every clock. Its pixels must stay unchanged.
    integer ax=0,ay=0;
    reg ade=0,ahs=0,avs=0;
    wire [23:0] analog_rgb,analog_reference;
    wire [3:0] analog_ctl,analog_reference_ctl;
    always @(negedge clk) begin
        if(ax==3839) begin ax=0;ay=(ay==261?0:ay+1);end else ax=ax+1;
        ade=ax<3200 && ay<240;ahs=ax>=3280 && ax<3560;avs=ay>=243 && ay<246;
    end
    osd #(.OSD_COUNTER_BITS(12),.OSD_MAX_LINES(240),.OSD_FIXED_UPRIGHT(1),.OSD_EXTERNAL_BUFFER(1)) analog_osd (
        .clk_sys(clk),.clk_video(clk),.io_osd,.io_strobe,.io_din,
        .din(24'h345678),.de_in(ade),.hs_in(ahs),.vs_in(avs),.dout(analog_rgb),
        .de_out(analog_ctl[0]),.hs_out(analog_ctl[1]),.vs_out(analog_ctl[2]),.osd_status(analog_ctl[3]),
        .buffer_re(ar),.buffer_raddr(aa),.buffer_q(aq),.buffer_scheduled(scheduled));
    osd_reference #(.OSD_COUNTER_BITS(12),.OSD_MAX_LINES(240),.OSD_FIXED_UPRIGHT(1)) analog_old (
        .clk_sys(clk),.clk_video(clk),.io_osd,.io_strobe,.io_din,
        .din(24'h345678),.de_in(ade),.hs_in(ahs),.vs_in(avs),.dout(analog_reference),
        .de_out(analog_reference_ctl[0]),.hs_out(analog_reference_ctl[1]),
        .vs_out(analog_reference_ctl[2]),.osd_status(analog_reference_ctl[3]));

    integer px,py,w,h,rows,divisor,tick=0;
    integer row_first,row_last,row_count;
    reg visible=0, checking=0;
    reg [1:0] applied_rotation=0;
    reg [26:0] expected[0:3];
    integer checked=0,col0=0,col255=0;
    function automatic [7:0] content(input integer x,y);
        content=(y*17)^x^(x>>3);
    endfunction
    function automatic [23:0] overlay(input [23:0] background,input bit pixel);
        overlay={{pixel,pixel,1'b1,background[23:19]},
                 {pixel,pixel,1'b0,background[15:11]},
                 {pixel,pixel,1'b0,background[7:3]}};
    endfunction
    always @(posedge clk) begin : oracle
        reg [23:0] want;
        reg [7:0] bits;
        integer x,y,sx,sy,sw,sh;
        want=rgb;
        sw=applied_rotation==0?w:h;sh=applied_rotation==0?h:w;
        sx=applied_rotation==1?py:applied_rotation==2?sw-1-py:px;
        sy=applied_rotation==1?sh-1-px:applied_rotation==2?px:py;
        x=sx-(sw-256)/2;y=sy-(sh-rows*8)/2;
        if(visible && de && x>=0 && x<256 && y>=0 && y<rows*8) begin
            bits=content(x,y/8);
            want=overlay(rgb,bits[y%8]);
            if(checking && native_enable && x==0) col0=col0+1;
            if(checking && native_enable && x==255) col255=col255+1;
        end
        expected[3]<=expected[2];expected[2]<=expected[1];expected[1]<=expected[0];
        expected[0]<={vs,hs,de,want};
        #1;
        if(checking) begin
            if({analog_ctl,analog_rgb} !== {analog_reference_ctl,analog_reference})
                $fatal(1,"independent analog changed while DV1 enabled=%0d",native_enable);
            if({actual_ctl,actual} !== {reference_ctl,reference})
                $fatal(1,"legacy output differs from pre-DS-pixel reference mode%0dx%0d/%0d",w,h,divisor);
            if(visible && py==h/2 && actual_ctl[0] && actual!=0) begin
                if(row_first<0) row_first=tick;
                if(tick>row_last) row_last=tick;
                row_count++;
            end
            checked=checked+1;
        end
    end
    task automatic tx(input [15:0] value);
        @(negedge clk);io_din=value;io_strobe=1;
        repeat(2) @(negedge clk);io_strobe=0;
        repeat(2) @(negedge clk);
    endtask
    task automatic start_cmd(input [15:0] value);
        @(negedge clk);io_osd=0;
        repeat(2) @(negedge clk);io_osd=1;tx(value);
    endtask
    task automatic end_cmd;
        @(negedge clk);io_osd=0;
        repeat(8) @(negedge clk);
    endtask
    task automatic menu(input integer rotation);
        start_cmd('h40);end_cmd();
        for(integer row=0;row<rows;row++) begin
            start_cmd('h20|row);
            for(integer col=0;col<256;col++) tx(content(col,row));
            end_cmd();
        end
        start_cmd(visible ? rows==8 ? 'h49 : 'h41 : 'h40);
        tx(0);tx(0);tx(0);tx(0);tx(rotation);end_cmd();
    endtask
    task automatic raster(input integer width,height,repeat_pixels,menu_rows,rotation,input bit enabled,shown);
        checking=0;native_enable=enabled;visible=shown;
        w=width;h=height;divisor=repeat_pixels;rows=menu_rows;
        col0=0;col255=0;menu(rotation);
        for(integer frame=0;frame<8;frame++) begin
            row_first=-1;row_last=-1;row_count=0;
            for(integer y=0;y<height+30;y++) begin
                for(integer x=0;x<(width+100)*divisor;x++) begin
                    @(negedge clk);
                    checking=frame>=6;
                    px=x/divisor;py=y;tick=x;
                    ce=(x%divisor)==0;
                    de=(px<width && y<height);
                    hs=(px>=width+16 && px<width+64);
                    vs=(y>=height+3 && y<height+6);
                    rgb=shown?24'd0:{8'(px),8'(py),8'(px^py)};
                end
            end
            if(frame>=6 && rotation==0) begin : width_check
                integer period,limit,expected_width;
                period=(width*repeat_pixels)/512;
                if(period<1) period=1;
                limit=(width*repeat_pixels)/264;
                if(wide_enable && width*repeat_pixels<4096 && limit>period)
                    period=(2*period<limit)?2*period:limit;
                expected_width=shown?256*period:0;
                if(row_count!=expected_width)
                    $fatal(1,"visible width %0d expected %0d at %0dx%0d repeat%0d",row_count,expected_width,width,height,repeat_pixels);
                if(shown && ((row_first+row_last)-(width*repeat_pixels-1)>period*8+8 ||
                             (width*repeat_pixels-1)-(row_first+row_last)>period*8+8))
                    $fatal(1,"menu off center %0d..%0d canvas%0d",row_first,row_last,width*repeat_pixels);
            end
        end
        @(negedge clk);checking=0;
        if(0)
            $fatal(1,"missing edge columns %0d %0d",col0,col255);
        $display("PASS %s %0dx%0d repeat%0d rows%0d rotation%0d visible%0d",
                 enabled?"legacy with DV1 active":"legacy exact",w,h,divisor,rows,rotation,shown);
    endtask
    initial begin
        repeat(5) @(negedge clk);
        // Full-width stacked display, single-screen CRT canvas and side-by-side.
        raster(256,392,3,16,0,1,1);
        raster(256,392,3,8,0,1,1);
        raster(320,240,10,16,0,1,1);
        raster(536,198,6,16,0,1,1);
        raster(512,192,6,16,0,1,1);
        raster(520,192,6,16,0,1,1);
        raster(256,192,6,8,0,1,1);
        raster(256,414,3,16,0,1,1);
        raster(256,392,3,16,0,1,0);
        // Rotated game canvases retain the upright legacy menu; fit it safely.
        applied_rotation=1;
        raster(392,256,6,16,0,1,1);
        raster(240,320,3,8,0,1,1);
        raster(198,536,2,16,0,1,1);
        applied_rotation=2;
        raster(414,256,6,16,0,1,1);
        raster(192,520,2,8,0,1,1);
        applied_rotation=0;
        // Switch back after DV1; every RGB and sync sample must match rc10.
        raster(256,392,3,16,0,0,1);
        raster(320,240,10,16,0,0,1);
        raster(536,198,6,8,0,0,1);
        raster(320,240,10,16,1,0,1);
        raster(320,240,10,8,3,0,1);
        $display("PASS dual DV1 width, single/legacy equivalence, centering and analog: %0d samples",checked);
        $finish;
    end
endmodule
