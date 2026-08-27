module tb_nds_standalone_boot_ddr;
    logic clk=0,reset=1,enable=0;always #5 clk=~clk;
    logic boot_valid,boot_error,cpu_rd=0,cpu_we=0,cpu_busy,cpu_ready;
    logic video_rd=0,video_we=0,video_busy,video_ready;
    logic ddram_rd,ddram_we,ddram_busy=0,ddram_ready=0;
    logic [7:0] cpu_burst=1,cpu_be=8'hff,video_burst=1,video_be=8'hff,ddram_burst;
    logic [28:0] cpu_addr=29'h123,video_addr=29'h600,ddram_addr;
    logic [63:0] cpu_din=0,video_din=64'h55,ddram_din,ddram_dout=0,cpu_dout,video_dout;
    logic [7:0] ddram_be;
    logic [31:0] generation,dtcm_vector,trace_trigger,entry9,entry7,sp9,irq9,saved9;
    logic [31:0] sp7,irq7,saved7,cpsr;
    logic [31:0] descriptor[0:15];
    integer remaining=0,index=0,video_writes=0,cpu_reads=0;
    logic response_cpu=0;

    nds_standalone_boot_ddr dut(
        .clk,.reset,.enable,.boot_valid,.boot_error,
        .boot_generation(generation),.arm9_dtcm_irq_vector(dtcm_vector),
        .arm9_trace_trigger(trace_trigger),
        .arm9_entry(entry9),.arm7_entry(entry7),.arm9_current_sp(sp9),
        .arm9_irq_sp(irq9),.arm9_saved_sp(saved9),.arm7_current_sp(sp7),
        .arm7_irq_sp(irq7),.arm7_saved_sp(saved7),.initial_cpsr(cpsr),
        .cpu_rd,.cpu_we,.cpu_burstcnt(cpu_burst),.cpu_addr,.cpu_din,.cpu_be,
        .cpu_busy,.cpu_dout,.cpu_dout_ready(cpu_ready),
        .video_rd,.video_we,.video_burstcnt(video_burst),.video_addr,
        .video_din,.video_be,.video_busy,.video_dout,
        .video_dout_ready(video_ready),
        .ddram_rd,.ddram_we,.ddram_burstcnt(ddram_burst),
        .ddram_addr,.ddram_din,.ddram_be,.ddram_busy,
        .ddram_dout,.ddram_dout_ready(ddram_ready));

    always @(posedge clk) begin
        ddram_ready<=0;
        if(ddram_we)begin
            if(ddram_addr!==29'h600||ddram_din!==64'h55)
                $fatal(1,"unexpected write during boot");
            video_writes<=video_writes+1;
        end
        if(ddram_rd)begin
            if(ddram_addr==29'h05800200)begin
                if(ddram_burst!==8)$fatal(1,"descriptor burst length");
                remaining<=8;index<=0;response_cpu<=0;
            end else if(ddram_addr==29'h05800201)begin
                remaining<=1;index<=8;response_cpu<=0;
            end else if(ddram_addr==29'h123)begin
                if(!boot_valid)$fatal(1,"CPU reached DDR before valid boot");
                remaining<=1;response_cpu<=1;cpu_reads<=cpu_reads+1;
            end else $fatal(1,"unexpected read address %h",ddram_addr);
        end else if(remaining>0)begin
            if(response_cpu)ddram_dout<=64'h1122334455667788;
            else if(index==8)ddram_dout<={descriptor[3],descriptor[2]};
            else ddram_dout<={descriptor[index*2+1],descriptor[index*2]};
            ddram_ready<=1;remaining<=remaining-1;index<=index+1;
        end
        if(cpu_ready&&!boot_valid)$fatal(1,"boot response leaked to CPU");
        if(video_ready)$fatal(1,"no video read was issued");
    end

    initial begin
        descriptor[0]=32'h4253444e;descriptor[1]=3;
        descriptor[2]=1;descriptor[3]=32'h01ffd5ec;
        descriptor[4]=32'h00400000;descriptor[5]=32'h02064eb4;
        descriptor[6]=32'h02000800;descriptor[7]=32'h02380000;
        descriptor[8]=32'h03002f7c;descriptor[9]=32'h03003f80;
        descriptor[10]=32'h03003fc0;descriptor[11]=32'h0380fd80;
        descriptor[12]=32'h0380ff80;descriptor[13]=32'h0380ffc0;
        descriptor[14]=32'h000000d3;descriptor[15]=32'hde5dada4;
        repeat(2)@(posedge clk);reset=0;enable=1;
        if(!cpu_busy)$fatal(1,"CPU not blocked before descriptor");

        // A video-side input publication competes during descriptor loading.
        // It must make progress without stealing any descriptor return beat.
        video_we=1;
        do @(posedge clk); while(!(ddram_we&&ddram_addr==29'h600));
        @(negedge clk);video_we=0;
        wait(boot_valid||boot_error);#1;
        if(boot_error||!boot_valid||video_writes!=1)
            $fatal(1,"boot/video arbitration failed: error=%0d valid=%0d writes=%0d generation=%08h",
                   boot_error,boot_valid,video_writes,generation);
        if(dtcm_vector!==32'h01ffd5ec)
            $fatal(1,"DTCM IRQ vector did not propagate through boot DDR");
        if(trace_trigger!==32'h02064eb4)
            $fatal(1,"runtime ARM9 trace trigger did not propagate");

        wait(!cpu_busy);@(negedge clk);cpu_rd=1;
        wait(ddram_rd&&ddram_addr==29'h123);@(negedge clk);cpu_rd=0;
        wait(cpu_ready);#1;
        if(cpu_dout!==64'h1122334455667788||cpu_reads!=1)
            $fatal(1,"post-boot CPU response routing");
        $display("PASS: video shares DDR during boot and ownership switches atomically to CPU");
        $finish;
    end
endmodule
