`timescale 1ns/1ps
module tb_nds_firmware_cache #(parameter bit RAM_SIMULATE=1);
    logic clk=0, guest_clk=0, guest_clock_run=1, reset=1;
    always #5 clk=~clk;
    always #7 if(guest_clock_run) guest_clk=~guest_clk;
    logic enable=1,img_mounted=0,img_readonly=0;
    logic [63:0] img_size=262144;
    logic [15:0] fw_addr=0;
    logic fw_req=0,fw_wr=0,fw_release=0;
    logic [1:0] fw_wlane=0;
    logic [7:0] fw_wdata=0;
    wire fw_done,fw_busy;
    wire [31:0] fw_data;
    logic flush_req=0,commit_ack=0;
    logic [15:0] commit_sequence=0;
    wire mounted,clean,persist_pending,fault;
    wire [15:0] persist_sequence;
    wire [31:0] sd_lba;
    wire sd_rd,sd_wr;
    logic sd_ack=0,sd_buff_wr=0;
    logic [12:0] sd_buff_addr=0;
    logic [15:0] sd_buff_dout=0;
    wire [15:0] sd_buff_din;
    nds_firmware_cache #(.SIMULATE(RAM_SIMULATE)) dut(.*);
    logic [15:0] disk[0:131071],outgoing[0:255];
    integer reads=0,writes=0,commits=0,refill_words=256,service_delay=13,rotate=0;
    integer outgoing_lba=0,tail_delay=0;
    logic auto_commit=0;
    integer fw_responses=0;
    always @(posedge guest_clk) if(fw_done) fw_responses<=fw_responses+1;
    task automatic check(input bit yes,input string why);
        if(!yes) $fatal(1,"%s @%t",why,$time);
    endtask
    task automatic commit_now(input logic [15:0] seq);
        @(negedge clk);
        if(seq==persist_sequence && persist_pending) begin
            for(integer k=0;k<256;k=k+1) disk[outgoing_lba*256+k]=outgoing[k];
            commits=commits+1;
        end
        commit_sequence=seq;commit_ack=1;
        @(negedge clk);commit_ack=0;
    endtask
    // Sector transport. Refill indices deliberately can begin at an arbitrary
    // shared hps_io address; ordered payload must still occupy a complete line.
    initial forever begin
        wait(!reset && (sd_rd || sd_wr));
        if(sd_rd) begin
            integer lba,n;
            lba=sd_lba;n=refill_words;
            repeat(service_delay) @(negedge clk);
            sd_ack=1;
            for(integer k=0;k<n;k=k+1) begin
                if(k==n-1 && tail_delay!=0) begin
                    sd_ack=0;sd_buff_wr=0;
                    repeat(tail_delay) @(negedge clk);
                end
                sd_buff_addr=(k+rotate)&255;
                sd_buff_dout=disk[lba*256+(k&255)];sd_buff_wr=1;
                @(negedge clk);
            end
            sd_buff_wr=0;sd_ack=0;reads=reads+1;
            wait(!sd_rd);
        end else begin
            outgoing_lba=sd_lba;
            repeat(service_delay) @(negedge clk);
            sd_ack=1;
            for(integer k=0;k<256;k=k+1) begin
                @(negedge clk);sd_buff_addr=k;
                @(posedge clk);#1;outgoing[k]=sd_buff_din;
            end
            @(negedge clk);sd_ack=0;writes=writes+1;
            wait(!sd_wr);
        end
        @(negedge clk);
    end
    initial forever begin
        wait(persist_pending);
        if(auto_commit) begin
            repeat(19) @(negedge clk);
            commit_now(persist_sequence);
        end
        wait(!persist_pending);
    end
    task automatic mount_image;
        @(negedge clk);img_mounted=1;
        @(negedge clk);img_mounted=0;
        repeat(7) @(negedge guest_clk);
        check(mounted && !fault,"mount failed");
    endtask
    task automatic clean_reset;
        @(negedge clk);reset=1;
        repeat(5) @(negedge clk);
        reset=0;
        repeat(8) @(negedge guest_clk);
        check(!fault,"clean reset retained fault");
        mount_image;
    endtask
    task automatic start_guest(input bit writing,input integer address,input integer lane,input logic[7:0] value,input bit release_cs=0);
        @(negedge guest_clk);
        fw_addr=address;fw_wlane=lane;fw_wdata=value;
        fw_wr=writing;fw_req=!writing;fw_release=release_cs;
        @(negedge guest_clk);fw_wr=0;fw_req=0;fw_release=0;
    endtask
    task automatic guest_done(output logic[31:0] value);
        integer timeout;
        timeout=0;
        while(!fw_done && timeout<20000) begin @(negedge guest_clk);timeout=timeout+1;end
        check(fw_done && !fault,"guest transaction stalled or faulted");
        value=fw_data;
        @(negedge guest_clk);
    endtask
    task automatic read_word(input integer address,input logic[31:0] wanted);
        logic[31:0] v;
        start_guest(0,address,0,0);guest_done(v);
        check(v==wanted,$sformatf("read %h got %h expected %h",address,v,wanted));
    endtask
    task automatic write_byte(input integer address,input integer lane,input logic[7:0] value,input bit release_cs=0);
        logic[31:0] unused;
        start_guest(1,address,lane,value,release_cs);guest_done(unused);
    endtask
    task automatic flush_all;
        @(negedge clk);flush_req=1;
        @(negedge clk);flush_req=0;
        wait(clean);repeat(5) @(negedge guest_clk);
        check(!fw_busy,"status stayed busy after durable flush");
    endtask
    initial begin
        logic [31:0] value;
        integer count_before;
        logic [15:0] saved_seq;
        for(integer i=0;i<131072;i=i+1) disk[i]=16'h1000^(i&16'hffff);
        repeat(7) @(negedge clk);reset=0;
        repeat(8) @(negedge guest_clk);mount_image;
        rotate=19;tail_delay=1;
        read_word(0,32'h10011000);count_before=reads;
        read_word(1,32'h10031002);check(reads==count_before,"cache hit refetched sector");
        tail_delay=0;
        // A release coincident with the write must wait for the byte response.
        write_byte(0,3,8'hab,1);wait(persist_pending);
        repeat(7) @(negedge guest_clk);
        check(!clean && fw_busy && dut.dirty!=0,"write falsely clean before durability");
        check(outgoing[1]==16'hab01,"writeback did not include last program byte");
        saved_seq=persist_sequence;
        commit_now(saved_seq-1);repeat(5) @(negedge clk);
        check(persist_pending && dut.dirty!=0,"stale commit discarded dirty data");
        // One request can wait safely while a background flush owns another line.
        count_before=fw_responses;start_guest(0,256,0,0);
        repeat(25) @(negedge guest_clk);
        check(fw_responses==count_before,"guest completed before durable eviction/flush");
        commit_now(saved_seq);guest_done(value);
        check(value==32'h12011200,"pending request used flushed line index");
        wait(clean);read_word(0,32'hab011000);
        for(integer lane=0;lane<4;lane=lane+1) write_byte(0,lane,8'h11*(lane+1));
        read_word(0,32'h44332211);
        auto_commit=1;
        read_word(512,32'h14011400); // same index, new tag: dirty eviction first
        check(disk[0]==16'h2211 && disk[1]==16'h4433,"eviction lost byte lanes");
        for(integer line_index=0;line_index<4;line_index=line_index+1)
            write_byte(line_index*128,0,8'h70+line_index);
        @(negedge clk);enable=0;repeat(5) @(negedge clk);
        check(!clean && dut.dirty!=0,"disable hid uncommitted writes");
        enable=1;flush_all;
        for(integer line_index=0;line_index<4;line_index=line_index+1)
            check(disk[line_index*256][7:0]==8'h70+line_index,"flush lost dirty sector");
        // Reset with dirty bytes faults visibly but preserves them for recovery.
        write_byte(0,1,8'h5a);
        @(negedge clk);reset=1;repeat(5) @(negedge clk);reset=0;
        repeat(8) @(negedge guest_clk);
        check(fault && dut.dirty!=0 && !clean,"dirty reset silently lost state");
        @(negedge clk);flush_req=1;@(negedge clk);flush_req=0;
        wait(dut.dirty==0 && dut.state==0);repeat(8) @(negedge clk);
        check(disk[0][15:8]==8'h5a && fault,"fault recovery did not persist retained bytes");
        clean_reset;read_word(0,32'h44335a70);
        // Short and oversized sectors never become valid and never acknowledge.
        for(integer short_case=0;short_case<2;short_case=short_case+1) begin
            clean_reset;refill_words=short_case==0?255:257;
            count_before=fw_responses;start_guest(0,128,0,0);
            wait(fault && !sd_rd);repeat(8) @(negedge guest_clk);
            check(dut.valid==0 && fw_responses==count_before,"partial/oversized sector escaped validation");
        end
        refill_words=256;clean_reset;
        // A second pulse cannot overwrite the payload of an outstanding request.
        service_delay=80;count_before=fw_responses;
        start_guest(0,0,0,0);start_guest(0,512,0,0);
        wait(fault && !sd_rd);repeat(8) @(negedge guest_clk);
        check(fw_responses==count_before,"mailbox overrun acknowledged corrupt payload");
        service_delay=13;clean_reset;
        read_word(0,32'h44335a70);
        check(dut.req_toggle==1,"stopped-clock case needs nonzero old toggle");
        count_before=fw_responses;
        // Reset assertion while the guest clock is stopped still re-aligns CDC.
        @(negedge guest_clk);guest_clock_run=0;
        @(negedge clk);reset=1;repeat(5) @(negedge clk);reset=0;
        repeat(5) @(negedge clk);guest_clock_run=1;
        repeat(8) @(negedge guest_clk);mount_image;
        check(fw_responses==count_before,"stopped clock caused phantom response");
        read_word(0,32'h44335a70);
        check(!fault,"CDC reset left a phantom request");
        // A commit is valid only after its sector transport has completed.
        auto_commit=0;write_byte(0,2,8'hb6,1);wait(sd_wr);
        saved_seq=persist_sequence;commit_now(saved_seq);
        wait(persist_pending);repeat(5) @(negedge clk);
        check(dut.dirty!=0 && fw_busy,"early commit acknowledged an incomplete sector");
        // Even a fabric reset cannot discard a transferred but uncommitted line.
        @(negedge clk);reset=1;repeat(5) @(negedge clk);reset=0;
        repeat(8) @(negedge guest_clk);
        check(fault && persist_pending && persist_sequence==saved_seq && dut.dirty!=0,
            "reset discarded pending durable commit");
        commit_now(saved_seq);wait(dut.dirty==0 && dut.state==0);
        check(disk[1][7:0]==8'hb6,"reset/commit recovery lost program byte");
        clean_reset;
        // Replacing the mounted image while dirty must fail without losing it.
        write_byte(0,3,8'hc7);
        @(negedge clk);img_mounted=1;@(negedge clk);img_mounted=0;
        repeat(5) @(negedge clk);
        check(fault && dut.dirty!=0 && !clean,"remount discarded dirty firmware");
        auto_commit=1;
        @(negedge clk);flush_req=1;@(negedge clk);flush_req=0;
        wait(dut.dirty==0 && dut.state==0);
        check(disk[1][15:8]==8'hc7,"failed remount lost retained byte");
        clean_reset;
        // Native firmware media must be writable and exactly 256 KiB.
        for(integer bad_image=0;bad_image<2;bad_image=bad_image+1) begin
            @(negedge clk);reset=1;repeat(5) @(negedge clk);reset=0;
            repeat(8) @(negedge guest_clk);
            img_readonly=bad_image==0;img_size=bad_image==0?262144:131072;
            @(negedge clk);img_mounted=1;@(negedge clk);img_mounted=0;
            repeat(5) @(negedge clk);
            check(fault && !mounted && !clean,"invalid firmware media was accepted");
        end
        $display("PASS: firmware cache RAM_SIMULATE=%0d async CDC, cache hits/misses, all byte lanes, durable eviction/flush, stale/early ack, dirty/inflight reset, remount guard, sector/media validation and overrun (%0d reads/%0d writes/%0d commits)",RAM_SIMULATE,reads,writes,commits);
        $finish;
    end
    initial begin #3000000;$fatal(1,"cache test timeout state=%0d dirty=%b fault=%b",dut.state,dut.dirty,fault);end
endmodule
