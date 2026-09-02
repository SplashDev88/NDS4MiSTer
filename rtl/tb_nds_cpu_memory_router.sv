module tb_nds_cpu_memory_router;
    logic clk=0,reset=1,request=0,rnw,cpu_is_arm9=1;always #5 clk=~clk;
    logic [1:0] wramcnt=3;
    logic [31:0] arm9_dtcm_region=32'h0300000a;
    logic arm9_dtcm_enable=1;
    logic arm9_dtcm_seed_valid=1;
    logic [31:0] arm9_dtcm_irq_vector=32'h01ffd5ec;
    logic [31:0] address,wdata,rdata;logic [1:0] access;logic done;
    logic oreq,ornw,odone=0;logic [31:0] oaddr,owdata,ordata=0;logic [1:0] oacc;
    logic rd,we,busy=0,ready=0;logic [7:0] burst,be;logic [28:0] daddr;
    logic [63:0] din,dout=0;
    // Exercise the production default so a future HPS/FPGA physical-address
    // mismatch is caught by the fast simulation gate.
    nds_cpu_memory_router dut(.*,
        .read_not_write(rnw),.write_data(wdata),.read_data(rdata),
        .oracle_request(oreq),.oracle_address(oaddr),.oracle_read_not_write(ornw),
        .oracle_access(oacc),.oracle_write_data(owdata),.oracle_read_data(ordata),
        .oracle_done(odone),.ddram_read(rd),.ddram_write(we),
        .ddram_burst_count(burst),.ddram_address(daddr),.ddram_write_data(din),
        .ddram_byte_enable(be),.ddram_busy(busy),.ddram_read_data(dout),
        .ddram_read_data_ready(ready));

    task begin_request(input [31:0] a,input bit is_read,input [1:0] size,input [31:0] value);
        @(negedge clk);address=a;rnw=is_read;access=size;wdata=value;request=1;
    endtask
    task end_request;@(negedge clk);request=0;@(posedge clk);endtask

    initial begin
        address=0;rnw=1;access=2'b10;wdata=0;
        repeat(3)@(posedge clk);reset=0;
        arm9_dtcm_seed_valid=0;

        // Direct-boot ARM9 ITCM is a 32 MiB aperture mirrored over 32 KiB.
        begin_request(32'h00000100,0,2'b10,32'h12345678);wait(done);
        if(oreq||rd||we)$fatal(1,"ARM9 ITCM write escaped locally");
        end_request();
        begin_request(32'h01000100,1,2'b10,0);wait(done);#1;
        if(rdata!==32'h12345678||oreq||rd||we)
            $fatal(1,"ARM9 ITCM mirror read %h",rdata);
        end_request();

        // Direct-boot DTCM occupies 16 KiB at 0x03000000.
        begin_request(32'h03000100,0,2'b10,32'h89abcdef);wait(done);
        if(oreq||rd||we)$fatal(1,"ARM9 DTCM write escaped locally");
        end_request();
        begin_request(32'h03000100,1,2'b10,0);wait(done);#1;
        if(rdata!==32'h89abcdef||oreq||rd||we)
            $fatal(1,"ARM9 DTCM read %h",rdata);
        end_request();

        // Firmware relocates the same physical DTCM into main-RAM address
        // space. It must take priority over DDR, and the old aperture must
        // stop selecting DTCM.
        arm9_dtcm_region=32'h027e000a;
        begin_request(32'h027e3ffc,1,2'b10,0);wait(done);#1;
        if(rdata!==32'h01ffd5ec||oreq||rd||we)
            $fatal(1,"seeded ARM9 DTCM IRQ vector %h",rdata);
        end_request();
        begin_request(32'h027e3fa0,0,2'b10,32'h0207ccc8);wait(done);
        if(oreq||rd||we)$fatal(1,"relocated ARM9 DTCM write escaped locally");
        end_request();
        begin_request(32'h027e3fa0,1,2'b10,0);wait(done);#1;
        if(rdata!==32'h0207ccc8||oreq||rd||we)
            $fatal(1,"relocated ARM9 DTCM read %h",rdata);
        end_request();

        // NSMB's filesystem helper copies a one-byte directory-entry length
        // into this exact relocated-DTCM stack address. Cover byte and
        // halfword lane merging here so the hardware probe's eventual stage
        // result has a matching fast regression at the production router.
        begin_request(32'h027e378c,0,2'b10,32'haabbccdd);wait(done);
        end_request();
        begin_request(32'h027e378c,0,2'b00,32'h00000007);wait(done);
        end_request();
        begin_request(32'h027e378c,1,2'b00,0);wait(done);#1;
        if(rdata!==32'h00000007||oreq||rd||we)
            $fatal(1,"relocated ARM9 DTCM byte read %h",rdata);
        end_request();
        begin_request(32'h027e378c,1,2'b10,0);wait(done);#1;
        if(rdata!==32'haabbcc07||oreq||rd||we)
            $fatal(1,"relocated ARM9 DTCM byte merge %h",rdata);
        end_request();
        begin_request(32'h027e378c,0,2'b01,32'h00000766);wait(done);
        end_request();
        begin_request(32'h027e378c,1,2'b01,0);wait(done);#1;
        if(rdata!==32'h00000766||oreq||rd||we)
            $fatal(1,"relocated ARM9 DTCM halfword read %h",rdata);
        end_request();

        begin_request(32'h03000100,1,2'b10,0);#1;
        if(!done||rdata!==0||oreq||rd||we)
            $fatal(1,"old ARM9 DTCM aperture remained active");
        end_request();

        // 0x02600024 mirrors to main-RAM offset 0x00200024.
        begin_request(32'h02600024,1,2'b10,0);wait(rd);
        if(oreq||daddr!==29'h05860004)$fatal(1,"main RAM mirror route %h",daddr);
        @(posedge clk);
        @(negedge clk);dout=64'hcafebabe11223344;ready=1;
        @(posedge clk);#1;if(!done||rdata!==32'hcafebabe)$fatal(1,"main RAM read");
        @(negedge clk);ready=0;request=0;@(posedge clk);

        // I/O must bypass DDR and retain the original oracle transaction.
        begin_request(32'h04000208,0,2'b10,32'h00000001);#1;
        if(!oreq||rd||we||oaddr!==32'h04000208||ornw||oacc!==2'b10||owdata!==1)$fatal(1,"oracle route");
        ordata=32'h55667788;odone=1;#1;
        if(!done||rdata!==32'h55667788)$fatal(1,"oracle response");
        @(negedge clk);odone=0;request=0;@(posedge clk);

        // Top main-RAM mirror maps to offset 0x003fffff and the correct byte lane.
        begin_request(32'h02ffffff,0,2'b00,32'h5a);wait(we);
        if(oreq||daddr!==29'h0589ffff||be!==8'h80||din!==64'h5a00000000000000)$fatal(1,"top mirror write");
        wait(done);end_request();

        // melonDS treats this upper unmapped cart aperture as zero-filled.
        // It must complete locally without touching DDR or the HPS oracle.
        begin_request(32'h0d3d085c,1,2'b10,0);#1;
        if(!done||rdata!==0||oreq||rd||we)
            $fatal(1,"zero-filled aperture route");
        end_request();

        // Direct boot starts with WRAMCNT=3: ARM7 owns all shared WRAM and
        // its 0x037f8000 entry mirror lands at shared-WRAM offset zero.
        cpu_is_arm9=0;
        begin_request(32'h00000000,1,2'b10,0);#1;
        if(!done||rdata!==32'hea00041c||oreq||rd||we)
            $fatal(1,"ARM7 local BIOS reset vector %h",rdata);
        end_request();
        begin_request(32'h0000115c,1,2'b10,0);#1;
        if(!done||rdata!==32'he2500001||oreq||rd||we)
            $fatal(1,"ARM7 local BIOS delay loop %h",rdata);
        end_request();
        begin_request(32'h037f805c,1,2'b10,0);wait(rd);
        if(oreq||daddr!==29'h0580200b)$fatal(1,"ARM7 shared WRAM route %h",daddr);
        @(posedge clk);
        @(negedge clk);dout=64'h11223344cafebabe;ready=1;
        @(posedge clk);#1;if(!done||rdata!==32'h11223344)
            $fatal(1,"ARM7 shared WRAM read done=%0d data=%h offset=%h",
                   done,rdata,dut.shared_wram_address);
        @(negedge clk);ready=0;request=0;@(posedge clk);

        // ARM7's 0x03800000 aperture is always its private 64 KiB WRAM.
        begin_request(32'h0380fd80,0,2'b10,32'h12345678);wait(we);
        if(oreq||daddr!==29'h05805fb0)$fatal(1,"ARM7 private WRAM route %h",daddr);
        wait(done);end_request();

        // With WRAMCNT=3 ARM9 has no shared-WRAM mapping.
        cpu_is_arm9=1;
        begin_request(32'h03005234,1,2'b10,0);#1;
        if(!done||rdata!==0||oreq||rd||we)$fatal(1,"ARM9 WRAMCNT=3 route");
        end_request();

        // WRAMCNT=1 gives ARM9 the upper 16 KiB and ARM7 the lower 16 KiB.
        wramcnt=1;
        begin_request(32'h03005234,1,2'b10,0);wait(rd);
        if(daddr!==29'h05802a46)$fatal(1,"ARM9 upper shared bank %h",daddr);
        @(posedge clk);
        @(negedge clk);dout=0;ready=1;@(posedge clk);
        @(negedge clk);ready=0;request=0;@(posedge clk);
        cpu_is_arm9=0;
        begin_request(32'h03005234,1,2'b10,0);wait(rd);
        if(daddr!==29'h05802246)$fatal(1,"ARM7 lower shared bank %h",daddr);
        @(posedge clk);
        @(negedge clk);dout=0;ready=1;@(posedge clk);
        @(negedge clk);ready=0;request=0;@(posedge clk);

        $display("PASS: ARM9 TCM, main/shared/ARM7 WRAM, and BIOS route locally while I/O routes to oracle");
        $finish;
    end
endmodule
