`timescale 1ns/1ps
module tb_shared_osd;
    reg clk=0;
    always #5 clk=~clk;
    reg selected=0,io_clk=0,rack=0,io_ack=0;
    wire io_strobe=~rack & io_clk;
    reg [15:0] io_din=0;
    wire busy;
    // Exact sys_top acknowledgement structure, with the proposed busy term.
    always @(posedge clk) if(!busy || io_strobe) begin
        rack<=io_clk;
        io_ack<=rack;
    end
    reg dde=0,dhs=0,dvs=0,ade=0,ahs=0,avs=0,analog_active=0;
    wire [23:0] ref_d,ref_a,new_d,new_a;
    wire [3:0] rdc,rac,ndc,nac;
    wire we,dre,are,scheduled;
    wire [12:0] wa,da,aa;
    wire [7:0] wd,dq,aq;
    osd_reference #(.OSD_COUNTER_BITS(14),.OSD_MAX_LINES(512)) original_d
      (.clk_sys(clk),.io_osd(selected),.io_strobe,.io_din,.clk_video(clk),
       .din(24'h245678),.de_in(dde),.hs_in(dhs),.vs_in(dvs),
       .dout(ref_d),.de_out(rdc[0]),.hs_out(rdc[1]),.vs_out(rdc[2]),.osd_status(rdc[3]));
    osd_reference #(.OSD_COUNTER_BITS(12),.OSD_FIXED_UPRIGHT(1),.OSD_MAX_LINES(240)) original_a
      (.clk_sys(clk),.io_osd(selected),.io_strobe,.io_din,.clk_video(clk),
       .din(24'h783456),.de_in(ade),.hs_in(ahs),.vs_in(avs),
       .dout(ref_a),.de_out(rac[0]),.hs_out(rac[1]),.vs_out(rac[2]),.osd_status(rac[3]));
    osd #(.OSD_COUNTER_BITS(14),.OSD_MAX_LINES(512),.OSD_EXTERNAL_BUFFER(1)) shared_d
      (.clk_sys(clk),.io_osd(selected),.io_strobe,.io_din,.clk_video(clk),
       .din(24'h245678),.de_in(dde),.hs_in(dhs),.vs_in(dvs),
       .dout(new_d),.de_out(ndc[0]),.hs_out(ndc[1]),.vs_out(ndc[2]),.osd_status(ndc[3]),
       .buffer_we(we),.buffer_waddr(wa),.buffer_wdata(wd),
       .buffer_re(dre),.buffer_raddr(da),.buffer_q(dq),.buffer_scheduled());
    osd #(.OSD_COUNTER_BITS(12),.OSD_FIXED_UPRIGHT(1),.OSD_MAX_LINES(240),.OSD_EXTERNAL_BUFFER(1)) shared_a
      (.clk_sys(clk),.io_osd(selected),.io_strobe,.io_din,.clk_video(clk),
       .din(24'h783456),.de_in(ade),.hs_in(ahs),.vs_in(avs),
       .dout(new_a),.de_out(nac[0]),.hs_out(nac[1]),.vs_out(nac[2]),.osd_status(nac[3]),
       .buffer_we(),.buffer_waddr(),.buffer_wdata(),
       .buffer_re(are),.buffer_raddr(aa),.buffer_q(aq),.buffer_scheduled(scheduled));
    nds_native_osd_memory memory(.clk,.write_enable(we),.write_address(wa),.write_data(wd),.busy,
       .digital_read(dre),.digital_address(da),.digital_q(dq),
       .analog_read(are && scheduled && analog_active),.analog_address(aa),.analog_q(aq));
    integer checks=0,dpixels=0,apixels=0,peak=0,writes=0;
    reg checking=0;
    always @(posedge clk) begin
        if(we) writes=writes+1;
        if(memory.count>peak) peak=memory.count;
        #1;
        if(checking) begin
            if({new_d,ndc}!=={ref_d,rdc}) $fatal(1,"digital mismatch at %0t new=%h old=%h",$time,new_d,ref_d);
            if({new_a,nac}!=={ref_a,rac}) $fatal(1,"analog mismatch at %0t new=%h old=%h",$time,new_a,ref_a);
            if((^new_a)===1'bx || (^new_d)===1'bx) $fatal(1,"unknown visible data");
            checks=checks+1;
            if(ndc[0] && new_d!=24'h245678) dpixels=dpixels+1;
            if(nac[0] && new_a!=24'h783456) apixels=apixels+1;
        end
    end
    task automatic tx(input [15:0] word);
        @(negedge clk);io_din=word;io_clk=1;
        while(!io_ack) @(negedge clk);
        io_clk=0;
        while(io_ack) @(negedge clk);
    endtask
    task automatic begin_cmd(input [15:0] word);
        @(negedge clk);selected=0;
        repeat(3) @(negedge clk);
        selected=1;tx(word);
    endtask
    task automatic end_cmd;
        @(negedge clk);selected=0;
        repeat(3) @(negedge clk);
    endtask
    task automatic menu(input integer rotation,input integer mode);
        begin_cmd('h40);tx(0);tx(0);tx(0);tx(0);tx(rotation);end_cmd();
        for(integer row=0;row<(mode==1?8:16);row=row+1) begin
            begin_cmd('h20|row);
            for(integer col=0;col<256;col=col+1) tx((row*17)^col^(col>>3));
            end_cmd();
        end
        if(mode>=2) begin
            begin_cmd('h45);tx(mode==3?4000:32);tx(mode==3?4000:48);tx(24);tx(9);tx(rotation);end_cmd();
        end else begin_cmd('h41);
        end_cmd();
    endtask
    task automatic run(input integer width,height,total_h,total_v,divisor,rotation,mode);
        integer dx,dy,ax,ay;
        checking=0;dpixels=0;apixels=0;
        dx=0;dy=0;ax=0;ay=0;
        fork
            begin
                // Stress menu writes while both scanout engines are reading.
                repeat(2022160) @(negedge clk);
                menu(rotation,mode);
            end
            begin
                for(integer frame=0;frame<8;frame=frame+1) begin
                    checking=frame>=6;
                    analog_active=frame>=1;
                    for(integer tick=0;tick<1006080;tick=tick+1) begin
                        @(negedge clk);
                        dde=dx<width*divisor && dy<height;
                        dhs=dx>=(width+8)*divisor && dx<(width+36)*divisor;
                        dvs=dy>=height+3 && dy<height+6;
                        ade=analog_active && ax<3200 && ay<240;
                        ahs=ax>=3280 && ax<3560;avs=ay>=243 && ay<246;
                        if(dx==total_h*divisor-1) begin dx=0;dy=dy==total_v-1?0:dy+1;end else dx=dx+1;
                        if(ax==3839) begin ax=0;ay=ay==261?0:ay+1;end else ax=ax+1;
                    end
                end
                checking=0;
            end
        join
        if(mode!=3 && (dpixels==0 || apixels==0)) $fatal(1,"menu absent");
        for(integer i=0;i<4096;i=i+1)
            if((i%2 ? memory.bitmap_odd[i/2] : memory.bitmap_even[i/2])!==original_d.osd_buffer[i]) $fatal(1,"lost bitmap byte%0d",i);
        $display("PASS shared bitmap %0dx%0d /%0d rot%0d mode%0d pixels%0d/%0d peakFIFO%0d",width,height,divisor,rotation,mode,dpixels,apixels,peak);
    endtask
    initial begin
        original_d.scan.f1=0;original_a.scan.f1=0;shared_d.scan.f1=0;shared_a.scan.f1=0;
        repeat(5) @(negedge clk);
        run(320,240,384,262,10,0,0);
        run(536,198,640,262,6,0,1);
        run(536,198,640,262,6,1,0);
        run(256,414,640,524,3,0,0);
        run(256,414,640,524,3,3,2);
        run(320,240,384,262,10,0,3);
        $display("PASS %0d pixel/control comparisons per output, %0d SPI writes, peak queue%0d",checks,writes,peak);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"timeout");end
endmodule
