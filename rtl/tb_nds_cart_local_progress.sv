// SPDX-License-Identifier: GPL-3.0-or-later
// Real cartridge read-ahead controller and H3D fabric, with a saturated
// accelerator peer. Early cartridge replies immediately request another
// cache miss, so an idle controller cycle is not an idle cartridge client.
`timescale 1ns/1ps
module tb_nds_cart_local_progress #(parameter PRIORITY=1, OUTER_PRIORITY=1, EVENTS=0);
    reg clk=0, reset=1;
    always #8.333 clk=~clk;
    reg cart_req=0, scan_req=0;
    reg [27:1] cart_addr=0, scan_addr=27'h7f00000;
    wire cart_ready, scan_ready, scan_valid;
    wire scan_pending;
    wire [31:0] cart_data;
    wire [63:0] scan_data;
    wire legacy_rd,legacy_we,legacy_busy,legacy_valid;
    wire [7:0] legacy_burst,legacy_be;
    wire [28:0] legacy_addr;
    wire [63:0] legacy_din,legacy_dout;
    ddram #(.CART_WIDE_BANK(1),.SCANOUT_READ_PRIORITY(PRIORITY)) legacy (
        .DDRAM_CLK(clk),.DDRAM_BUSY(legacy_busy),.DDRAM_BURSTCNT(legacy_burst),
        .DDRAM_ADDR(legacy_addr),.DDRAM_DOUT(legacy_dout),
        .DDRAM_DOUT_READY(legacy_valid),.DDRAM_RD(legacy_rd),
        .DDRAM_DIN(legacy_din),.DDRAM_BE(legacy_be),.DDRAM_WE(legacy_we),
        .ch1_addr(27'd0),.ch1_req(1'b0),.ch1_rnw(1'b1),.ch1_din(16'd0),
        .ch1_dout(),.ch1_ready(),
        .ch2_addr(cart_addr),.ch2_altbank(1'b0),.ch2_req(cart_req),
        .ch2_rnw(1'b1),.ch2_din(32'd0),.ch2_dout(cart_data),.ch2_ready(cart_ready),
        .ch3_addr(27'd0),.ch3_req(1'b0),.ch3_rnw(1'b1),.ch3_be(8'd0),
        .ch3_din(64'd0),.ch3_dout(),.ch3_ready(),.ch3_burst(8'd1),.ch3_valid(),
        .ch4_addr(27'd0),.ch4_req(1'b0),.ch4_rnw(1'b1),.ch4_be(8'd0),
        .ch4_din(64'd0),.ch4_dout(),.ch4_ready(),
        .ch5_addr(27'd0),.ch5_req(1'b0),.ch5_burst(8'd128),
        .ch5_din(64'd0),.ch5_next(),.ch5_ready(),
        .ch6_addr(scan_addr),.ch6_req(scan_req),.ch6_burst(8'd128),
        .ch6_dout(scan_data),.ch6_valid(scan_valid),.ch6_ready(scan_ready),
        .ch6_pending(scan_pending)
    );
    reg accelerator_pending=1, accelerator_receiving=0;
    wire accelerator_busy,accelerator_valid;
    wire [63:0] accelerator_data;
    integer accelerator_beat=0,accelerator_completed=0;
    reg event_pending=1, event_stream=0;
    wire event_busy, event_accepted;
    integer event_completed=0, event_beat=0, event_words=0;
    wire [63:0] event_data=64'(event_completed*8+event_beat);

    wire rd,wr,protocol_error;
    wire [7:0] burst,be;
    wire [28:0] addr;
    wire [63:0] din;
    reg busy=1,valid=0;
    reg [63:0] dout=0;
    nds_h3d_ddr_fabric fabric (
        .clk,.reset,.legacy_scanout_pending(OUTER_PRIORITY && scan_pending),
        .legacy_read(legacy_rd),.legacy_write(legacy_we),
        .legacy_burst_count(legacy_burst),.legacy_address(legacy_addr),
        .legacy_write_data(legacy_din),.legacy_byte_enable(legacy_be),
        .legacy_busy,.legacy_command_accepted(),.legacy_read_data(legacy_dout),
        .legacy_read_data_ready(legacy_valid),
        .plane_read(1'b0),.plane_write(1'b0),.plane_burst_count(8'd1),
        .plane_address(29'd0),.plane_write_data(64'd0),.plane_byte_enable(8'd0),
        .plane_busy(),.plane_command_accepted(),.plane_read_data(),.plane_read_data_ready(),
        .event_read(1'b0),.event_write(EVENTS && (event_pending || event_stream)),.event_burst_count(8'd8),
        .event_address(29'h07f01000),.event_write_data(event_data),.event_byte_enable(8'hff),
        .event_busy(event_busy),.event_command_accepted(event_accepted),.event_read_data(),.event_read_data_ready(),
        .control_read(accelerator_pending),.control_write(1'b0),
        .control_burst_count(8'd128),.control_address(29'h07f80000),
        .control_write_data(64'd0),.control_byte_enable(8'hff),
        .control_busy(accelerator_busy),.control_command_accepted(),
        .control_read_data(accelerator_data),.control_read_data_ready(accelerator_valid),
        .ddram_read(rd),.ddram_write(wr),.ddram_burst_count(burst),
        .ddram_address(addr),.ddram_write_data(din),.ddram_byte_enable(be),
        .ddram_busy(busy),.ddram_read_data(dout),.ddram_read_data_ready(valid),
        .epoch_quiescent(),.protocol_error,.debug_state()
    );
    integer cycles=0,left=0,delay_count=0,cart_completed=0;
    reg [28:0] response_addr;
    reg [31:0] rng=32'hb15ca17;
    function automatic [63:0] word_at(input [28:0] a);
        word_at={3'b0,a,3'b0,a};
    endfunction
    always @(posedge clk) begin
        cycles<=cycles+1;
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        busy<=reset || rng[2:0]==0;
        valid<=0;
        if(!reset) begin
            if(protocol_error) $fatal(1,"fabric protocol error");
            if(event_pending && !event_busy) begin event_pending<=0;event_stream<=1;end
            if(event_accepted) begin
                event_beat<=event_beat+1;
                if(event_beat==7) begin
                    event_completed<=event_completed+1;event_beat<=0;
                    event_pending<=1;event_stream<=0;
                end
            end
            if(wr && !busy) begin
                if(left || addr!=29'h07f01000 || burst!=8 || be!=8'hff || din!=64'(event_words))
                    $fatal(1,"event burst ownership/data corrupted");
                event_words<=event_words+1;
            end
            if(rd && !busy) begin
                if(left) $fatal(1,"read response ownership overlap");
                left<=burst;response_addr<=addr;delay_count<=12+(rng[7:3]);
            end else if(delay_count) delay_count<=delay_count-1;
            else if(left) begin
                dout<=word_at(response_addr);valid<=1;
                response_addr<=response_addr+1'b1;left<=left-1;
                delay_count<=rng[2:0]==0 ? 3 : 0;
            end
            if(accelerator_pending && !accelerator_busy) begin
                accelerator_pending<=0;accelerator_receiving<=1;accelerator_beat<=0;
            end
            if(accelerator_valid) begin
                if(!accelerator_receiving || accelerator_data!==word_at(29'h07f80000+accelerator_beat))
                    $fatal(1,"accelerator response corrupted");
                accelerator_beat<=accelerator_beat+1;
                if(accelerator_beat==127) begin
                    accelerator_pending<=1;accelerator_receiving<=0;
                    accelerator_completed<=accelerator_completed+1;
                end
            end
        end
    end
    // Keep the next miss queued while the previous four-beat refill drains.
    always @(negedge clk) begin
        cart_req=0;
        if(!reset && (cycles==20 || cart_ready)) begin
            if(cart_ready) begin
                if(cart_data!==(32'h06000000+{7'b0,cart_addr[27:3]}))
                    $fatal(1,"cartridge response corrupted");
                cart_completed=cart_completed+1;
                cart_addr=cart_addr+27'd2;
            end
            cart_req=1;
        end
    end
    // Active commands must remain stable until granted. An empty legacy
    // port may make local progress without bypassing reset quarantine.
    reg held_command=0;
    reg [110:0] held_payload;
    always @(posedge clk) begin
        if (held_command && {legacy_rd,legacy_we,legacy_burst,legacy_addr,legacy_din,legacy_be} !== held_payload)
            $fatal(1,"legacy command changed before its grant");
        held_command <= (legacy_rd || legacy_we) && legacy_busy;
        held_payload <= {legacy_rd,legacy_we,legacy_burst,legacy_addr,legacy_din,legacy_be};
        if (fabric.epoch_quiescent && !legacy_rd && !legacy_we && legacy_busy)
            $fatal(1,"empty legacy port blocked local cache work");
        if (reset && !legacy_busy)
            $fatal(1,"reset quarantine allowed legacy progress");
    end
    integer start_cycle,beats,max_latency=0;
    initial begin
        repeat(8) @(negedge clk);reset=0;
        repeat(100) @(negedge clk);
        for(integer line=0;line<48;line=line+1) begin
            start_cycle=cycles;beats=0;
            scan_addr=27'h7f00000+(line<<9);scan_req=1;
            @(negedge clk);scan_req=0;
            while(!scan_ready) begin
                if(scan_valid) begin
                    if(scan_data!==word_at(29'h07fc0000+(line<<7)+beats))
                        $fatal(1,"scanout response corrupted line=%0d beat=%0d",line,beats);
                    beats=beats+1;
                end
                if(cycles-start_cycle>=3840)
                    $fatal(1,"SCANOUT_DEADLINE_MISSED line=%0d cart=%0d accelerator=%0d legacy_state=%0d queued=%b rd=%b busy=%b owner=%0d response=%b remain=%0d scanbeats=%0d",line,cart_completed,accelerator_completed,legacy.state,legacy.ch_rq,legacy_rd,legacy_busy,fabric.fabric.grant_owner,fabric.fabric.read_pending,fabric.fabric.beats_remaining,beats);
                @(negedge clk);
            end
            if(beats!=128) $fatal(1,"scanout lost beats %0d",beats);
            if(cycles-start_cycle>max_latency)max_latency=cycles-start_cycle;
            while(cycles-start_cycle<3840) @(negedge clk);
        end
        if(cart_completed<4 || accelerator_completed<48 || (EVENTS && event_completed<48))
            $fatal(1,"peer starved cart=%0d accelerator=%0d",cart_completed,accelerator_completed);
        if (cart_completed < 4000) $fatal(1,"local cartridge progress starved");
        $display("PASS scanout deadlines: 48 complete lines, max=%0d/3840 clocks, cart=%0d accelerator=%0d events=%0d",max_latency,cart_completed,accelerator_completed,event_completed);
        $finish;
    end
    initial begin #10000000;$fatal(1,"contention timeout");end
endmodule
