// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_checkpoint_math_restore;
    parameter bit PRODUCT=1;
    logic clk=0,reset=1,request=0,read_not_write=1;
    always #5 clk=~clk;
    logic [7:0] cycle_advance=1;
    logic cycle_advance_valid=1;
    logic [31:0] address=0,write_data=0;
    logic [1:0] access=2;
    wire selected,done,div_busy,sqrt_busy,checkpoint_idle;
    wire [31:0] read_data;
    logic [3:0] checkpoint_address=0;
    logic checkpoint_restore=0,checkpoint_write=0;
    logic [31:0] checkpoint_write_data=0;
    wire [31:0] checkpoint_data;
    wire checkpoint_valid,checkpoint_restore_ready,checkpoint_restore_error;
    wire rs,rd,rb,sb,ri;
    wire [31:0] rq;
    nds_nitro_arm9_math_unit #(.COMBINATIONAL_READ(PRODUCT),.EXPERIMENTAL_CHECKPOINT(1)) dut(.*);
    nds_nitro_arm9_math_unit_reference #(.COMBINATIONAL_READ(PRODUCT)) reference_math(
        .clk(clk),.reset(reset),.request(request),.read_not_write(read_not_write),.cycle_advance(cycle_advance),
        .cycle_advance_valid(cycle_advance_valid),.address(address),.write_data(write_data),.access(access),
        .selected(rs),.done(rd),.div_busy(rb),.sqrt_busy(sb),.read_data(rq),.checkpoint_idle(ri));
    bit restoring,recording=0,check_image=1;
    integer scenario=0,gap=0,state_file,trace_file,observations=0;
    logic [31:0] image[0:12];
    logic [36:0] actual,expected;
    logic [31:0] rng;
    logic [63:0] numerator,denominator,parameter_value;
    logic [31:0] addresses[0:12];
    always @(clk) begin
        #1;
        if (!restoring && {selected,done,div_busy,sqrt_busy,read_data,checkpoint_idle} !== {rs,rd,rb,sb,rq,ri})
            $fatal(1,"math pinned baseline differs");
    end
    task automatic observe;
        integer count;
        if(recording) begin
            actual={selected,done,div_busy,sqrt_busy,read_data,checkpoint_idle};
            if(restoring) begin
                count=$fscanf(trace_file,"%h\n",expected);
                if(count!=1 || actual!==expected) $fatal(1,"math continuation mismatch step=%0d",observations);
            end else $fdisplay(trace_file,"%h",actual);
            observations=observations+1;
        end
    endtask
    task automatic ticks(input integer n=1);
        repeat(n) begin @(posedge clk);#2;observe();@(negedge clk);end
    endtask
    task automatic transact(input logic [31:0] a,input bit wr,input logic [31:0] value=0,input logic [1:0] size=2,input integer span=2);
        address=a;read_not_write=!wr;write_data=value;access=size;request=1;
        ticks(span);request=0;ticks(3);
    endtask
    task automatic drain;
        integer n;
        n=0;
        while(!checkpoint_idle && n<500) begin ticks();n=n+1;end
        if(!checkpoint_idle) $fatal(1,"math did not drain");ticks(2);
    endtask
    task automatic load_word(input integer a,input logic [31:0] value);
        checkpoint_address=a;checkpoint_write_data=value;checkpoint_write=1;ticks();
        checkpoint_write=0;ticks(1+gap*(1+a%3));
    endtask
    task automatic new_attempt;
        checkpoint_restore=0;ticks();checkpoint_restore=1;ticks();
        if(checkpoint_restore_ready) $fatal(1,"math stale coverage");
    endtask
    task automatic load_all;
        for(integer a=0;a<13;a=a+1) begin
            load_word(a,image[a]);
            if(a<12 && checkpoint_restore_ready) $fatal(1,"math partial restore accepted");
        end
        if(!checkpoint_restore_ready || checkpoint_restore_error) $fatal(1,"math complete restore not ready");
    endtask
    task automatic image_read;
        for(integer a=0;a<13;a=a+1) begin
            checkpoint_address=a;#1;
            if(!checkpoint_valid) $fatal(1,"math image unavailable");
            if(restoring) begin
                if(check_image && checkpoint_data!==image[a]) $fatal(1,"math restored word mismatch word=%0d",a);
            end else image[a]=checkpoint_data;
        end
        checkpoint_address=13;#1;
        if(checkpoint_valid || checkpoint_data!==0) $fatal(1,"math undefined word exposed data");
        @(negedge clk);
    endtask
    initial begin
        restoring=$test$plusargs("restore");check_image=!$test$plusargs("no-image-check");
        if($value$plusargs("scenario=%d",scenario)) begin end
        if($value$plusargs("gap=%d",gap)) begin end
        addresses[0]='h04000280;addresses[1]='h04000290;addresses[2]='h04000294;addresses[3]='h04000298;
        addresses[4]='h0400029c;addresses[5]='h040002a0;addresses[6]='h040002a4;addresses[7]='h040002a8;
        addresses[8]='h040002ac;addresses[9]='h040002b0;addresses[10]='h040002b4;addresses[11]='h040002b8;addresses[12]='h040002bc;
        ticks(4);
        if(restoring) begin
            state_file=$fopen("math.state","r");if(!state_file) $fatal(1,"math image missing");
            for(integer a=0;a<13;a=a+1) if($fscanf(state_file,"%h\n",image[a])!=1) $fatal(1,"math image truncated");
            if(!$feof(state_file)) $fatal(1,"math extra image records");$fclose(state_file);
            checkpoint_restore=1;ticks();load_all();image_read();
            load_word(13,0);if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"math extra word accepted");
            for(integer fault=0;fault<6;fault=fault+1) begin
                new_attempt();
                case(fault)
                    0: load_word(1,image[1]);
                    1: begin load_word(0,image[0]);load_word(0,image[0]);end
                    2: load_word(0,image[0]|32'h00008000);
                    3: load_word(0,image[0]|32'h80000000);
                    4: load_word(15,0);
                    5: begin request=1;ticks();request=0;ticks();end
                endcase
                if(!checkpoint_restore_error || checkpoint_restore_ready || checkpoint_valid) $fatal(1,"math invalid restore accepted");
                load_word(0,image[0]);if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"math poisoned restore recovered");
            end
            new_attempt();load_all();image_read();
            reset=0;checkpoint_restore=0;ticks(2);
            checkpoint_restore=1;load_word(0,0);
            if(!checkpoint_restore_error || checkpoint_restore_ready) $fatal(1,"math live restore accepted");
            checkpoint_restore=0;ticks();image_read();
            trace_file=$fopen("math.trace","r");
        end else begin
            reset=0;ticks(2);
            if(scenario!=0) begin
                numerator=64'h12345678fedcba98;denominator=64'h000000001234567;
                parameter_value=64'hfedcba9876543210;
                case(scenario)
                    1: begin numerator=100;denominator=7;parameter_value=123456;end
                    2: begin numerator=-100;denominator=7;end
                    3: begin numerator=64'h8000000000000000;denominator=-1;end
                    4: begin numerator=100;denominator=0;end
                    5: begin numerator=-100;denominator=0;end
                    6: begin numerator=64'h0000000080000000;denominator=64'h00000000ffffffff;end
                    7: begin numerator=64'h12345678fedcba98;denominator=64'h8000000000000000;end
                    8: begin numerator=-100;denominator=-7;parameter_value=64'hffffffffffffffff;end
                    9: begin numerator=64'h7fffffffffffffff;denominator=64'h123456789abcdef;end
                endcase
                transact(addresses[0],1,scenario==6 ? 0 : (scenario==3 ? 2 : (scenario%4)));
                transact(addresses[1],1,numerator[31:0]);transact(addresses[2],1,numerator[63:32]);
                transact(addresses[3],1,denominator[31:0]);transact(addresses[4],1,denominator[63:32]);
                transact(addresses[9],1,scenario%2);transact(addresses[11],1,parameter_value[31:0]);transact(addresses[12],1,parameter_value[63:32]);
                drain();
                if(scenario==1 && (dut.div_quotient!=14 || dut.div_remainder!=2 || dut.sqrt_result!=351)) $fatal(1,"math independent result wrong");
                if(scenario==3 && (dut.div_quotient!=64'h8000000000000000 || dut.div_remainder!=0)) $fatal(1,"math overflow result wrong");
                // Keep a nonzero registered read snapshot even with no reply outstanding.
                transact(addresses[scenario%13],0);drain();
            end
            address=0;access=2;read_not_write=1;write_data=0;ticks(2);image_read();
            state_file=$fopen("math.state","w");for(integer a=0;a<13;a=a+1) $fdisplay(state_file,"%h",image[a]);$fclose(state_file);
            trace_file=$fopen("math.trace","w");
        end
        if(!trace_file) $fatal(1,"math trace unavailable");
        recording=1;observe();ticks(2);
        // Observe all stored registers before restarting either arithmetic unit.
        for(integer a=0;a<13;a=a+1) begin
            transact(addresses[a],0);transact(addresses[a],0,0,1);transact(addresses[a]+1,0,0,0);
        end
        rng=32'h5a6231+scenario*7919;
        for(integer n=0;n<160;n=n+1) begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            cycle_advance=rng[7:0];cycle_advance_valid=rng[8];
            case(n%8)
                0: transact(addresses[1],1,rng);
                1: transact(addresses[3],1,rng);
                2: transact(addresses[0],1,rng,1);
                3: transact(addresses[11],1,rng);
                4: transact(addresses[12],1,rng);
                5: transact(addresses[9],1,rng,1);
                6: transact(addresses[5],0);
                7: transact(addresses[10],0);
            endcase
            if(n%13==0) begin cycle_advance=1;cycle_advance_valid=1;drain();end
        end
        cycle_advance=1;cycle_advance_valid=1;drain();
        // A repeated fixed destination with intervening unselected IO must
        // re-arm its signature, while a stable two-clock sample deduplicates.
        if(PRODUCT) begin
            request=1;address=addresses[3];read_not_write=0;write_data=7;ticks(2);
            address='h04000130;read_not_write=1;ticks(2);
            address=addresses[3];read_not_write=0;write_data=11;ticks(2);request=0;drain();
            if(dut.div_denominator[31:0]!=11) $fatal(1,"math signature did not rearm");
        end
        for(integer a=0;a<13;a=a+1) transact(addresses[a],0);
        if(restoring && !$feof(trace_file)) $fatal(1,"math extra trace records");$fclose(trace_file);
        $display("CHECKPOINT_MATH_RESTORE_PASS restoring=%0d product=%0d scenario=%0d gap=%0d observations=%0d",restoring,PRODUCT,scenario,gap,observations);$finish;
    end
    initial begin #10000000;$fatal(1,"math restore watchdog");end
endmodule
