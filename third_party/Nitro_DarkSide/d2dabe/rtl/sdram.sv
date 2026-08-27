//
// sdram
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
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

module sdram
#(
	// 1 inserts a register stage between the pin capture (dq_reg, which the
	// fitter puts in an I/O cell at the die edge) and the wide ch*_dout banks
	// (which it puts next to their consumers, deep in the fabric). That hop is
	// ~5.8ns of pure interconnect with ZERO logic levels in it, so it cannot be
	// optimised - only split, by giving the fitter a register it may place
	// halfway. Costs one clk of read latency, so leave it 0 unless clk is fast
	// enough that the hop misses setup: at 100.5MHz it has +1.16ns of slack.
	parameter integer DQ_PIPE = 0,

	// The two chip-protocol knobs. Both are sized for <=100MHz as they stand,
	// and neither is visible to FPGA static timing analysis - STA checks the
	// fabric, not whether the SDRAM part is being given the nanoseconds it
	// needs. Raising clk without revisiting these buys a core that closes
	// timing and reads the wrong data.
	//
	// CAS_LATENCY: the original's own comment is "2 for < 100MHz, 3 for
	// >100MHz". RDLY tracks it, so the read taps follow automatically.
	parameter integer CAS_LATENCY = 2,

	// TRCD_WAIT: clk cycles inserted between ACTIVE and READ/WRITE. 1 gives the
	// original's fixed 2-clock gap - 19.9ns at 100.5MHz, but only 14.9ns at
	// 134.1MHz, which is under the tRCD of every SDR part MiSTer ships with.
	parameter integer TRCD_WAIT = 1
)
(
	input             init,        // reset to initialize RAM
	input             clk,         // clock ~100MHz

	inout     [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
	output            SDRAM_DQML,  // two byte masks
	output            SDRAM_DQMH,  // 
	output reg  [1:0] SDRAM_BA,    // two banks
	output            SDRAM_nCS,   // a single chip select
	output            SDRAM_nWE,   // write enable
	output            SDRAM_nRAS,  // row address select
	output            SDRAM_nCAS,  // columns address select
	output            SDRAM_CKE,   // clock enable
	output            SDRAM_CLK,   // clock for chip

   input             refresh_req,

	input      [26:1] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [63:0] ch1_dout,    // data output to cpu
	input      [15:0] ch1_din,     // data input from cpu
	input             ch1_req,     // request
	input             ch1_rnw,     // 1 - read, 0 - write
	output reg        ch1_ready,
	// Pulses on the edge this channel takes a request into service. ch1_addr is
	// sampled LIVE at that grant (unlike ch2, which latches its attributes at
	// request time), so a requester must hold the address until it sees this -
	// and without it there is no way to know when the single ch1_rq slot has
	// freed, which is what forced callers to wait for ch1_ready and so pay full
	// SDRAM latency on every read with nothing overlapped.
	output reg        ch1_accept,
	
	input      [26:1] ch2_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [31:0] ch2_dout,    // data output to cpu
	input      [31:0] ch2_din,     // data input from cpu
	input       [3:0] ch2_be,      // byte enables for writes (DQM masks), keep 4'b1111 for reads
	input             ch2_req,     // request
	input             ch2_cancel,  // cancel pending read request so it doesn't deliver ready anymore
	input             ch2_rnw,     // 1 - read, 0 - write
	output reg        ch2_ready,
	output reg        ch2_ready16,
	// The high 32 bits of the SAME burst ch2_dout already returns. BURST_LENGTH
	// is 4, so every ch2 read moves 64 bits over the bus and this channel used
	// to discard half of them; ch1 has always kept all four words. Taking the
	// other two costs nothing on the wire - the burst occupies the identical
	// number of cycles - and lets a caller that wants an aligned 8-byte pair
	// (an ARM9 cache line fill is four such pairs) halve its number of round
	// trips through nds_mainram, which is where the real cost is.
	//
	// ch2_dout stays valid until the next burst, so a 64-bit consumer reads
	// {ch2_dout_hi, ch2_dout} on ch2_ready64 and a 32-bit one is untouched.
	// Only meaningful when the burst base is 8-byte aligned: ACCESS_TYPE is 0
	// (sequential), so a burst from a misaligned base wraps inside its aligned
	// block and the two halves come back swapped.
	output reg [31:0] ch2_dout_hi,
	output reg        ch2_ready64,

	input      [24:1] ch3_addr,
	output reg [15:0] ch3_dout,
	input      [15:0] ch3_din,
	input             ch3_req,
	input             ch3_rnw,
	output reg        ch3_ready
);

// Burst length = 4
localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam [2:0] CAS_LAT_B     = CAS_LATENCY[2:0];
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LAT_B, ACCESS_TYPE, BURST_CODE};

// Where the read-return delay line starts. Every DQ_PIPE stage pushes the whole
// line one bit up, which makes each tap fire one clk later - so the taps below
// stay put and the pipeline depth is expressed in exactly one place.
localparam RDLY                = CAS_LATENCY + BURST_LENGTH + DQ_PIPE;

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd750;  // (64000*100)/8192-1 Calc'd as (64ms @ 100MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;

// Registered "the refresh interval has elapsed". The comparison used to sit
// inline in STATE_IDLE, which put a 14-bit magnitude compare in the same cone as
// the three-channel grant arbitration that drives command[] - the third-worst
// path family in the 134MHz fit. Registering it is exact, not approximate:
// (count >= N) sampled at count==N is visible in the cycle where count==N+1,
// which is precisely when (count > N) used to first evaluate true.
reg        refresh_due = 0;

// Pin capture, and the optional pipeline copies. These live at module scope
// only so the dqu* selects below can be written once instead of at every tap;
// dq_reg is still assigned in exactly one place. One copy per channel: fanout
// is not the problem (dq_reg drives 6 loads), distance is, and three copies let
// the fitter place each near its own channel's dout bank rather than at the
// compromise centroid of all three. All optimised away when DQ_PIPE=0.
reg [15:0] dq_reg;
reg [15:0] dq_p1, dq_p2, dq_p3;

wire [15:0] dqu1 = DQ_PIPE ? dq_p1 : dq_reg;
wire [15:0] dqu2 = DQ_PIPE ? dq_p2 : dq_reg;
wire [15:0] dqu3 = DQ_PIPE ? dq_p3 : dq_reg;

// DQ is driven through an explicit registered tristate rather than the
// "inout reg SDRAM_DQ" the original used. Quartus accepts inout reg and infers
// exactly this, but it is not legal in any Verilog standard, so no simulator
// would elaborate the file - which is a large part of why this controller had
// no bench. Same hardware, one that can be tested.
reg [15:0] dq_out;
reg        dq_oe;
assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;

// dq_out is packed into the I/O cell, so whatever feeds it pays a route out to
// the pin ring. It used to be fed by a state-selected mux between the low and
// high halves of saved_data, which put "state -> SDRAM_DQ[n]~reg0" in the 134MHz
// violation list. dq_pre carries the word that is due next, so the I/O register
// is now fed by one plain flop with no select in the way; the fitter is then
// free to place dq_pre right against the pin bank.
reg [15:0] dq_pre;

// these reference command/chip, so they must follow the declarations
assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_RW2     = 3;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;
localparam STATE_WAIT2   = 11;   // second tRCD cycle, only entered when TRCD_WAIT > 1


always @(posedge clk) begin
	reg [RDLY:0] data_ready_delay1, data_ready_delay2, data_ready_delay3;

	reg        saved_wr;
	reg [12:0] cas_addr;
	reg [31:0] saved_data;
	reg  [3:0] saved_be;
	reg  [3:0] state = STATE_STARTUP;

	reg       ch1_rq, ch2_rq, ch3_rq;
	reg [1:0] ch;

	// pre-arbitration (see the block below the rq latches)
	reg [12:0] pre_a, pre_cas;
	reg  [1:0] pre_ba;
	reg [31:0] pre_data;
	reg  [3:0] pre_be;
	reg        pre_rfsh = 0, pre_ch1 = 0, pre_ch2 = 0, pre_ch3 = 0;
	reg        pre_chip, pre_wr;
	reg        n_ch1, n_ch2, n_ch3;

	// ch2 request contract fix (2P guest mux): a request owns its attributes.
	// The original code sampled ch2_addr/din/be/rnw LIVE at grant time and let
	// a latched rq survive ch2_cancel - safe with the single 1P client whose
	// registers hold still until grant, but with gba_wrap's guest mux in front
	// the attributes move while a request waits (extern chains/rewinds its
	// address, the mux switches source) and an abandoned request would run
	// later as a ghost whose done poisons whichever channel waits.
	reg [26:1] ch2_addr_r; // range matches the port: a [26:0] reg would
	                       // zero-extend the assignment and shift every
	                       // address bit down by one on queued grants
	reg [31:0] ch2_din_r;
	reg  [3:0] ch2_be_r;
	reg        ch2_rnw_r;
	reg        ch2_kill = 0;

	ch1_rq <= ch1_rq | ch1_req;
	ch2_rq <= (ch2_rq & ~ch2_cancel) | ch2_req; // cancel kills a pending rq; same-edge relaunch re-arms
	ch3_rq <= ch3_rq | ch3_req;

	// ---- pre-arbitration -------------------------------------------------
	// STATE_IDLE used to run the whole channel priority mux INTO the SDRAM_A
	// register: `ch1_rq / state.* -> SDRAM_A[7:8]`, one clkMem period, ending
	// in an I/O-column flop. At 134 MHz that was the last family missing
	// timing (-0.432 audio, -0.515 debug), and it is why NDS_CLKMEM_4X could
	// not close.
	//
	// The mux does not have to be in that cone. Its inputs are the request
	// LATCHES, so the decision can be made one cycle early, in PARALLEL with
	// those latches' own update rather than in series with it, and IDLE then
	// only moves an already-chosen word. That is free, not a pipeline stage:
	// pre_* holds exactly what the old mux would have produced in the cycle
	// IDLE consumes it.
	//
	// It is evaluated from `rq | req` - the next value of each latch IGNORING
	// the grant clears. The stale value that leaves behind is only ever seen
	// while we are NOT in IDLE (a grant goes IDLE -> WAIT -> [WAIT2] -> RW1,
	// so the earliest return to IDLE is several cycles later, by which time
	// the clear has propagated), and IDLE is the only state that reads it.
	//
	// One behavioural change, and only for ch2: it used to grant on
	// `ch2_rq | ch2_req`, i.e. in the very cycle the request arrived, taking
	// the LIVE ch2_addr. That same-cycle grant is now one cycle later. ch1 and
	// ch3 are bit-identical in timing - their request bits were already
	// registered - so the renderer channel's 8-cycle slot is unchanged, and
	// 4x keeps its full throughput gain over 3x.
	// the next value of each request latch, ignoring the grant clears
	n_ch1 = ch1_rq | ch1_req;
	n_ch2 = (ch2_rq & ~ch2_cancel) | ch2_req;
	n_ch3 = ch3_rq | ch3_req;

	pre_rfsh <= refresh_req | refresh_due;
	pre_ch1  <= ~(refresh_req | refresh_due) & n_ch1;
	pre_ch2  <= ~(refresh_req | refresh_due) & ~n_ch1 & n_ch2;
	pre_ch3  <= ~(refresh_req | refresh_due) & ~n_ch1 & ~n_ch2 & n_ch3;

	if (n_ch1) begin
		{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, 1'b1, ch1_addr[25:1]};
		pre_chip <= ch1_addr[26];
		pre_data <= ch1_din;
		pre_be   <= 4'b1111;
		pre_wr   <= ~ch1_rnw;
	end
	else if (n_ch2) begin
		// a request owns its attributes: live only for the same-edge pulse,
		// otherwise what was latched when it was made
		if (ch2_req) begin
			{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch2_rnw, ch2_addr[25:1]};
			pre_chip <= ch2_addr[26];
			pre_data <= ch2_din;
			pre_be   <= ch2_be;
			pre_wr   <= ~ch2_rnw;
		end
		else begin
			{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch2_rnw_r, ch2_addr_r[25:1]};
			pre_chip <= ch2_addr_r[26];
			pre_data <= ch2_din_r;
			pre_be   <= ch2_be_r;
			pre_wr   <= ~ch2_rnw_r;
		end
	end
	else begin
		{pre_cas[12:9], pre_ba, pre_a, pre_cas[8:0]} <= {2'b00, ch3_rnw, ch3_addr[23:1], 2'b00};
		pre_chip <= ch3_addr[24];
		pre_data <= {8'hFF, ch3_din[15:8], 8'hFF, ch3_din[7:0]};
		pre_be   <= 4'b1111;
		pre_wr   <= ~ch3_rnw;
	end

	if (ch2_req) begin
		ch2_addr_r <= ch2_addr;
		ch2_din_r  <= ch2_din;
		ch2_be_r   <= ch2_be;
		ch2_rnw_r  <= ch2_rnw;
	end

	ch1_ready   <= 0;
	ch1_accept  <= 0;
	ch2_ready   <= 0;
	ch2_ready16 <= 0;
	ch2_ready64 <= 0;
	ch3_ready   <= 0;

	refresh_count <= refresh_count+1'b1;
	refresh_due   <= (refresh_count >= cycles_per_refresh);

	data_ready_delay1 <= data_ready_delay1>>1;
	data_ready_delay2 <= data_ready_delay2>>1;
	data_ready_delay3 <= data_ready_delay3>>1;

	dq_reg <= SDRAM_DQ;
	dq_p1  <= dq_reg;
	dq_p2  <= dq_reg;
	dq_p3  <= dq_reg;

	if(data_ready_delay1[3]) ch1_dout[15:00] <= dqu1;
	if(data_ready_delay1[2]) ch1_dout[31:16] <= dqu1;
	if(data_ready_delay1[1]) ch1_dout[47:32] <= dqu1;
	if(data_ready_delay1[0]) ch1_dout[63:48] <= dqu1;
	// tap [0], not [1]. The last word lands on the [0] edge, so a consumer that
	// samples dout on the cycle ready is high - which is what NDS.sv:984 does,
	// and what any synchronous consumer does - must not be told "ready" until
	// the cycle after that. On [1] it read ch1_dout[63:48] from the PREVIOUS
	// burst. [1] was correct while ch1_dout was 48 bits wide; widening it to 64
	// added the [0] tap without moving ready. sim/tb_sdram_ch.sv covers this.
	if(data_ready_delay1[0]) ch1_ready <= 1;

	if(data_ready_delay2[3]) ch2_dout[15:00] <= dqu2;
	if(data_ready_delay2[2]) ch2_dout[31:16] <= dqu2;
	if(data_ready_delay2[2]) ch2_ready   <= 1;
	if(data_ready_delay2[3]) ch2_ready16 <= 1;
	// words 3 and 4 of the same burst - the half ch2 used to drop. Tapped at
	// [1]/[0] exactly as ch1 is, and ready at [0] rather than [1] for the
	// reason spelled out above ch1_ready: the last word lands ON the [0] edge,
	// so a ready raised at [1] would be seen beside the PREVIOUS burst's high
	// half. That was a real ch1 bug; do not "tighten" it here either.
	if(data_ready_delay2[1]) ch2_dout_hi[15:00] <= dqu2;
	if(data_ready_delay2[0]) ch2_dout_hi[31:16] <= dqu2;
	if(data_ready_delay2[0]) ch2_ready64 <= 1;

	if(data_ready_delay3[3]) ch3_dout[07:00] <= dqu3[7:0];
	if(data_ready_delay3[1]) ch3_dout[15:08] <= dqu3[7:0];
	if(data_ready_delay3[1]) ch3_ready <= 1;

	dq_oe  <= 0;
	dq_out <= dq_pre;   // unconditional: the enable lives on dq_oe, not on a mux

	command <= CMD_NOP;
	case (state)
		STATE_STARTUP: begin
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;

			if (refresh_count == (startup_refresh_max-64)) chip <= 0;
			if (refresh_count == (startup_refresh_max-32)) chip <= 1;

			// All the commands during the startup are NOPS, except these
			if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
				// ensure all rows are closed
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
				SDRAM_BA    <= 2'b00;
			end
			if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
				// these refreshes need to be at least tREF (66ns) apart
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
				// Now load the mode register
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			if (!refresh_count) begin
				state   <= STATE_IDLE;
				refresh_count <= 0;
				refresh_due   <= 0;   // count is being cleared; keep the flag in step
			end
		end

		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: state <= STATE_IDLE;

		STATE_RFSH: begin
			state    <= STATE_IDLE_5;
			command  <= CMD_AUTO_REFRESH;
			chip     <= 1;
		end

		// Everything the grant needs was chosen a cycle ago (see the
		// pre-arbitration block), so this state only MOVES it. SDRAM_A's data
		// input is now a single register, not the channel priority mux, which
		// is what takes the mux out of its cone.
		STATE_IDLE: begin
			if (pre_rfsh) begin
				state         <= STATE_RFSH;
				command       <= CMD_AUTO_REFRESH;
				refresh_count <= 0;
				refresh_due   <= 0;
				chip          <= 0;
			end
			else if (pre_ch1 | pre_ch2 | pre_ch3) begin
				SDRAM_A    <= pre_a;
				SDRAM_BA   <= pre_ba;
				cas_addr   <= pre_cas;
				chip       <= pre_chip;
				saved_data <= pre_data;
				saved_be   <= pre_be;
				saved_wr   <= pre_wr;
				command    <= CMD_ACTIVE;
				state      <= STATE_WAIT;

				if (pre_ch1) begin
					ch         <= 0;
					ch1_rq     <= 0;
					ch1_accept <= 1;   // address captured; caller may present the next
				end
				else if (pre_ch2) begin
					ch       <= 1;
					ch2_rq   <= 0;
					// a cancel arriving on THIS edge still wins: its
					// `ch2_kill <= 1` is the last assignment in the block, so
					// a stale rq granted here is a dead slot, not a stray done
					ch2_kill <= 0;
				end
				else begin
					ch      <= 2;
					ch3_rq  <= 0;
				end
			end
		end

		// dq_pre survives any number of wait states - it is only overwritten in
		// RW1 - so loading it here works for both TRCD_WAIT settings.
		STATE_WAIT: begin
			state  <= (TRCD_WAIT > 1) ? STATE_WAIT2 : STATE_RW1;
			dq_pre <= saved_data[15:0];   // due on the bus with the first WRITE
		end
		STATE_WAIT2: state <= STATE_RW1;
		STATE_RW1: begin
			SDRAM_A <= cas_addr;
			if(saved_wr) begin
				command  <= CMD_WRITE;
				dq_pre   <= saved_data[31:16];  // due with the second
				dq_oe    <= 1;
				SDRAM_A[12:11] <= ~saved_be[1:0]; // DQM byte masks for the low word
				if(!ch) begin
					ch1_ready  <= 1;
					state <= STATE_IDLE_2;
				end
				else begin
					state <= STATE_RW2;
				end
			end
			else begin
				command <= CMD_READ;
				state   <= STATE_IDLE_5;
				     if(ch == 0) data_ready_delay1[RDLY] <= 1;
				else if(ch == 1) begin
					// a cancel since grant means nobody wants this data:
					// let the burst run out silently, fire no ready
					if (~ch2_kill) data_ready_delay2[RDLY] <= 1;
				end
				else             data_ready_delay3[RDLY] <= 1;
			end
		end

		STATE_RW2: begin
			if(ch == 1) begin
				// 8-cycle slot like reads: the next grant's same-bank ACTIVE
				// (or AUTO_REFRESH) must sit out tWR+tRP of this write's auto
				// precharge and tRC of its ACTIVE (63ns on AS4C32M16SB-7 =
				// 6.4 cycles). The old 6-cycle slot fired ACT at 59.6ns,
				// corrupting rows under sustained EWRAM write traffic --
				// harmless in 1P, whose gameplay never writes ch2.
				state       <= STATE_IDLE_4;
				SDRAM_A[10] <= 1;
				SDRAM_A[0]  <= 1;
				SDRAM_A[12:11] <= ~saved_be[3:2]; // DQM byte masks for the high word
				command     <= CMD_WRITE;
				dq_oe       <= 1;
				ch2_ready   <= 1;
				ch2_ready16 <= 1;
				// a write returns no data; raise the 64-bit done too so a
				// pair-mode caller retires writes on the same signal it
				// retires reads on
				ch2_ready64 <= 1;
			end
			else begin
				state       <= STATE_IDLE_2;
				SDRAM_A[10] <= 1;
				SDRAM_A[1]  <= 1;
				command     <= CMD_WRITE;
				dq_oe       <= 1;
				ch3_ready   <= 1;
			end
		end
	endcase

	if (init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		refresh_due   <= 0;
	end
   
   if (ch2_cancel) begin
		// kill the pipeline AND a ready registered this very edge: the
		// pre-edge delay bit would otherwise let the abandoned op's done
		// escape into whatever read the canceller starts on this edge
		data_ready_delay2 <= 'd0;
		ch2_ready         <= 0;
		ch2_ready16       <= 0;
		ch2_ready64       <= 0;
		// sticky kill for ops between grant and CAS, and for a stale rq
		// granted this very edge (this assignment is last, so it wins over
		// the grant's clear). A same-edge relaunch keeps its op alive.
		if (!ch2_req) ch2_kill <= 1;
	end
 
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
