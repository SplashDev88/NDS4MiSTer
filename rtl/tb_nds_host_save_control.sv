`timescale 1ns/1ps
module tb_nds_host_save_control #(parameter bit RAM_SIMULATE=1, parameter bit NAND_SAVES=0);
    logic clk=0,clk7=0,clk9=0,run7=1,run9=1,reset=1;
    always #5 clk=~clk;
    always #7 if(run7) clk7=~clk7;
    always #11 if(run9) clk9=~clk9;
    logic io_enable=0,io_strobe=0;
    logic [15:0] io_din=0,io_dout;
    wire io_override;
    logic ioctl_download=0,ioctl_wr=0;
    logic [15:0] ioctl_index=0,ioctl_dout=0;
    logic [26:0] ioctl_addr=0;
    wire ioctl_wait;
    logic cart_download=0;
    wire cart_profile_ready;
    wire [31:0] cart_profile_code;
    wire [3:0] cart_profile_type;
    logic mounted=0,clean=1,cache_fault=0,persist_pending=0;
    logic [15:0] persist_sequence=16'h1357;
    wire hold_console,native_mode,bios7_ready,bios9_ready,profile_ready,direct_profile_ready,fault;
    wire flush_req,commit_ack;
    wire [15:0] commit_sequence;
    wire [11:0] bios7_addr;
    wire [31:0] bios7_data;
    wire [3:0] bios7_be;
    wire bios7_we;
    wire [9:0] bios9_addr;
    wire [31:0] bios9_data;
    wire [3:0] bios9_be;
    wire bios9_we;
    wire [6:0] builtin_addr;
    wire [31:0] builtin_data;
    wire [3:0] builtin_be;
    wire builtin_we;
    logic [31:0] builtin_ram[0:127];
    logic cfg_pending=0;
    logic [6:0] cfg_addr=0;
    logic [31:0] cfg_data=0;
    logic [3:0] cfg_be=0;
    integer builtin_commits=0;
    logic [4:0] profile_addr=0;
    wire [31:0] profile_data,profile_fw_offset,profile_fw_checksums;
    logic [31:0] ram7[0:4095],ram9[0:1023];
    integer writes7=0,writes9=0,flushes=0,commits=0;
    reg [15:0] last_commit=0;
    nds_firmware_control #(.SIMULATE(RAM_SIMULATE),.HOST_SAVE_PROFILE(1),.NAND_SAVES(NAND_SAVES)) dut(.*);

    // Match the generated SPI RAM's registered config-write stage.
    always @(posedge clk7) begin
        cfg_pending<=builtin_we;
        if(builtin_we) begin
            if(!hold_console) $fatal(1,"built-in profile write escaped hold");
            cfg_addr<=builtin_addr;cfg_data<=builtin_data;cfg_be<=builtin_be;
        end
        if(cfg_pending) begin
            for(integer lane=0;lane<4;lane=lane+1)
                if(cfg_be[lane]) builtin_ram[cfg_addr][lane*8+:8]<=cfg_data[lane*8+:8];
            builtin_commits<=builtin_commits+1;
        end
    end

    always @(posedge clk7) if(bios7_we) begin
        if(!hold_console) $fatal(1,"ARM7 BIOS write escaped console hold");
        if(bios7_be[0]) ram7[bios7_addr][7:0]<=bios7_data[7:0];
        if(bios7_be[1]) ram7[bios7_addr][15:8]<=bios7_data[15:8];
        if(bios7_be[2]) ram7[bios7_addr][23:16]<=bios7_data[23:16];
        if(bios7_be[3]) ram7[bios7_addr][31:24]<=bios7_data[31:24];
        writes7<=writes7+1;
    end
    always @(posedge clk9) if(bios9_we) begin
        if(!hold_console) $fatal(1,"ARM9 BIOS write escaped console hold");
        if(bios9_be[0]) ram9[bios9_addr][7:0]<=bios9_data[7:0];
        if(bios9_be[1]) ram9[bios9_addr][15:8]<=bios9_data[15:8];
        if(bios9_be[2]) ram9[bios9_addr][23:16]<=bios9_data[23:16];
        if(bios9_be[3]) ram9[bios9_addr][31:24]<=bios9_data[31:24];
        writes9<=writes9+1;
    end
    always @(posedge clk) begin
        if(flush_req) flushes<=flushes+1;
        if(commit_ack) begin commits<=commits+1;last_commit<=commit_sequence;end
    end
    function automatic [15:0] halfword(input integer index,offset);
        if(index==6 && offset==0) halfword=16'hfe00;
        else if(index==6 && offset==2) halfword=16'h0003;
        else if(index==6 && offset==4) halfword=16'habcd;
        else if(index==6 && offset==6) halfword=16'h1234;
        else halfword=(offset>>1) ^ (index<<12) ^ 16'h5aa5;
    endfunction
    task automatic word_io(input [15:0] value,output [15:0] response);
        @(negedge clk);io_din=value;io_strobe=1;
        @(posedge clk);#1;response=io_dout;
        @(negedge clk);io_strobe=0;
    endtask
    task automatic check_direct_profile;
        reg [31:0] expected;
        reg [15:0] direct_flags,direct_error;
        if(profile_fw_offset!==32'h0001fe00 || profile_fw_checksums!==32'h00000000)
            $fatal(1,"direct metadata did not restore generated firmware values");
        for(integer i=0;i<128;i=i+1) begin
            expected={halfword(7,i*4+2),halfword(7,i*4)};
            if(builtin_ram[i]!==expected) $fatal(1,"built-in user page word %0d differs",i);
            if(i<28) begin
                @(negedge clk7);profile_addr=i;
                @(posedge clk7);#1;
                if(profile_data!==expected) $fatal(1,"direct loader/SPI profile mismatch %0d",i);
            end
        end
        command(0,0,direct_flags,direct_error);
        if(!direct_flags[9] || !profile_ready) $fatal(1,"completed direct profile flag missing");
    endtask
    task automatic command(input [15:0] op,arg,output [15:0] flags,err);
        reg [15:0] reply;
        @(negedge clk);io_enable=1;
        word_io(16'h45,reply);
        if(reply!==16'h4657 || !io_override) $fatal(1,"0x45 command magic/override timing");
        word_io(op,flags);
        word_io(arg,reply);
        if(reply!==persist_sequence) $fatal(1,"persist sequence response timing");
        word_io(0,err);
        @(negedge clk);io_enable=0;
        @(posedge clk);#1;
        if(io_override || io_dout!==0) $fatal(1,"SPI response leaked after command end");
    endtask
    task automatic begin_asset(input integer index);
        @(negedge clk);ioctl_index=index;ioctl_download=1;ioctl_wr=0;ioctl_addr=0;
        repeat(2) @(negedge clk);
    endtask
    task automatic send_half_value(input integer offset,input [15:0] value);
        integer guard;
        guard=0;
        while(ioctl_wait) begin
            @(negedge clk);guard=guard+1;
            if(guard>300) $fatal(1,"upload CDC stalled");
        end
        @(negedge clk);ioctl_wr=1;ioctl_addr=offset;ioctl_dout=value;
        @(negedge clk);ioctl_wr=0;
    endtask
    task automatic send_half(input integer index,offset);
        send_half_value(offset,halfword(index,offset));
    endtask
    task automatic end_asset;
        integer guard;
        @(negedge clk);ioctl_download=0;ioctl_wr=0;
        repeat(3) @(negedge clk);
        guard=0;
        while(ioctl_wait) begin
            @(negedge clk);guard=guard+1;
            if(guard>300) $fatal(1,"asset never finished after download fell");
        end
        repeat(2) @(negedge clk);
    endtask
    task automatic upload(input integer index,length);
        begin_asset(index);
        for(integer offset=0;offset<length;offset=offset+2) send_half(index,offset);
        end_asset;
    endtask
    task automatic check_profile;
        reg [31:0] expected,previous_data;
        if(profile_fw_offset!==32'h0003fe00 || profile_fw_checksums!==32'h1234abcd)
            $fatal(1,"profile metadata upload differs");
        for(integer i=0;i<28;i=i+1) begin
            @(negedge clk7);previous_data=profile_data;profile_addr=i;
            #1;if(profile_data!==previous_data) $fatal(1,"profile read became asynchronous");
            @(posedge clk7);#1;
            expected={halfword(6,8+i*4+2),halfword(6,8+i*4)};
            if(profile_data!==expected) $fatal(1,"profile word %0d got %h expected %h",i,profile_data,expected);
        end
    endtask
    reg [15:0] flags,err,reply;
    integer before7,before9,before_count;
    task automatic profile(input [31:0] code,input [15:0] kind,magic);
        begin_asset(8);
        send_half_value(0,code[15:0]);send_half_value(2,code[31:16]);
        send_half_value(4,kind);send_half_value(6,magic);end_asset;
    endtask
    initial begin
        repeat(8) @(negedge clk);reset=0;
        command(0,0,flags,err);
        if(flags!==(16'h420 | (NAND_SAVES ? 16'h1000 : 16'h0))) $fatal(1,"capability/reset flags %h",flags);
        command(1,0,flags,err);
        upload(4,16384);upload(5,4096);upload(7,512);
        // Old host can complete its firmware assets but cannot release a cart.
        command(3,0,flags,err);
        if(!fault || !hold_console || err!=3) $fatal(1,"old host released without metadata");
        command(1,0,flags,err);
        profile(32'h45434d41,3,16'h5351);
        if(!cart_profile_ready || cart_profile_code!==32'h45434d41 || cart_profile_type!==3)
            $fatal(1,"profile payload/commit");
        command(3,0,flags,err);
        if(fault || hold_console) $fatal(1,"matching profile did not release");
        // Next cartridge invalidates even if its code is identical.
        @(negedge clk);cart_download=1;repeat(3) @(negedge clk);cart_download=0;
        if(cart_profile_ready) $fatal(1,"stale profile survived ROM replacement");
        command(1,0,flags,err);
        begin_asset(8);send_half_value(0,16'h4d41);end_asset;
        if(cart_profile_ready || !fault) $fatal(1,"interrupted upload became ready");
        command(1,0,flags,err);profile(32'h45434d41,NAND_SAVES ? 10 : 8,16'h5351);
        if(cart_profile_ready || !fault) $fatal(1,"unsupported type accepted");
        command(1,0,flags,err);profile(32'h45434d41,3,16'h5350);
        if(cart_profile_ready || !fault) $fatal(1,"old protocol accepted");
        for(integer kind=0;kind<(NAND_SAVES ? 10 : 8);kind=kind+1) begin
            command(1,0,flags,err);profile(32'h12345678,kind,16'h5351);
            if(fault || !cart_profile_ready || cart_profile_type!==kind)
                $fatal(1,"valid type %0d rejected",kind);
        end
        // Duplicate/out-of-order address is not an atomic profile.
        command(1,0,flags,err);begin_asset(8);
        send_half_value(0,16'h1234);send_half_value(0,16'h5678);end_asset;
        if(cart_profile_ready || !fault) $fatal(1,"duplicate address accepted");
        // No-cartridge native BIOS boot does not require cartridge metadata.
        command(1,0,flags,err);upload(6,120);mounted=1;
        command(2,0,flags,err);
        if(fault || hold_console || !native_mode) $fatal(1,"no-cart firmware blocked");
        @(negedge clk);reset=1;repeat(3) @(negedge clk);reset=0;
        if(cart_profile_ready) $fatal(1,"media reset retained profile");
        $display("PASS: save metadata capability, atomic transfer, old host rejection, replacement invalidation, all types, malformed transfers and no-cart firmware");
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
