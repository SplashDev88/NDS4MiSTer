module nds_color_compositor (
    input  logic [31:0] val1,
    input  logic [31:0] val2,
    input  logic [15:0] blend_cnt,
    input  logic [4:0]  eva,
    input  logic [4:0]  evb,
    input  logic [4:0]  evy,
    input  logic        window_effect_enable,
    output logic [31:0] result
);
    logic [7:0] flag1, flag2;
    logic [15:0] target2;
    logic [2:0] effect;
    logic [5:0] r1,g1,b1,r2,g2,b2,ro,go,bo;
    logic [5:0] blend_eva, blend_evb;
    logic [7:0] first_target;

    function automatic [5:0] clamp6(input integer value);
        clamp6 = value > 63 ? 6'd63 : value[5:0];
    endfunction
    function automatic [5:0] blend4(input [5:0] a,input [5:0] b,input [5:0] ca,input [5:0] cb);
        blend4 = clamp6((a*ca+b*cb+8)>>4);
    endfunction
    function automatic [5:0] blend5(input [5:0] a,input [5:0] b,input [5:0] ca,input [5:0] cb);
        blend5 = clamp6((a*ca+b*cb+16)>>5);
    endfunction
    function automatic [5:0] brighten(input [5:0] c,input [4:0] factor);
        brighten = c + (((63-c)*factor+8)>>4);
    endfunction
    function automatic [5:0] darken(input [5:0] c,input [4:0] factor);
        darken = c - ((c*factor+7)>>4);
    endfunction

    always_comb begin
        first_target=0;
        flag1=val1[31:24]; flag2=val2[31:24];
        r1=val1[5:0]; g1=val1[13:8]; b1=val1[21:16];
        r2=val2[5:0]; g2=val2[13:8]; b2=val2[21:16];
        target2 = flag2[7] ? 16'h1000 : (flag2[6] ? 16'h0100 : ({8'b0,flag2}<<8));
        effect=0; blend_eva={1'b0,eva}; blend_evb={1'b0,evb};
        if (flag1[7] && ((blend_cnt & target2)!=0)) begin
            effect=1;
            if (flag1[6]) begin blend_eva={1'b0,flag1[4:0]}; blend_evb=6'd16-{1'b0,flag1[4:0]}; end
        end else if (flag1[6] && ((blend_cnt & target2)!=0)) begin
            effect=4;
        end else begin
            first_target=flag1;
            if(flag1[7]) first_target=8'h10; else if(flag1[6]) first_target=8'h01;
            if (((blend_cnt & {8'b0,first_target})!=0) && window_effect_enable) begin
                effect={1'b0,blend_cnt[7:6]};
                if(effect==1 && ((blend_cnt & target2)==0)) effect=0;
            end
        end
        ro=r1; go=g1; bo=b1; result=val1;
        case(effect)
            1: begin ro=blend4(r1,r2,blend_eva,blend_evb); go=blend4(g1,g2,blend_eva,blend_evb); bo=blend4(b1,b2,blend_eva,blend_evb); result={8'hff,2'b0,bo,2'b0,go,2'b0,ro}; end
            2: begin ro=brighten(r1,evy); go=brighten(g1,evy); bo=brighten(b1,evy); result={8'hff,2'b0,bo,2'b0,go,2'b0,ro}; end
            3: begin ro=darken(r1,evy); go=darken(g1,evy); bo=darken(b1,evy); result={8'hff,2'b0,bo,2'b0,go,2'b0,ro}; end
            4: begin
                blend_eva={1'b0,flag1[4:0]}+1; blend_evb=6'd32-blend_eva;
                if(blend_eva!=32) begin ro=blend5(r1,r2,blend_eva,blend_evb); go=blend5(g1,g2,blend_eva,blend_evb); bo=blend5(b1,b2,blend_eva,blend_evb); result={8'hff,2'b0,bo,2'b0,go,2'b0,ro}; end
            end
            default: result=val1;
        endcase
    end
endmodule
