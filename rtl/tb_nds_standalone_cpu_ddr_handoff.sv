module tb_nds_standalone_cpu_ddr_handoff;
    logic clk=0,reset=1,enable=0; always #5 clk=~clk;
    logic request=0,done,rd,we,busy,ready;
    logic [31:0] read_data;
    logic [7:0] burst,be;
    logic [28:0] address;
    logic [63:0] din,dout;

    logic boot_valid,boot_error;
    logic [31:0] generation,dtcm_vector,trace_trigger,entry9,entry7,sp9,irq9,saved9;
    logic [31:0] sp7,irq7,saved7,cpsr;
    logic video_busy,video_ready;
    logic ddram_rd,ddram_we,ddram_busy=0,ddram_ready=0;
    logic [7:0] ddram_burst,ddram_be;
    logic [28:0] ddram_addr;
    logic [63:0] ddram_din,ddram_dout=0;
    logic [31:0] descriptor[0:15];
    logic oracle_request,oracle_rnw,oracle_done=0;
    logic [31:0] oracle_address,oracle_wdata;
    logic [1:0] oracle_access;
    integer remaining=0,index=0,cpu_commands=0;

    nds_cpu_memory_router cpu_path (
        .clk,.reset(reset|!boot_valid),.request,.address(32'h02004800),
        .cpu_is_arm9(1'b1),.wramcnt(2'd3),
        .arm9_dtcm_region(32'h0300000a),.arm9_dtcm_enable(1'b1),
        .arm9_dtcm_seed_valid(boot_valid),
        .arm9_dtcm_irq_vector(dtcm_vector),
        .read_not_write(1'b1),.access(2'b10),.write_data(32'd0),
        .read_data,.done,
        .oracle_request,.oracle_address,
        .oracle_read_not_write(oracle_rnw),.oracle_access,
        .oracle_write_data(oracle_wdata),.oracle_read_data(32'd0),
        .oracle_done,
        .ddram_read(rd),.ddram_write(we),
        .ddram_burst_count(burst),.ddram_address(address),
        .ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),
        .ddram_read_data_ready(ready));

    nds_standalone_boot_ddr shared (
        .clk,.reset,.enable,.boot_valid,.boot_error,
        .boot_generation(generation),.arm9_dtcm_irq_vector(dtcm_vector),
        .arm9_trace_trigger(trace_trigger),
        .arm9_entry(entry9),.arm7_entry(entry7),.arm9_current_sp(sp9),
        .arm9_irq_sp(irq9),.arm9_saved_sp(saved9),.arm7_current_sp(sp7),
        .arm7_irq_sp(irq7),.arm7_saved_sp(saved7),.initial_cpsr(cpsr),
        .cpu_rd(rd),.cpu_we(we),.cpu_burstcnt(burst),.cpu_addr(address),
        .cpu_din(din),.cpu_be(be),.cpu_busy(busy),.cpu_dout(dout),
        .cpu_dout_ready(ready),
        .video_rd(1'b0),.video_we(1'b0),.video_burstcnt(8'd1),
        .video_addr(29'd0),.video_din(64'd0),.video_be(8'hff),
        .video_busy,.video_dout(),.video_dout_ready(video_ready),
        .ddram_rd,.ddram_we,.ddram_burstcnt(ddram_burst),
        .ddram_addr,.ddram_din,.ddram_be,.ddram_busy,
        .ddram_dout,.ddram_dout_ready(ddram_ready));

    always @(posedge clk) begin
        ddram_ready<=0;
        if(ddram_rd) begin
            if(ddram_addr==29'h05800200) begin
                remaining<=8; index<=0;
            end else if(ddram_addr==29'h05800201) begin
                remaining<=1; index<=8;
            end else if(ddram_addr==29'h05820900) begin
                remaining<=1; index<=9; cpu_commands<=cpu_commands+1;
            end else $fatal(1,"unexpected DDR read %h",ddram_addr);
        end else if(remaining>0) begin
            if(index==8) ddram_dout<={descriptor[3],descriptor[2]};
            else if(index==9) ddram_dout<=64'h11223344e3a00301;
            else ddram_dout<={descriptor[index*2+1],descriptor[index*2]};
            ddram_ready<=1; remaining<=remaining-1; index<=index+1;
        end
    end

    initial begin
        fork begin
            repeat(1000) @(posedge clk);
            $fatal(1,"timeout boot=%0d error=%0d request=%0d rd=%0d busy=%0d arb_sel_b=%0d arb_pending=%0d dwell=%0d",
                boot_valid,boot_error,request,rd,busy,
                shared.arbiter.selected_b,shared.arbiter.read_pending,
                shared.arbiter.grant_dwell);
        end join_none
        descriptor[0]=32'h4253444e; descriptor[1]=3;
        descriptor[2]=1; descriptor[3]=32'h01ffd5ec;
        descriptor[4]=32'h00400000; descriptor[5]=32'h02064eb4;
        descriptor[6]=32'h02004800; descriptor[7]=32'h02380000;
        descriptor[8]=32'h03002f7c; descriptor[9]=32'h03003f80;
        descriptor[10]=32'h03003fc0; descriptor[11]=32'h0380fd80;
        descriptor[12]=32'h0380ff80; descriptor[13]=32'h0380ffc0;
        descriptor[14]=32'h000000d3; descriptor[15]=32'h3ac5bac9;
        repeat(3) @(posedge clk); reset=0; enable=1;
        wait(boot_valid);
        if(dtcm_vector!==32'h01ffd5ec)
            $fatal(1,"DTCM IRQ vector lost at CPU handoff");
        if(trace_trigger!==32'h02064eb4)
            $fatal(1,"runtime ARM9 trace trigger lost at CPU handoff");
        @(negedge clk); request=1;
        wait(done); #1;
        if(oracle_request||read_data!==32'he3a00301||cpu_commands!=1)
            $fatal(1,"first production CPU path failed oracle=%0d data=%h commands=%0d",
                oracle_request,read_data,cpu_commands);
        $display("PASS: real DS entry address survives router and boot DDR ownership handoff");
        $finish;
    end
endmodule
