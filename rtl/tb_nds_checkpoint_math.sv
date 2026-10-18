// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_checkpoint_math;
    parameter bit PRODUCT = 1;
    logic clk=0, reset=1, request=0, read_not_write=1;
    logic [7:0] cycle_advance=1;
    logic cycle_advance_valid=1;
    logic [31:0] address=0, write_data=0;
    logic [1:0] access=2;
    wire selected,done,div_busy,sqrt_busy,checkpoint_idle;
    wire [31:0] read_data;
    wire ref_selected,ref_done,ref_div_busy,ref_sqrt_busy;
    wire [31:0] ref_read_data;
    always #5 clk=~clk;
    nds_nitro_arm9_math_unit #(.COMBINATIONAL_READ(PRODUCT)) dut(.*);
    nds_nitro_arm9_math_unit_reference #(.COMBINATIONAL_READ(PRODUCT)) reference_math(
        .clk(clk),.reset(reset),.request(request),.read_not_write(read_not_write),
        .cycle_advance(cycle_advance),.cycle_advance_valid(cycle_advance_valid),
        .address(address),.write_data(write_data),.access(access),
        .selected(ref_selected),.done(ref_done),.div_busy(ref_div_busy),
        .sqrt_busy(ref_sqrt_busy),.read_data(ref_read_data));
    // State visible after restoring a drained unit. Microengine scratch is
    // dormant once completion is retired, but live registers must be stable.
    wire [415:0] live_state={dut.div_cnt,dut.div_numerator,dut.div_denominator,
        dut.div_quotient,dut.div_remainder,dut.sqrt_cnt,dut.sqrt_parameter,
        dut.sqrt_result,dut.registered_read_data};
    integer compared=0,stable_checks=0,reply_checks=0,work_checks=0;
    logic before_idle;
    logic [415:0] before_state;
    always @(clk) begin
        #1;
        if ({selected,done,div_busy,sqrt_busy,read_data} !==
            {ref_selected,ref_done,ref_div_busy,ref_sqrt_busy,ref_read_data})
            $fatal(1,"math observer changed original behavior");
        compared=compared+1;
        if ((reset || request) && checkpoint_idle)
            $fatal(1,"math idle during reset/admission");
        if (!reset && !request && (done || dut.bus_response_pending)) begin
            reply_checks=reply_checks+1;
            if (checkpoint_idle) $fatal(1,"math idle before MMIO reply retired");
        end
        if (!reset && !request && (div_busy || sqrt_busy)) begin
            work_checks=work_checks+1;
            if (checkpoint_idle) $fatal(1,"math idle before arithmetic retired");
        end
    end
    always @(posedge clk) begin
        before_idle=checkpoint_idle;
        before_state=live_state;
        #2;
        if (before_idle && !reset && !request) begin
            stable_checks=stable_checks+1;
            if (!checkpoint_idle || before_state !== live_state)
                $fatal(1,"math idle was not a stable capture boundary");
        end
    end
    task automatic ticks(input integer n=1);
        repeat(n) @(negedge clk);
    endtask
    task automatic access_once(input logic [31:0] a,input logic wr,
                               input logic [31:0] d=0,input integer span=1);
        address=a;read_not_write=!wr;write_data=d;request=1;
        ticks(span);request=0;ticks(3);
    endtask
    task automatic drain;
        integer n;
        begin
            n=0;
            while (!checkpoint_idle && n<100) begin ticks();n=n+1;end
            if (!checkpoint_idle) $fatal(1,"math failed to drain with real credits");
            ticks(4);
        end
    endtask
    integer n;
    logic [31:0] rng=32'h137;
    initial begin
        ticks(4);reset=0;ticks();
        if (!checkpoint_idle) $fatal(1,"empty math unit not idle");
        // No arithmetic: a one-edge read still owes its delayed response.
        access_once(32'h040002a0,0);
        drain();
        // Hold the request after the response, then release the level guard.
        access_once(32'h040002b4,0,0,7);drain();
        // Signature tail exists even for an unselected transaction.
        access_once(32'h04000130,0);drain();
        // Engine finishes physically while zero/invalid cycle credits retain
        // architectural BUSY. Suspend cannot supply fabricated time credits.
        cycle_advance=0;
        access_once(32'h04000290,1,100);
        access_once(32'h04000298,1,7);
        access_once(32'h040002b8,1,123456);
        ticks(100);
        if (!div_busy || !sqrt_busy || checkpoint_idle)
            $fatal(1,"zero-credit arithmetic prematurely drained");
        cycle_advance=255;cycle_advance_valid=0;ticks(40);
        if (!div_busy || !sqrt_busy || checkpoint_idle)
            $fatal(1,"invalid credits retired arithmetic");
        cycle_advance_valid=1;drain();
        if (dut.div_quotient!=14 || dut.div_remainder!=2 || dut.sqrt_result!=351)
            $fatal(1,"drained results changed");
        cycle_advance=1;
        // Actual product DMA holds ena across changing transaction signatures.
        if (PRODUCT) begin
            request=1;address=32'h04000290;read_not_write=1;ticks(2);
            address=32'h04000298;write_data=9;read_not_write=0;ticks(2);
            address=32'h04000130;read_not_write=1;ticks(2);
            address=32'h04000298;write_data=11;read_not_write=0;ticks(2);
            request=0;drain();
            if (dut.div_denominator!=11 || dut.div_quotient!=9 || dut.div_remainder!=1)
                $fatal(1,"continuous-ena math transactions lost");
        end
        // Vary concurrent arithmetic, response tails, restart writes and
        // credit stalls. The immutable pre-observer implementation is oracle.
        for(n=0;n<200;n=n+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            cycle_advance={6'd0,rng[1:0]};cycle_advance_valid=rng[3];
            case(n%8)
                0: access_once(32'h04000290,1,rng);
                1: access_once(32'h04000294,1,rng);
                2: access_once(32'h04000298,1,rng);
                3: access_once(32'h04000280,1,{30'd0,rng[1:0]});
                4: access_once(32'h040002b8,1,rng);
                5: access_once(32'h040002bc,1,rng);
                6: access_once(32'h040002b0,1,{31'd0,rng[0]});
                7: access_once(32'h040002a0,0);
            endcase
            ticks(rng[6:4]);
            if(n%11==0) begin cycle_advance=1;cycle_advance_valid=1;drain();end
        end
        cycle_advance=1;cycle_advance_valid=1;drain();
        reset=1;ticks(2);reset=0;drain();
        if (compared<3000 || stable_checks<80 || reply_checks<100 || work_checks<1000)
            $fatal(1,"math coverage vacuous compared=%0d stable=%0d reply=%0d work=%0d",
                compared,stable_checks,reply_checks,work_checks);
        $display("CHECKPOINT_MATH_PASS product=%0d compared_phases=%0d stable=%0d reply=%0d work=%0d",
            PRODUCT,compared,stable_checks,reply_checks,work_checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"math checkpoint watchdog");end
endmodule
