// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_tate_controls;
    reg [1:0] rotation=0;
    reg [15:0] analog_in=0;
    reg [31:0] buttons_in=0;
    wire [15:0] analog_out;
    wire [31:0] buttons_out;
    nds_tate_input inputs (.*);
    reg clk=0, reset=1;
    always #5 clk=~clk;
    reg [11:0] hdmi_width=0, hdmi_height=0;
    reg [9:0] source_width=0, source_height=0;
    wire [12:0] arx,ary;
    nds_tate_scale scaler (.*);
    integer rot,x,y,u,v,b,layout,gap,fps,w,h,k,expected_x,expected_y;
    task automatic scale_case(input integer sw,sh,dw,dh);
        integer n;
        begin
            @(negedge clk);
            source_width=sw;source_height=sh;hdmi_width=dw;hdmi_height=dh;
            repeat(40) @(negedge clk);
            n=dw/sh;if(dh/sw<n)n=dh/sw;
            expected_x=n==0 ? sh : 4096+n*sh;
            expected_y=n==0 ? sw : 4096+n*sw;
            if(arx!==13'(expected_x) || ary!==13'(expected_y))
                $fatal(1,"scale %0dx%0d HDMI %0dx%0d got %0d/%0d expected %0d/%0d",sw,sh,dw,dh,arx,ary,expected_x,expected_y);
        end
    endtask
    initial begin
        #20; reset=0;
        for(rot=0;rot<4;rot=rot+1) begin
            rotation=rot;
            for(x=0;x<256;x=x+1)for(y=0;y<256;y=y+1)begin
                analog_in={8'(y^128),8'(x^128)}; #1;
                u=analog_out[7:0]^128;v=analog_out[15:8]^128;
                if(rot==1) begin
                    if(u!=y || v!=255-x)$fatal(1,"CW touch mismatch");
                end else if(rot==2)begin
                    if(u!=255-y || v!=x)$fatal(1,"CCW touch mismatch");
                end else if(u!=x || v!=y)$fatal(1,"Off changed touch");
            end
            for(b=0;b<16;b=b+1)begin
                buttons_in=32'hba987650|b;#1;
                if(buttons_out[31:4]!==buttons_in[31:4])$fatal(1,"non-directional buttons changed");
                if(rot==1 && buttons_out[3:0]!=={buttons_in[0],buttons_in[1],buttons_in[3],buttons_in[2]})$fatal(1,"CW buttons");
                if(rot==2 && buttons_out[3:0]!=={buttons_in[1],buttons_in[0],buttons_in[2],buttons_in[3]})$fatal(1,"CCW buttons");
                if((rot==0||rot==3)&&buttons_out!==buttons_in)$fatal(1,"Off buttons");
            end
        end
        for(layout=0;layout<4;layout=layout+1)
        for(gap=0;gap<4;gap=gap+1)
        for(fps=0;fps<2;fps=fps+1)begin
            w=layout==0?512+gap*8:256;
            h=(layout==1?384+gap*8:192)+fps*6;
            scale_case(w,h,1280,720);scale_case(w,h,1920,1080);
            scale_case(w,h,2560,1440);scale_case(w,h,3840,2160);
            scale_case(w,h,1080,1920);scale_case(w,h,640,480);
            scale_case(w,h,320,200);scale_case(w,h,0,0);
        end
        $display("PASS 262144 touch coordinates, D-pad/non-D-pad controls, 256 rotated scaling cases including portrait and small HDMI modes");
        $finish;
    end
endmodule
