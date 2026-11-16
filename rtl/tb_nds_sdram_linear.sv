// SPDX-License-Identifier: GPL-3.0-or-later
// Pin-level raw channel-3 writes and four-halfword reads, including A9 at 32 MiB.
`timescale 1ns/1ps
module tb_nds_sdram_linear #(parameter integer PIPE=0);
    reg clk=0,init=1;always #5 clk=~clk;
    tri [15:0] dq;
    wire [12:0] a;wire [1:0] ba;wire ncs,nwe,nras,ncas,ml,mh,ready;
    reg req=0,rnw=1;reg [26:1] addr=0;reg [15:0] din=0;
    wire [63:0] dout;
    sdram #(.CAS_LATENCY(3),.TRCD_WAIT(2),.DQ_PIPE(PIPE),.CH3_LINEAR(1)) dut(
        .init(init),.clk(clk),.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),
        .SDRAM_DQML(ml),.SDRAM_DQMH(mh),.SDRAM_nCS(ncs),.SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),
        .refresh_req(1'b0),.ch1_addr(26'd0),.ch1_din(16'd0),.ch1_req(1'b0),.ch1_rnw(1'b1),
        .ch2_addr(26'd0),.ch2_din(32'd0),.ch2_be(4'b1111),.ch2_req(1'b0),.ch2_rnw(1'b1),
        .ch2_cancel(1'b0),.ch2_wide(1'b0),.ch2_din_hi(32'd0),.ch2_be_hi(4'd0),
        .ch3_addr(addr),.ch3_din(din),.ch3_req(req),.ch3_rnw(rnw),.ch3_ready(ready),.ch3_dout64(dout));
    reg drive=0;reg [15:0] driven=0;assign dq=drive?driven:16'bz;
    reg [12:0] rows[0:3];reg [15:0] mem[0:511];
    reg [25:0] physical,read_base,expected_address;
    reg [15:0] expected_data;
    integer latency=0,left=0,beat=0,physical_writes=0,physical_reads=0,last_active=-100,cycle=0;
    reg checking_write=0;
    always @(negedge clk) begin
        cycle=cycle+1;drive=0;
        if(left) begin
            if(latency)latency=latency-1;
            else begin drive=1;driven=mem[(read_base+beat)&511];beat=beat+1;left=left-1;end
        end
        if(!ncs && {nras,ncas,nwe}==3'b011) begin
            if(cycle-last_active<8)$fatal(1,"tRC violated in raw uploads");
            last_active=cycle;rows[ba]=a;
        end
        if(!ncs && ({nras,ncas,nwe}==3'b100 || {nras,ncas,nwe}==3'b101)) begin
            physical={1'b0,a[9],ba,rows[ba],a[8:0]};
            if(!a[10])$fatal(1,"raw access omitted auto-precharge");
            if({mh,ml}!=0)$fatal(1,"raw access masked bytes");
            if({nras,ncas,nwe}==3'b100) begin
                if(!checking_write || physical!==expected_address || dq!==expected_data)
                    $fatal(1,"raw WRITE addr=%h/%h data=%h/%h",physical,expected_address,dq,expected_data);
                mem[physical&511]=dq;physical_writes=physical_writes+1;checking_write=0;
            end else begin
                if(physical!==expected_address || left)$fatal(1,"raw READ address/overlap");
                read_base=physical;latency=2;left=4;beat=0;physical_reads=physical_reads+1;
            end
        end
    end
    task access(input [25:0] at,input bit reading,input [15:0] value);
        @(posedge clk);#1;addr=at;rnw=reading;din=value;req=1;
        expected_address=at;expected_data=value;checking_write=!reading;
        @(posedge clk);#1;req=0;
        wait(ready);@(negedge clk);#1;
        if(checking_write)$fatal(1,"ready before physical WRITE");
        repeat(3)@(posedge clk);
    endtask
    reg [25:0] bases[0:4];integer i,j;
    initial begin
        bases[0]=26'h800000;bases[1]=26'hfffffc;bases[2]=26'h1000000;
        bases[3]=26'h1fffffc;bases[4]=26'h8001fc;
        repeat(4)@(posedge clk);@(negedge clk);init=0;
        repeat(13000)@(posedge clk);
        for(i=0;i<5;i=i+1) begin
            for(j=0;j<4;j=j+1)access(bases[i]+j,0,16'h1230+i*16+j);
            access(bases[i],1,0);
            if(dout!=={16'(16'h1233+i*16),16'(16'h1232+i*16),16'(16'h1231+i*16),16'(16'h1230+i*16)})
                $fatal(1,"raw burst data %h",dout);
        end
        if(physical_writes!=20 || physical_reads!=5)$fatal(1,"extra raw accesses");
        $display("PASS: raw SDRAM channel pins, 16/32/64 MiB boundaries, exact halfwords, full read burst, DQ_PIPE=%0d",PIPE);
        $finish;
    end
    initial begin #10000000;$fatal(1,"raw SDRAM watchdog");end
endmodule
