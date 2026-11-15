// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual MiSTer FIO address counter and its delayed write pulse.
`timescale 1ns/1ps
module tb_nds_cart_fio;
    reg clk=0,mem_clk=0,reset=1;
    always #5 clk=~clk;
    always #3.7 mem_clk=~mem_clk;
    tri [45:0] HPS_BUS;
    tri [35:0] EXT_BUS;
    reg selected=0,strobe=0;
    reg [15:0] data=0;
    assign HPS_BUS[45:38]=0;
    assign HPS_BUS[35:33]={selected,1'b0,strobe};
    assign HPS_BUS[31:16]=data;
    assign EXT_BUS[32]=0;
    assign EXT_BUS[15:0]=0;
    wire download,wr,wait_io;
    wire [26:0] address;
    wire [15:0] index,payload;
    wire [31:0] lba[2];
    wire [5:0] blocks[2];
    wire [15:0] buff[2];
    assign lba[0]=0;assign blocks[0]=0;assign buff[0]=0;
    assign lba[1]=0;assign blocks[1]=0;assign buff[1]=0;
    hps_io #(.CONF_STR("T;"),.WIDE(1),.VDNUM(2)) io(
        .clk_sys(clk),.HPS_BUS,.EXT_BUS,
        .sd_lba(lba),.sd_blk_cnt(blocks),.sd_buff_din(buff),.sd_rd(2'b0),.sd_wr(2'b0),
        .ioctl_download(download),.ioctl_index(index),.ioctl_wr(wr),
        .ioctl_addr(address),.ioctl_dout(payload),.ioctl_wait(wait_io),
        .ioctl_upload_req(1'b0),.ioctl_upload_index(8'd0),.ioctl_din(16'd0),
        .status_set(1'b0),.status_in(128'd0),.info_req(1'b0),
        .new_vmode(1'b0),.video_rotated(1'b0)
    );
    wire loaded,fault,ram_req,ram_rnw;
    wire [26:1] ram_addr;
    wire [15:0] ram_data;
    reg ram_ready=0;
    wire full=download && index==16'hf03;
    nds_cart_sdram_tail #(.TAIL_BYTES(256)) tail(
        .clk,.mem_clk,.reset,.cart_download(download),.full_download(full),
        .ioctl_wr(wr),.ioctl_addr(address),.ioctl_data(payload),.ioctl_wait(wait_io),
        .loaded,.fault,.read_req(1'b0),.read_addr(26'd0),.read_ready(),.read_data(),
        .ram_addr,.ram_data,.ram_req,.ram_rnw,.ram_ready,.ram_result(64'd0)
    );
    integer writes=0,delay_left=0;
    always @(posedge mem_clk) begin
        ram_ready<=0;
        if(ram_req) begin
            if(delay_left || ram_rnw)$fatal(1,"invalid SDRAM transaction");
            if(ram_addr!==26'h800000+writes || ram_data!==16'h8100+writes)
                $fatal(1,"FIO payload/address mismatch at %0d: %h %h",writes,ram_addr,ram_data);
            writes<=writes+1;delay_left<=13;
        end else if(delay_left>1)delay_left<=delay_left-1;
        else if(delay_left==1)begin delay_left<=0;ram_ready<=1;end
    end
    task word(input [15:0] value);
        wait(!wait_io);@(negedge clk);data=value;strobe=1;
        @(negedge clk);strobe=0;
        repeat(4)@(negedge clk);
        wait(!wait_io);
    endtask
    task begin_cmd(input [15:0] command);
        @(negedge clk);selected=1;word(command);
    endtask
    task end_cmd;
        @(negedge clk);selected=0;
        repeat(4)@(negedge clk);
    endtask
    integer i;
    initial begin
        repeat(5)@(negedge clk);reset=0;
        begin_cmd(16'h55);word(16'hf03);end_cmd();
        begin_cmd(16'h53);word(255);word(0);word(0);end_cmd();
        if(loaded || !download || address!=0)$fatal(1,"bad full upload start");
        for(i=0;i<128;i=i+1)begin
            if(i%16==0)begin_cmd(16'h54);
            word(16'h8100+i);
            if(i%16==15)end_cmd();
        end
        if(loaded || writes!=128 || fault)$fatal(1,"premature/malformed upload");
        begin_cmd(16'h53);word(0);end_cmd();
        if(!loaded || fault || download)$fatal(1,"complete FIO upload rejected");
        // Demonstrate the actual protocol interprets these words as address,
        // including the odd offset a trimmed file length would otherwise set.
        begin_cmd(16'h53);word(255);word(37);word(0);end_cmd();
        if(address!=37)$fatal(1,"hps_io address interpretation changed");
        begin_cmd(16'h54);word(16'hf00d);end_cmd();
        begin_cmd(16'h53);word(0);end_cmd();
        if(loaded || !fault || writes!=128)$fatal(1,"bad starting address admitted");
        $display("PASS: actual hps_io FIO counter, chunk boundaries, write backpressure, full commit and trimmed-offset rejection");
        $finish;
    end
    initial begin #1000000;$fatal(1,"FIO watchdog");end
endmodule
