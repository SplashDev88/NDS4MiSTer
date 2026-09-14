// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_tate_video #(parameter integer TILE_ROWS=4, parameter integer CCW_ONLY=1);
    reg reset=1, i_clk=0, avl_clk=0, o_clk=0;
    always #8 i_clk=~i_clk;
    always #5 avl_clk=~avl_clk;
    always #7 o_clk=~o_clk;
    reg i_ce=0, i_de=0, i_vs=1;
    reg [23:0] i_rgb=0;
    reg [1:0] rotation=0;
    reg [9:0] source_width=16, source_height=16;
    reg o_vbl=0, pause_display=0;
    wire fb_enable, overflow;
    wire [1:0] rotation_applied;
    wire [9:0] fb_width, fb_height;
    wire [31:0] fb_base;
    wire [13:0] fb_stride;
    wire [27:0] wr_address;
    wire [127:0] wr_data;
    wire wr_valid, wr_ready;
    nds_tate_video #(.TILE_ROWS(TILE_ROWS),.CCW_ONLY(CCW_ONLY)) dut (.*);

    reg s_read=0, s_write=0;
    reg [27:0] s_address=28'h1000;
    reg [7:0] s_burstcount=4;
    reg [127:0] s_writedata=128'h1234;
    reg [15:0] s_byteenable=16'hffff;
    wire s_waitrequest, m_read, m_write;
    wire [27:0] m_address;
    wire [7:0] m_burstcount;
    wire [127:0] m_writedata;
    wire [15:0] m_byteenable;
    reg m_waitrequest=0, force_stall=0, traffic=0;
    nds_tate_scaler_arbiter #(.TATE_BEATS(TILE_ROWS/4)) arb (
        .clk(avl_clk), .reset,
        .s_read,.s_write,.s_address,.s_burstcount,.s_writedata,.s_byteenable,
        .s_waitrequest,.t_write(wr_valid),.t_address(wr_address),
        .t_writedata(wr_data),.t_ready(wr_ready),
        .m_read,.m_write,.m_address,.m_burstcount,.m_writedata,.m_byteenable,
        .m_waitrequest
    );
    reg [31:0] memory [0:786431];
    integer beats=0, base_word=0, remaining=0, writes=0, normal_beats=0;
    integer lane, address_word;
    integer vblank_clock=0, scaler_left=0, avl_count=0;
    reg stalled=0;
    reg [27:0] stalled_address;
    reg [127:0] stalled_data;
    reg [7:0] stalled_burst;
    reg [31:0] random_state=32'h83a24071;
    always @(negedge avl_clk) begin
        random_state = {random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        m_waitrequest = force_stall || (traffic && random_state[2:0] == 0);
        if (!reset && traffic) begin
            if (scaler_left == 0 && random_state[7:0] == 8'h91) scaler_left=4;
            s_write=scaler_left != 0;
            s_read=!s_write && random_state[5:3] == 0;
        end else begin s_write=0; s_read=0; end
    end
    always @(posedge avl_clk) if (!reset) begin
        avl_count=avl_count+1;
        if (stalled && (m_address !== stalled_address ||
            m_writedata !== stalled_data || m_burstcount !== stalled_burst || !m_write))
            $fatal(1,"write changed under backpressure");
        stalled=m_write && m_waitrequest;
        stalled_address=m_address; stalled_data=m_writedata; stalled_burst=m_burstcount;
        if (s_write && !s_waitrequest) begin scaler_left=scaler_left-1; normal_beats=normal_beats+1; end
        if (m_write && !m_waitrequest) begin
            if (remaining == 0) begin
                base_word=(m_address-28'h2400000)*4;
                beats=0; remaining=m_burstcount;
            end
            if (m_address >= 28'h2400000) begin
                if (m_burstcount != TILE_ROWS/4 || m_byteenable != 16'hffff)
                    $fatal(1,"rotation is not a full tile burst");
                if (fb_enable && ((m_address-28'h2400000)>>16) == dut.display_fb)
                    $fatal(1,"write overwrote the displayed frame");
                for(lane=0;lane<4;lane=lane+1) begin
                    address_word=base_word+beats*4+lane;
                    if(address_word<0 || address_word>=786432) $fatal(1,"write escaped reserved buffers");
                    memory[address_word]=m_writedata[lane*32+:32];
                end
                writes=writes+1;
            end
            beats=beats+1; remaining=remaining-1;
        end
        if (rotation == 0 && !wr_valid && !arb.t_second) begin
            if (m_read !== s_read || m_write !== s_write ||
                m_address !== s_address || m_writedata !== s_writedata ||
                s_waitrequest !== m_waitrequest)
                $fatal(1,"Off changed the scaler handshake");
        end
    end
    always @(negedge o_clk) begin
        if(pause_display) begin o_vbl=0; vblank_clock=0; end
        else begin
            vblank_clock=vblank_clock+1;
            if(vblank_clock==2000) o_vbl=1;
            if(vblank_clock==2100) begin o_vbl=0; vblank_clock=0; end
        end
    end
    function automatic [23:0] pattern(input integer x,y,id);
        reg [5:0] r,g,b;
        begin
            r=6'(x ^ (id*19));g=6'(y ^ (id*37));b=6'(x+y+id*7);
            pattern={r,r[5:4],g,g[5:4],b,b[5:4]};
        end
    endfunction
    function automatic [31:0] packed_pattern(input integer x,y,id);
        reg [23:0] p;
        begin p=pattern(x,y,id); packed_pattern={8'd0,p[7:0],p[15:8],p[23:16]}; end
    endfunction
    task automatic tick_pixel(input bit de, input bit vs, input [23:0] rgb);
        begin
            @(negedge i_clk); i_ce=1; i_de=de; i_vs=vs; i_rgb=rgb;
            @(negedge i_clk); i_ce=0;
            repeat(1) @(negedge i_clk);
        end
    endtask
    integer midframe_rotation = -1;
    task automatic frame(input integer w,h,id,rot);
        integer px,py;
        begin
            if(CCW_ONLY && rot==1) rot=2;
            rotation=rot; source_width=w; source_height=h;
            tick_pixel(0,0,0); tick_pixel(0,0,0); tick_pixel(0,1,0);
            for(py=0;py<h;py=py+1) begin
                for(px=0;px<w;px=px+1) begin
                    tick_pixel(1,1,pattern(px,py,id));
                    if(midframe_rotation >= 0 && py == h/2 && px == w/2)
                        rotation=midframe_rotation;
                end
                repeat(12) tick_pixel(0,1,0);
            end
            tick_pixel(0,1,0);
        end
    endtask
    task automatic verify_frame(input integer w,h,id,rot);
        integer dx,dy,sx,sy,base,t;
        reg [31:0] expected;
        begin
            if(CCW_ONLY && rot==1) rot=2;
            t=0;
            while((!fb_enable || rotation_applied!=rot ||
                memory[((fb_base-32'h24000000)>>2)] !==
                    (rot==1 ? packed_pattern(0,h-1,id) : packed_pattern(w-1,0,id))) && t<100000) begin
                @(negedge avl_clk);t=t+1;
            end
            if(t==100000) $fatal(1,"frame not published id=%0d mode=%0d overflow=%b",id,rot,overflow);
            if(fb_width!=h || fb_height!=w || fb_stride!=((h+TILE_ROWS-1)/TILE_ROWS)*(TILE_ROWS*4))
                $fatal(1,"bad geometry %0d x %0d stride %0d",fb_width,fb_height,fb_stride);
            base=(fb_base-32'h24000000)>>2;
            for(dy=0;dy<w;dy=dy+1) for(dx=0;dx<h;dx=dx+1) begin
                sx=rot==1 ? dy : w-1-dy;
                sy=rot==1 ? h-1-dx : dx;
                expected=packed_pattern(sx,sy,id);
                if(memory[base+dy*(fb_stride/4)+dx] !== expected)
                    $fatal(1,"pixel id=%0d rot=%0d dest=%0d,%0d src=%0d,%0d got=%h expected=%h",id,rot,dx,dy,sx,sy,memory[base+dy*(fb_stride/4)+dx],expected);
            end
            $display("PASS pixels %0dx%0d %s frame=%0d",w,h,rot==1?"CW ":"CCW",id);
        end
    endtask
    integer before_writes, id, h, rot, rgb;
    reg [31:0] previous_frame_base;
    reg [5:0] test_r,test_g,test_b;
    initial begin
        for(rgb=0;rgb<262144;rgb=rgb+1)begin
            test_r=rgb>>12;test_g=rgb>>6;test_b=rgb;
            if(dut.pixel_word(18'(rgb)) !== {8'd0,test_b,test_b[5:4],test_g,test_g[5:4],test_r,test_r[5:4]})
                $fatal(1,"native color roundtrip failed");
        end
        $display("PASS all 262144 native RGB666 colors roundtrip exactly");
        repeat(6) @(negedge i_clk);reset=0;traffic=1;
        frame(32,16,1,0);repeat(200) @(negedge avl_clk);
        if(writes!=0 || fb_enable) $fatal(1,"Off generated rotation traffic");
        id=2;
        for(rot=1;rot<=2;rot=rot+1) for(h=16;h<=23;h=h+1) begin
            frame(32,h,id,rot);verify_frame(32,h,id,rot);id=id+1;
        end
        // Both native maximum canvases must work in both directions, with
        // non-tile-aligned heights from gaps and the optional FPS overlay.
        for(rot=1;rot<=2;rot=rot+1) begin
            frame(536,198,id,rot);verify_frame(536,198,id,rot);id=id+1;
            frame(256,414,id,rot);verify_frame(256,414,id,rot);id=id+1;
        end
        if(!CCW_ONLY) begin
            // A menu change during capture must not publish a frame in the
            // old direction or mix the two transforms. Keep the old complete
            // picture until the next full frame in the requested direction.
            for(rot=1;rot<=2;rot=rot+1) begin
                frame(32,23,id,rot);verify_frame(32,23,id,rot);
                previous_frame_base=fb_base;
                midframe_rotation=3-rot;
                frame(32,23,id+1,rot);
                midframe_rotation=-1;
                repeat(10000) @(negedge avl_clk);
                if(fb_base != previous_frame_base || rotation_applied != rot)
                    $fatal(1,"mid-frame direction change published a stale transform");
                verify_frame(32,23,id,rot);
                id=id+2;
                frame(32,23,id,3-rot);verify_frame(32,23,id,3-rot);id=id+1;
            end
            $display("PASS both mid-frame direction changes hold the previous complete frame");
        end
        if(overflow) $fatal(1,"unexpected overflow with ordinary stalls");
        pause_display=1;
        frame(32,24,id,1);repeat(1000) @(negedge avl_clk);
        frame(32,24,id+1,1);repeat(1000) @(negedge avl_clk);
        frame(32,24,id+2,1);repeat(1000) @(negedge avl_clk);
        pause_display=0;verify_frame(32,24,id,1);
        id=id+3;frame(32,24,id,2);verify_frame(32,24,id,2);id=id+1;
        // Force the strip deadline to fail. The complete old frame must stay
        // visible, and recovery must replace every pixel before publication.
        force_stall=1;
        frame(32,48,id,1);
        if(!overflow) $fatal(1,"missed the deliberately late strip");
        force_stall=0;repeat(10000) @(negedge avl_clk);
        id=id+1;frame(32,24,id,1);verify_frame(32,24,id,1);
        rotation=0;frame(32,24,id+1,0);repeat(10000) @(negedge avl_clk);
        before_writes=writes;frame(32,24,id+2,0);
        if(writes!=before_writes || fb_enable) $fatal(1,"Off did not quiesce");
        if(normal_beats==0) $fatal(1,"no competing scaler bursts tested");
        $display("PASS TATE pixels, partial strips, stalls, no displayed-bank overwrite, recovery and zero Off traffic; normal beats=%0d",normal_beats);
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
