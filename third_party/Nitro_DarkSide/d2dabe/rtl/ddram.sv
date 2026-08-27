//
// ddram.v
// Copyright (c) 2019 Sorgelig
//
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//

module ddram
(
	input         DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	
	input  [27:1] ch1_addr,
	output [63:0] ch1_dout,
	input  [15:0] ch1_din,
	input         ch1_req,
	input         ch1_rnw,
	output        ch1_ready,

	input  [27:1] ch2_addr,
	output [31:0] ch2_dout,
	input  [31:0] ch2_din,
	input         ch2_req,
	input         ch2_rnw,
	output        ch2_ready,

	// Was a donor 16-bit channel with a [25:1] address, tied off since import.
	// Reshaped to ch4's form (64-bit R/W + byte enables, full [27:1] address)
	// for the HPS audio ring: the ring lives at byte 0x0FFD0000, which the old
	// 25-bit address could not reach at all (it topped out at 64 MB).
	input  [27:1] ch3_addr,
	output [63:0] ch3_dout,
	input  [63:0] ch3_din,
	input         ch3_req,
	input         ch3_rnw,
	input  [7:0]  ch3_be,
	output        ch3_ready,

	// save state
	input  [27:1] ch4_addr,
	output [63:0] ch4_dout,
	input  [63:0] ch4_din,
	input         ch4_req,
	input         ch4_rnw,
	input  [7:0]  ch4_be,
	output        ch4_ready,
   
   // framebuffer write (NDS: line bursts; ch5_burst=1 behaves as before)
	input  [27:1] ch5_addr,
	input  [63:0] ch5_din,
	input         ch5_req,
	input   [7:0] ch5_burst,
	output        ch5_next,   // advance the feeder: ch5_din is sampled this cycle
	output        ch5_ready,

	// framebuffer read (NDS scanout prefetch): burst read, streaming beats
	input  [27:1] ch6_addr,
	input   [7:0] ch6_burst,
	input         ch6_req,
	output [63:0] ch6_dout,
	output        ch6_valid,  // one pulse per beat, qualifies ch6_dout
	output        ch6_ready
);

reg  [7:0] ram_burst;
reg [63:0] ram_q[4:1];
reg [63:0] ram_data;
reg [27:1] ram_address;
reg        ram_read = 0;
reg        ram_write = 0;
reg  [7:0] ram_be;

reg  [6:1] ready;

assign DDRAM_BURSTCNT = ram_burst;
assign DDRAM_BE       = ram_read ? 8'hFF : ram_be;
assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]}; // RAM at 0x30000000
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_data;
assign DDRAM_WE       = ram_write;

assign ch1_dout  = ram_address[2] ? {ram_q[1][31:0], ram_q[1][63:32]} : ram_q[1];
assign ch2_dout  = ram_address[2] ? ram_q[2][63:32] : ram_q[2][31:0];
assign ch3_dout  = ram_q[3];
assign ch4_dout  = ram_q[4];
assign ch1_ready = ready[1];
assign ch2_ready = ready[2];
assign ch3_ready = ready[3];
assign ch4_ready = ready[4];
assign ch5_ready = ready[5];
assign ch6_ready = ready[6];

reg [63:0] next_q[2:1];
reg [27:1] cache_addr[2:1];
reg  [2:0] state  = 0;
reg  [2:1] cached = 0;
reg  [2:0] ch = 0;
reg  [6:1] ch_rq = 0;   // explicit power-up value (also keeps SV sims X-free)
reg  [7:0] wcnt;   // ch5 burst-write beats left to present
reg  [7:0] rcnt;   // ch6 burst-read beats left to receive

// request-pending terms, shared by the grant chain and the ch5 feeder strobe
// so the two can never disagree about who is being served
wire p1 = ch_rq[1] | ch1_req;
wire p2 = ch_rq[2] | ch2_req;
wire p3 = ch_rq[3] | ch3_req;
wire p4 = ch_rq[4] | ch4_req;
wire p6 = ch_rq[6] | ch6_req;
wire p5 = ch_rq[5] | ch5_req;

// ch5_din is consumed at the burst grant (first beat) and on every accepted
// beat that still has data behind it; the feeder advances one word per pulse
wire grant5 = (state == 3'd0) && !DDRAM_BUSY && !p1 && !p2 && !p3 && !p4 && !p6 && p5;
assign ch5_next = grant5 || ((state == 3'd3) && !DDRAM_BUSY && (wcnt != 0));

// beats stream straight through; the consumer registers them
assign ch6_dout  = DDRAM_DOUT;
assign ch6_valid = (state == 3'd4) && DDRAM_DOUT_READY;

always @(posedge DDRAM_CLK) begin


	ch_rq <= ch_rq | {ch6_req, ch5_req, ch4_req, ch3_req, ch2_req, ch1_req};
	ready <= 0;

	if(!DDRAM_BUSY) begin
		ram_write <= 0;
		ram_read  <= 0;

		case(state)
			0: if(p1) begin
					ch_rq[1]         <= 0;
					ch               <= 1;
					ram_data         <= {4{ch1_din}};
					ram_be           <= 8'h03 << {ch1_addr[2:1],1'b0};
					if(~ch1_rnw) begin
						ram_address   <= ch1_addr;
						ram_write     <= 1;
						ram_burst     <= 1;
						cached[1]     <= 0;
						ready[1]      <= 1;
					end else begin
						ram_address   <= ch1_addr;
						cache_addr[1] <= ch1_addr;
						ram_read      <= 1;
						ram_burst     <= 1;
						state         <= 1;
					end
				end
			   else if(p2) begin
					ch_rq[2]         <= 0;
					ch               <= 2;
					ram_data         <= {2{ch2_din}};
					ram_be           <= ch2_addr[2] ? 8'hF0 : 8'h0F;
					if(~ch2_rnw) begin
						ram_address   <= ch2_addr;
						ram_write     <= 1;
						ram_burst     <= 1;
						cached[2]     <= 0;
						ready[2]      <= 1;
					end
					else if(cached[2] && cache_addr[2][27:3] == ch2_addr[27:3]) begin
						// same-beat cache hit: no memory op, but the dout
						// half-select (ram_address[2]) must follow THIS
						// request, not the address of the original fill -
						// sequential word0->word1 reads served the wrong
						// word otherwise
						ram_address   <= ch2_addr;
						ready[2]      <= 1;
					end
					else if(cached[2] && (cache_addr[2][27:3]+1'd1) == ch2_addr[27:3]) begin
						ram_q[2]      <= next_q[2];
						cache_addr[2] <= ch2_addr;
						ram_address   <= ch2_addr + 8'd4;
						ram_read      <= 1;
						ram_burst     <= 1;
						cached[2]     <= 1;
						ready[2]      <= 1;
						state         <= 2;
					end
					else begin
						ram_address   <= ch2_addr;
						cache_addr[2] <= ch2_addr;
						ram_read      <= 1;
						ram_burst     <= 2;
						cached[2]     <= 1;
						state         <= 1;
					end
				end
			   else if(p3) begin
					// Same shape as ch4 below. The old arm cleared cached[2] on a
					// write - a copy-paste from the ch2 block that invalidated the
					// CARD ROM beat cache, not ch3's (ch3 has none; `cached` is
					// [2:1]). It never fired because ch3 was tied off; it is gone
					// rather than carried into a channel that now sees real traffic.
					ch_rq[3]         <= 0;
					ch               <= 3;
					ram_address      <= ch3_addr;
					ram_data         <= ch3_din;
					ram_be           <= ch3_be;
					ram_burst        <= 1;
					if(~ch3_rnw) begin
						ram_write     <= 1;
						ready[3]      <= 1;
					end
					else begin
						ram_read      <= 1;
						state         <= 1;
					end
				end
			   else if(p4) begin
					ch_rq[4]         <= 0;
					ch               <= 4;
					ram_data         <= ch4_din;
					ram_be           <= ch4_be;
					ram_address      <= ch4_addr;
					ram_burst        <= 1;
					if(~ch4_rnw) begin
						ram_write     <= 1;
						ready[4]      <= 1;
					end
					else begin
						ram_read      <= 1;
						state         <= 1;
					end
            end
            else if(p6) begin
					// burst read: command goes out now, beats are collected in
					// state 4 (not gated on DDRAM_BUSY - readdatavalid is
					// independent of waitrequest)
					ch_rq[6]         <= 0;
					ram_address      <= ch6_addr;
					ram_read         <= 1;
					ram_burst        <= ch6_burst;
					rcnt             <= ch6_burst;
					state            <= 4;
				end
            else if(p5) begin
					ch_rq[5]         <= 0;
					ch               <= 5;
					ram_data         <= ch5_din;
					ram_be           <= 8'hFF;
               ram_address      <= ch5_addr;
               ram_write        <= 1;
               ram_burst        <= ch5_burst;
               if(ch5_burst == 8'd1) ready[5] <= 1;   // legacy single-beat shape
               else begin
                  wcnt          <= ch5_burst - 1'd1;
                  state         <= 3;
               end
				end

			3: begin
					// burst write stream: entering here with !DDRAM_BUSY means the
					// beat presented last cycle was just accepted
					if(wcnt == 0) begin
						ready[5]      <= 1;   // last beat accepted (ram_write stays cleared)
						state         <= 0;
					end
					else begin
						ram_write     <= 1;
						ram_data      <= ch5_din;
						wcnt          <= wcnt - 1'd1;
					end
				end
		endcase
	end

	// Read-data collection for every channel sits OUTSIDE the !DDRAM_BUSY
	// gate: Avalon readdatavalid is independent of waitrequest, and once
	// the fb channels keep the port genuinely busy (128-beat bursts), a
	// beat arriving while BUSY is high must not be dropped - under the old
	// gating that beat was lost and the FSM hung. With no overlap this is
	// cycle-identical to the original code.
	if(state == 3'd1 && DDRAM_DOUT_READY) begin
		ram_q[ch]  <= DDRAM_DOUT;
		ready[ch]  <= 1;
		state      <= {ram_burst[1], 1'b0};
	end

	if(state == 3'd2 && DDRAM_DOUT_READY) begin
		next_q[ch] <= DDRAM_DOUT;
		state      <= 0;
	end

	if(state == 3'd4 && DDRAM_DOUT_READY) begin
		rcnt <= rcnt - 1'd1;
		if(rcnt == 8'd1) begin
			ready[6] <= 1;
			state    <= 0;
		end
	end
end

endmodule
