module tb_nds_boot_descriptor_reader;
    logic clk=0,reset=1,enable=0;always #5 clk=~clk;
    logic valid,error,rd,busy=0,ready=0;
    logic [7:0] burst;logic [28:0] addr;
    logic [63:0] dout=0;
    logic [31:0] generation,dtcm_vector,trace_trigger,entry9,entry7,sp9,irq9,saved9;
    logic [31:0] sp7,irq7,saved7,cpsr;
    logic [31:0] descriptor[0:15];
    integer remaining=0,index=0;
    logic corrupt=0,stale=0;

    nds_boot_descriptor_reader #(.RETRY_DELAY_CYCLES(4)) dut(
        .clk,.reset,.enable,.valid,.format_error(error),
        .generation,.arm9_dtcm_irq_vector(dtcm_vector),
        .arm9_trace_trigger(trace_trigger),.arm9_entry(entry9),
        .arm7_entry(entry7),.arm9_current_sp(sp9),.arm9_irq_sp(irq9),
        .arm9_saved_sp(saved9),.arm7_current_sp(sp7),.arm7_irq_sp(irq7),
        .arm7_saved_sp(saved7),.initial_cpsr(cpsr),
        .ddram_read(rd),.ddram_burst_count(burst),.ddram_address(addr),
        .ddram_busy(busy),.ddram_read_data(dout),
        .ddram_read_data_ready(ready));

    always @(posedge clk) begin
        ready<=0;
        if(rd)begin
            if(addr==29'h05800200)begin remaining<=8;index<=0;end
            else if(addr==29'h05800201)begin
                remaining<=1;index<=8;
            end else $fatal(1,"unexpected descriptor address");
        end else if(remaining>0)begin
            if(index==8)begin
                dout<={descriptor[3],stale?32'd2:descriptor[2]};
            end else begin
                dout<={descriptor[index*2+1],
                       descriptor[index*2]^(corrupt&&index==3?32'h1:32'h0)};
            end
            ready<=1;remaining<=remaining-1;index<=index+1;
        end
    end

    task start_read;
        begin
            enable=0;reset=1;repeat(2)@(posedge clk);
            reset=0;enable=1;
        end
    endtask

    initial begin
        // Exact NSMB descriptor produced by StandaloneBoot.h.
        descriptor[0]=32'h4253444e;descriptor[1]=3;
        descriptor[2]=1;descriptor[3]=32'h01ffd5ec;
        descriptor[4]=32'h00400000;descriptor[5]=32'h02064eb4;
        descriptor[6]=32'h02000800;descriptor[7]=32'h02380000;
        descriptor[8]=32'h03002f7c;descriptor[9]=32'h03003f80;
        descriptor[10]=32'h03003fc0;descriptor[11]=32'h0380fd80;
        descriptor[12]=32'h0380ff80;descriptor[13]=32'h0380ffc0;
        descriptor[14]=32'h000000d3;descriptor[15]=32'hde5dada4;

        start_read();wait(valid||error);#1;
        if(error||!valid)begin
            for(integer dump=0;dump<16;dump=dump+1)
                $display("word[%0d]=%h",dump,dut.words[dump]);
            $fatal(1,"valid descriptor rejected crc=%h expected=%h fields=%b",
                ~dut.crc,descriptor[15],dut.fixed_fields_ok);
        end
        if(generation!==1||dtcm_vector!==32'h01ffd5ec||
           trace_trigger!==32'h02064eb4||
           entry9!==32'h02000800||entry7!==32'h02380000||
           sp9!==32'h03002f7c||irq9!==32'h03003f80||
           saved9!==32'h03003fc0||sp7!==32'h0380fd80||
           irq7!==32'h0380ff80||saved7!==32'h0380ffc0||
           cpsr!==32'hd3)$fatal(1,"descriptor field decode");

        corrupt=1;start_read();wait(valid||error);#1;
        if(!error||valid)$fatal(1,"corrupt descriptor accepted");
        corrupt=0;stale=1;start_read();wait(valid||error);#1;
        if(!error||valid)$fatal(1,"republished descriptor accepted");
        // A descriptor that was invalid because HPS had not yet published it
        // must recover automatically after the bounded retry interval.
        stale=0;corrupt=1;start_read();wait(error);#1;
        corrupt=0;wait(valid);#1;
        if(error||!valid)$fatal(1,"descriptor did not recover after publication");
        $display("PASS: boot descriptor CRC, decode, atomic generation, and retry");
        $finish;
    end
endmodule
