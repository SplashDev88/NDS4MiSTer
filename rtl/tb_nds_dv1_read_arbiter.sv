// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_nds_dv1_read_arbiter;
    reg clk=0,reset=1;
    always #5 clk=~clk;
    reg s_read=0,s_write=0,n_read=0;
    reg [27:0] s_address=28'h2000000,n_address=28'h2400000;
    reg [7:0] s_burstcount=1,n_burstcount=1;
    reg [127:0] s_writedata=0;
    reg [15:0] s_byteenable=16'hf00f;
    wire s_waitrequest,s_readdatavalid,n_waitrequest,n_readdatavalid,m_read,m_write;
    wire [27:0] m_address;
    wire [7:0] m_burstcount;
    wire [127:0] m_writedata;
    wire [15:0] m_byteenable;
    reg m_waitrequest=0,m_readdatavalid=0;
    nds_dv1_read_arbiter dut(.*);
    reg [31:0] rng=32'h93526b17;
    reg owners[0:65535];
    integer head=0,tail=0,normal_reads=0,native_reads=0,write_beats=0,cycle=0;
    integer client_writes=0,global_writes=0,native_due=0;
    reg normal_accepted=0,native_accepted=0,was_held=0;
    reg [181:0] held;
    wire [181:0] command={m_read,m_write,m_address,m_burstcount,m_writedata,m_byteenable};
    always @(negedge clk) if(!reset) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        m_waitrequest=rng[2:0]==0 || cycle%1000<20;
        m_readdatavalid=head!=tail && rng[4:3]!=0;
        if(normal_accepted || (!s_read && !s_write)) begin
            s_read=0;s_write=0;
            if(client_writes>0) begin s_write=1;s_writedata=s_writedata+1;end
            else if(rng[8:5]<10) begin s_read=1;s_burstcount=8'(1+rng[15:12]);end
            else if(rng[8:5]<14) begin
                s_write=1;s_burstcount=8'(1+rng[15:12]);client_writes=s_burstcount;
                s_writedata=s_writedata+1;
            end
        end
        if(native_accepted) n_read=0;
        if(!n_read && native_due==0 && cycle>1000 && cycle%997==0) begin
            n_read=1;n_burstcount=8'(1+rng[22:16]);
        end
    end
    always @(posedge clk) if(!reset) begin
        cycle=cycle+1;
        if(was_held && command!==held) $fatal(1,"memory request changed while stalled");
        held=command;was_held=(m_read || m_write) && m_waitrequest;
        normal_accepted=(s_read || s_write) && !s_waitrequest;
        native_accepted=n_read && !n_waitrequest;
        if(s_write && !s_waitrequest) begin client_writes=client_writes-1;write_beats=write_beats+1;end
        if(m_write && !m_waitrequest) begin
            if(m_address!=s_address || m_writedata!==s_writedata || m_byteenable!=s_byteenable)
                $fatal(1,"normal write corrupted");
            if(global_writes==0) global_writes=m_burstcount;
            global_writes=global_writes-1;
        end
        if(m_read && !m_waitrequest) begin
            if(global_writes!=0) $fatal(1,"interrupted write burst");
            if(tail-head+m_burstcount>=65536) $fatal(1,"test response queue full");
            for(integer i=0;i<m_burstcount;i=i+1) begin owners[tail%65536]=(m_address==n_address);tail=tail+1;end
            if(m_address==n_address) begin
                if(!native_accepted || native_due!=0) $fatal(1,"wrong native acceptance");
                native_due=m_burstcount;native_reads=native_reads+1;
            end else begin
                if(!normal_accepted || !s_read) $fatal(1,"wrong normal acceptance");
                normal_reads=normal_reads+1;
            end
        end
        if(m_readdatavalid) begin
            if(head==tail || n_readdatavalid!==owners[head%65536] ||
                s_readdatavalid===owners[head%65536]) $fatal(1,"response routed to wrong owner");
            if(n_readdatavalid) native_due=native_due-1;
            head=head+1;
        end
        if(cycle<1000 && (s_waitrequest!==m_waitrequest ||
            m_read!==s_read || m_write!==s_write || m_address!==s_address ||
            m_writedata!==s_writedata || s_readdatavalid!==m_readdatavalid))
            $fatal(1,"disabled native reader changed normal handshake");
        if(cycle==200000) begin
            if(native_reads<30 || normal_reads<100 || write_beats<100) $fatal(1,"coverage too small");
            $display("PASS arbiter: %0d native bursts, %0d normal bursts, %0d write beats; held requests and response ownership",native_reads,normal_reads,write_beats);
            $finish;
        end
    end
    initial begin repeat(5) @(negedge clk);reset=0;end
endmodule
