`timescale 1ns/1ps
module tb_osd_write_queue;
 reg clk=0;always #5 clk=~clk;
 reg io_clk=0,rack=0,ack=0;
 wire strobe=~rack & io_clk;
 wire busy;
 reg [12:0] address=0;
 reg [7:0] data=0;
 reg analog_read=0;
 reg [12:0] read_address=0;
 wire [7:0] dq,aq,pair_q;
 function automatic [7:0] contents(input integer a);
  contents=(a*73)^(a>>4)^8'h96;
 endfunction
 integer accepted=0,peak=0,blocked=0;
 always @(posedge clk) begin
  if(!busy || strobe) begin rack<=io_clk;ack<=rack;end
  if(strobe) accepted=accepted+1;
  if(memory.count>peak) peak=memory.count;
  if(busy && rack && !ack) blocked=blocked+1;
 end
 nds_native_osd_memory memory(.clk,.write_enable(strobe),.write_address(address),.write_data(data),.busy,
  .digital_read(1'b1),.digital_address(read_address),.digital_q(dq),.digital_pair_q(pair_q),
  .analog_read,.analog_address(read_address),.analog_q(aq));
 task automatic tx(input integer a,d);
  @(negedge clk);address=a;data=d;io_clk=1;
  while(!ack) @(negedge clk);
  io_clk=0;
  while(ack) @(negedge clk);
 endtask
 initial begin
  repeat(5) @(negedge clk);
  fork
   begin
    analog_read=1;
    repeat(500) @(negedge clk);
    analog_read=0;
   end
   begin
    for(integer i=0;i<64;i=i+1) tx(i,i^8'ha5);
   end
  join
  repeat(12) @(negedge clk);
  if(accepted!=64 || peak!=2 || blocked<400 || memory.count!=0)
   $fatal(1,"bad backpressure accepted%0d peak%0d blocked%0d count%0d",accepted,peak,blocked,memory.count);
  for(integer i=0;i<64;i=i+1) begin
   @(negedge clk);read_address=i;
   @(posedge clk);#1;
   if(dq !== (8'(i)^8'ha5)) $fatal(1,"lost first-pass byte %0d",i);
  end
  // Legal fastest strobe rate (one rising pulse every two clocks), with
  // analog read bursts followed by spare cycles. Ignore ack in this part
  // to exercise more write load than the real HPS acknowledgement permits.
  force rack=0;
  fork
   begin
    for(integer t=0;t<384;t=t+1) begin
     @(negedge clk);analog_read=(t%6)<2;
    end
    analog_read=0;
   end
   begin
    for(integer i=0;i<64;i=i+1) begin
     @(negedge clk);address=i;data=i^8'h3c;io_clk=1;
     @(negedge clk);io_clk=0;
    end
   end
  join
  release rack;
  repeat(12) @(negedge clk);
  if(accepted!=128 || memory.count!=0) $fatal(1,"lost stress writes");
  analog_read=1;
  for(integer i=0;i<64;i=i+1) begin
   @(negedge clk);read_address=i;
   @(posedge clk);#1;
   if(dq!==(8'(i)^8'h3c) || aq!==dq) $fatal(1,"read port mismatch address%0d d%h a%h",i,dq,aq);
  end
  $display("PASS OSD FIFO: %0d writes, peak%0d, %0d backpressure clocks, exact bytes and both read ports",accepted,peak,blocked);
  // Exercise both byte enables throughout the bitmap, including the last
  // pair. Invalid SPI addresses must not wrap onto valid byte lanes.
  analog_read=0;
  for(integer i=0;i<4096;i++) tx(i,contents(i));
  tx(4096,0);tx(8191,0);
  repeat(12) @(negedge clk);
  analog_read=1;
  for(integer i=0;i<4096;i++) begin
   @(negedge clk);read_address=i;
   @(posedge clk);#1;
   if(dq!==contents(i) || aq!==contents(i) || pair_q!==contents(i^1))
    $fatal(1,"packed bitmap mismatch address%0d digital%h analog%h pair%h",i,dq,aq,pair_q);
  end
  $display("PASS complete 4096-byte bitmap, companion columns and out-of-range write rejection");
  $finish;
 end
 initial begin #1000000; $fatal(1,"timeout");end
endmodule
