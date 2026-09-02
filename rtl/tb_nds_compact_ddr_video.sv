module tb;
    localparam HA=8,VA=2,HT=12,VT=5,WORDS=4,BURST=2;logic clk=0,reset=1;
    logic ddram_busy=1,ddram_dout_ready=0,ddram_rd,ddram_we,ce_pixel,de,hblank,vblank,hsync,vsync,ready,format_error;
    logic [31:0] joystick=32'h00000012;logic [63:0] ddram_dout,ddram_din;logic [7:0] ddram_burstcnt,red,green,blue;logic [28:0] ddram_addr;
    logic [3:0] debug_progress;
    logic signed [15:0] audio_l,audio_r;
    logic [511:0] header;integer beat=0,left=0,checked=0,input_checked=0;always #5 clk=~clk;
    nds_compact_ddr_video #(.H_ACTIVE(HA),.H_FRONT(1),.H_SYNC(1),.H_TOTAL(HT),
        .V_ACTIVE(VA),.V_FRONT(1),.V_SYNC(1),.V_TOTAL(VT),.PIXEL_DIVIDE(3),
        .FRAME_WORDS(WORDS),.FETCH_BURST_WORDS(BURST)) dut(.*,.control_addr(29'h06000000));
    function automatic [15:0] px(input integer n);
        reg [15:0] value;
        begin
            value = 16'd0;
            value[4:0] = n % HA;
            value[9:5] = n / HA;
            px = value;
        end
    endfunction
    initial begin
        header=0;header[63:0]=64'h315542504c53444e;header[95:64]=2;header[127:96]=64;
        header[191:128]=2;header[223:192]=0;header[255:224]=196608;header[287:256]=2;
        header[319:288]=98304;header[383:320]=1;header[447:384]=2;
        repeat(4)@(posedge clk);@(negedge clk);reset=0;
        wait(ddram_rd);
        repeat(3)begin
            @(posedge clk);#1;
            if(!ddram_rd)$fatal(1,"header request dropped while busy");
        end
        @(negedge clk);ddram_busy=0;
    end
    always @(negedge clk)begin
        ddram_dout_ready=0;
        if(ddram_rd&&!ddram_busy)begin left=ddram_burstcnt;beat=0;end
        else if(left>0)begin
            if(ddram_burstcnt==8)ddram_dout=header[beat*64+:64];
            else ddram_dout={px((ddram_addr-29'h06080000+beat)*4+3),px((ddram_addr-29'h06080000+beat)*4+2),
                px((ddram_addr-29'h06080000+beat)*4+1),px((ddram_addr-29'h06080000+beat)*4)};
            ddram_dout_ready=1;beat=beat+1;left=left-1;
        end
    end
    always @(posedge clk)if(ce_pixel&&de&&ready)begin
        if(red!=={dut.x[4:0],dut.x[4:2]}||green!=={dut.y[4:0],dut.y[4:2]}||blue!==0)
            $fatal(1,"pixel x=%0d y=%0d got %h %h %h",dut.x,dut.y,red,green,blue);
        checked=checked+1;if(checked==HA*VA)begin if(format_error)$fatal(1,"format");
            if(!input_checked)$fatal(1,"input bridge write not observed");
            if(debug_progress!==4'hf)$fatal(1,"debug progress %h",debug_progress);
            $display("NDS compact DDR video/input: ABI-2 fetch, bank swap, RGB555 raster, and joystick publication passed");$finish;end
    end
    always @(posedge clk)if(ddram_we)begin
        if(ddram_addr!==29'h06000008)$fatal(1,"input address %h",ddram_addr);
        if(ddram_din!==64'h4a53444e00000012)$fatal(1,"input payload %h",ddram_din);
        input_checked=1;
    end
    initial begin repeat(10000)@(posedge clk);$fatal(1,"timeout ready=%b",ready);end
endmodule
