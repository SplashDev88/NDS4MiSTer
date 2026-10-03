`timescale 1ns/1ps
module tb_nds_firmware_control #(parameter bit RAM_SIMULATE=1);
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
    nds_firmware_control #(.SIMULATE(RAM_SIMULATE)) dut(.*);

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
    initial begin
        // Incommensurate clocks exercise separate ARM7/ARM9 upload mailboxes.
        repeat(8) @(negedge clk);reset=0;
        command(0,0,flags,err);
        if(flags!==16'h20 || err!==0) $fatal(1,"reset status flags incorrect %h",flags);
        @(negedge clk);io_enable=1;
        word_io(16'h44,reply);
        if(io_override || reply!==0) $fatal(1,"unselected SPI command claimed");
        word_io(1,reply);word_io(0,reply);
        @(negedge clk);io_enable=0;repeat(2) @(negedge clk);
        if(hold_console) $fatal(1,"unselected SPI command executed an operation");

        // Invalid native release fails closed, then hold clears the fault.
        command(2,0,flags,err);
        if(!fault || native_mode || err!==2) $fatal(1,"native boot accepted without assets");
        command(1,0,flags,err);
        if(!hold_console || fault) $fatal(1,"hold did not clear control fault");

        upload(4,16384);
        if(!bios7_ready || fault || writes7!=8192) $fatal(1,"ARM7 exact-length asset failed %0d",writes7);
        for(integer i=0;i<4096;i=i+1)
            if(ram7[i]!=={halfword(4,i*4+2),halfword(4,i*4)}) $fatal(1,"ARM7 word %0d differs",i);

        // ARM9 must upload even if ARM7 has no clock edges, and vice versa.
        @(negedge clk7);run7=0;before7=writes7;
        upload(5,4096);
        if(!bios9_ready || fault || writes9!=2048 || writes7!=before7) $fatal(1,"independent ARM9 upload failed");
        for(integer i=0;i<1024;i=i+1)
            if(ram9[i]!=={halfword(5,i*4+2),halfword(5,i*4)}) $fatal(1,"ARM9 word %0d differs",i);
        run7=1;
        @(negedge clk9);run9=0;before9=writes9;
        upload(4,16384);
        if(!bios7_ready || fault || writes9!=before9 || writes7!=16384) $fatal(1,"independent ARM7 upload failed");
        run9=1;
        // Profile writes do not require loader clock edges. Each little-endian
        // halfword still reaches the independent host write port.
        @(negedge clk7);run7=0;
        upload(6,120);
        run7=1;
        if(!profile_ready || fault) $fatal(1,"complete profile not ready");
        check_profile;
        // A truncated low-half update must not corrupt its adjacent high half.
        begin_asset(6);
        for(integer offset=0;offset<8;offset=offset+2) send_half(6,offset);
        send_half_value(8,16'hcafe);end_asset;
        if(profile_ready || !fault) $fatal(1,"partial profile published readiness");
        @(negedge clk7);profile_addr=0;
        @(posedge clk7);#1;
        if(profile_data!=={halfword(6,10),16'hcafe})
            $fatal(1,"partial profile write altered untouched halfword");
        command(1,0,flags,err);upload(6,120);check_profile;
        mounted=1;
        command(2,0,flags,err);
        if(hold_console || !native_mode || fault) $fatal(1,"valid native release failed");
        begin_asset(6);
        for(integer offset=0;offset<8;offset=offset+2) send_half(6,offset);
        send_half_value(8,16'hdead);end_asset;
        if(profile_ready || !fault) $fatal(1,"profile mutation without hold accepted");
        check_profile;
        before7=writes7;
        upload(4,2);
        if(writes7!=before7 || bios7_ready || !fault) $fatal(1,"BIOS mutation without hold accepted");
        command(1,0,flags,err);
        upload(6,120);check_profile;
        upload(4,16384);

        // Truncation and oversize reject readiness. A fresh held retry recovers.
        upload(5,4094);
        if(bios9_ready || !fault) $fatal(1,"truncated BIOS accepted");
        command(1,0,flags,err);upload(5,4096);
        if(!bios9_ready || fault) $fatal(1,"BIOS retry failed");
        upload(6,122);
        if(profile_ready || !fault) $fatal(1,"oversize profile accepted");
        command(1,0,flags,err);upload(6,120);check_profile;
        upload(6,118);
        if(profile_ready || !fault) $fatal(1,"truncated profile accepted");
        command(1,0,flags,err);upload(6,120);check_profile;

        // Duplicate/out-of-order address rejects the transfer and allows retry.
        begin_asset(6);send_half(6,0);send_half(6,0);end_asset;
        if(profile_ready || !fault) $fatal(1,"duplicate halfword accepted");
        command(1,0,flags,err);upload(6,120);check_profile;
        begin_asset(6);send_half(6,0);
        @(negedge clk);ioctl_index=5;
        send_half(5,2);end_asset;
        if(profile_ready || !fault) $fatal(1,"asset change mid-transfer accepted");
        command(1,0,flags,err);upload(6,120);check_profile;

        clean=0;command(2,0,flags,err);
        if(!fault || !hold_console || err!==2) $fatal(1,"dirty firmware released");
        clean=1;command(1,0,flags,err);
        cache_fault=1;command(0,0,flags,err);
        if(!flags[7] || err!==16'h8001) $fatal(1,"cache fault reporting differs");
        command(2,0,flags,err);
        if(!hold_console) $fatal(1,"cache fault did not block native release");
        cache_fault=0;command(1,0,flags,err);
        persist_pending=1;command(0,0,flags,err);
        if(!flags[8]) $fatal(1,"pending persistence flag missing");
        before_count=flushes;command(4,0,flags,err);
        if(flushes!=before_count+1) $fatal(1,"flush command must pulse exactly once");
        before_count=commits;command(5,16'hbeef,flags,err);
        if(commits!=before_count+1 || last_commit!==16'hbeef) $fatal(1,"commit payload/timing differs");
        command(3,0,flags,err);
        if(!hold_console || !fault || err!==3)
            $fatal(1,"direct boot accepted the native profile instead of built-in settings");
        command(1,0,flags,err);
        before_count=builtin_commits;upload(7,512);
        if(!direct_profile_ready || fault || builtin_commits!=before_count+256)
            $fatal(1,"direct pages did not fully commit before ready");
        check_direct_profile;
        command(3,0,flags,err);
        if(native_mode || hold_console || fault) $fatal(1,"direct release with valid assets failed");
        command(6,0,flags,err);
        if(!hold_console || !fault || err!==6) $fatal(1,"abort command did not hold console");
        command(1,0,flags,err);
        // Short/oversize pages cannot retain readiness from a previous upload.
        upload(7,510);
        if(direct_profile_ready || profile_ready || !fault) $fatal(1,"short direct pages accepted");
        command(1,0,flags,err);upload(7,514);
        if(direct_profile_ready || profile_ready || !fault) $fatal(1,"oversize direct pages accepted");
        command(1,0,flags,err);
        // A host violating ioctl_wait must not silently lose a page halfword.
        begin_asset(7);
        @(negedge clk7);run7=0;
        send_half(7,0);
        repeat(3) @(negedge clk);
        if(!ioctl_wait) $fatal(1,"stopped built-in target did not backpressure");
        @(negedge clk);ioctl_wr=1;ioctl_addr=2;ioctl_dout=halfword(7,2);
        @(negedge clk);ioctl_wr=0;
        if(!fault || !dut.transfer_bad) $fatal(1,"busy built-in transfer accepted an unacknowledged word");
        run7=1;end_asset;
        if(direct_profile_ready || profile_ready) $fatal(1,"busy built-in transfer published readiness");
        command(1,0,flags,err);
        // Clock-stop test also exercises the extra config pipeline stage.
        begin_asset(7);
        for(integer offset=0;offset<510;offset=offset+2) send_half(7,offset);
        while(ioctl_wait) @(negedge clk);
        @(negedge clk7);run7=0;before_count=builtin_commits;
        send_half(7,510);
        @(negedge clk);ioctl_download=0;
        repeat(8) @(negedge clk);
        if(direct_profile_ready || !ioctl_wait || builtin_commits!=before_count)
            $fatal(1,"direct pages published before final config commit");
        command(3,0,flags,err);
        if(!hold_console || !fault) $fatal(1,"direct release escaped pending config write");
        command(1,0,flags,err);run7=1;end_asset;
        if(fault || !direct_profile_ready || builtin_commits!=before_count+1)
            $fatal(1,"direct final config commit did not resume");
        check_direct_profile;
        // Pause specifically between config capture and RAM commit: an ACK
        // at capture would publish a page whose last halfword is still stale.
        begin_asset(7);
        for(integer offset=0;offset<510;offset=offset+2) send_half(7,offset);
        while(ioctl_wait) @(negedge clk);
        before_count=builtin_commits;
        send_half(7,510);
        wait(builtin_we === 1'b1);
        @(posedge clk7);#1;run7=0;
        if(!cfg_pending || builtin_commits!=before_count)
            $fatal(1,"test did not stop between config capture and commit");
        @(negedge clk);ioctl_download=0;
        repeat(12) @(negedge clk);
        if(direct_profile_ready || !ioctl_wait || builtin_commits!=before_count)
            $fatal(1,"CONFIG_ACK_BEFORE_COMMIT: direct readiness escaped registered RAM write");
        run7=1;end_asset;
        if(fault || !direct_profile_ready || builtin_commits!=before_count+1)
            $fatal(1,"registered config commit did not finish after target clock resumed");
        check_direct_profile;
        command(2,0,flags,err);
        if(!hold_console || !fault) $fatal(1,"native boot accepted direct-only pages");
        command(1,0,flags,err);upload(6,120);
        if(direct_profile_ready) $fatal(1,"native upload retained direct profile readiness");
        check_profile;
        $display("PASS: FIO7 exact pages, generated metadata, loader/SPI parity, mode separation and delayed config acknowledgement");
        $display("PASS: RAM_SIMULATE=%0d control protocol, full BIOS CDC across independent clocks, hold gating, length checks, retry, profile and commit/flush",RAM_SIMULATE);

        // Closing a complete upload cannot publish readiness until its final
        // halfword has actually reached the target RAM clock domain.
        begin_asset(5);
        for(integer offset=0;offset<4094;offset=offset+2) send_half(5,offset);
        while(ioctl_wait) @(negedge clk);
        @(negedge clk9);run9=0;before9=writes9;
        send_half(5,4094);
        @(negedge clk);ioctl_download=0;
        repeat(8) @(negedge clk);
        if(!ioctl_wait || bios9_ready || writes9!=before9)
            $fatal(1,"pending ARM9 final write published readiness before RAM sampled it");
        command(2,0,flags,err);
        if(!hold_console || !fault || err!==2)
            $fatal(1,"native release escaped pending final BIOS write");
        command(1,0,flags,err);
        run9=1;end_asset;
        if(!bios9_ready || fault || writes9!=before9+1)
            $fatal(1,"pending final BIOS write did not finish after target clock resumed");
        command(2,0,flags,err);
        if(hold_console || !native_mode || fault)
            $fatal(1,"native release failed after the final target RAM write");
        command(1,0,flags,err);
        $display("PASS: final BIOS CDC acknowledgement gates readiness and native release");

        // Last halfword outside download must not make an incomplete profile
        // ready: payload RAM itself correctly gates stores with download.
        begin_asset(6);
        for(integer offset=0;offset<118;offset=offset+2) send_half(6,offset);
        @(negedge clk);ioctl_download=0;ioctl_wr=1;ioctl_addr=118;ioctl_dout=16'hdead;
        @(negedge clk);ioctl_wr=0;
        repeat(8) @(negedge clk);
        if(profile_ready || !fault)
            $fatal(1,"OUTSIDE_DOWNLOAD_ACCEPTED: profile_ready=%b fault=%b received=%0d; final halfword was not stored",profile_ready,fault,dut.received);
        check_profile;
        $display("PASS: outside-download final word rejected");
        $finish;
    end
    initial begin #20000000;$fatal(1,"testbench timeout");end
endmodule
