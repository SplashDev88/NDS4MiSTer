// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
//
// Product-side reset adaptation of Nitro_DarkSide nds_fb_ddr3.sv from
// d2dabe03344c0a685cd0f00e42b1a89606710dee.  Only control/CDC state resets;
// the accumulator and line-buffer RAM arrays deliberately remain unreset.
//
// Write side (clk_sys): each 2D engine's merge drain (256 consecutive
// 1 px/cycle writes per line, monotonic x = 0..255, both engines at once)
// is pair-packed into a small per-engine MLAB line accumulator (2 banks);
// a drain FSM bursts finished lines to DDR3 through ddram ch5, whose
// ch5_next strobe advances the (asynchronous-read) feeder word index.
//
// Read side: the scanout (CLK_VIDEO) requests both screen lines for row V+1
// during row V (toggle handshake into clk_sys). The pager bursts each line
// from DDR3 through ddram ch6 into a dual-clock line buffer. Each
// {row-parity,screen} has two slots: DDR fills the inactive slot and promotes
// it only after all 128 pairs arrive. Scanout therefore sees either the old
// complete line or the new complete line, never a partially fetched mixture
// when DDR arbitration misses the nominal 31.8us deadline.
//
// DDR3 layout: 32bpp {14'b0, BGR666} pixels, two per 64-bit beat;
// line = 1 KB, screen s in frame bank f at
// FB_HW_BASE(bytes) + f*0x80000 + s*0x40000. The renderer writes one bank
// for a complete paired frame while scanout reads the last complete bank.
// Four banks let the next source frame start without overwriting the displayed
// frame, an unacknowledged publication, or a complete frame still draining.
// If all four are live, the source frame is discarded instead of reusing an
// immutable bank.
//

module nds_nitro_fb_ddr3 #(
	parameter [27:1] FB_HW_BASE = 27'h7F00000,  // byte address 0x0FE00000 >> 1
	parameter [27:1] ENGINE_B_HW_BASE = 27'h7EC0000,
	parameter  [7:0] FB_BURST   = 8'd128,       // beats per command (divisor of 128)
	parameter        RUNTIME_TELEMETRY = 1'b0
)(
	input             clk_sys,
	input             CLK_VIDEO,
	input             reset_sys,
	input             reset_video,

	// engine pixel streams (clk_sys)
	input       [7:0] pix_x,
	input       [7:0] pix_y,
	input      [17:0] pix_d,
	input             pix_we,
	input       [7:0] pixb_x,
	input       [7:0] pixb_y,
	input      [17:0] pixb_d,
	input             pixb_we,
	// Sticky fault from the clk1x -> clk_sys pixel boundary.
	input             source_fault,
	// Verified cartridge session, already in clk_sys.
	input      [31:0] telemetry_session,
	// ARM full-video mode writes complete immutable banks directly. Local
	// pixel drains are disabled from reset; each accepted descriptor publishes
	// one bank and is acknowledged only after scanout adopts it.
	input             external_frame_mode,
	input             external_frame_publish,
	input       [1:0] external_frame_bank,
	output reg        external_frame_adopted,

	// Diagnostic-only words periodically forced into top line 191. This
	// bypasses the engine streams so state remains visible if rendering stalls.
	input      [17:0] dbg0,
	input      [17:0] dbg1,
	input      [17:0] dbg2,
	input      [17:0] dbg3,
	input      [17:0] dbg4,
	input      [17:0] dbg5,
	input      [17:0] dbg6,
	input      [17:0] dbg7,
	input      [17:0] dbg8,
	input      [17:0] dbg9,
	input      [17:0] dbg10,
	input      [17:0] dbg11,

	// scanout prefetch request (CLK_VIDEO): payload written with the toggle
	input             pf_tgl,
	input             pf_scr,
	input       [7:0] pf_line,
	input             pf_bank,
	input       [1:0] pf_frame_bank,
	input             pf_external,

	// Last completely drained, order-valid top+bottom frame pair (clk_sys).
	// Scanout synchronizes and adopts this bank only at its own frame boundary.
	output reg        published_frame_toggle,
	output reg  [1:0] published_frame_bank,
	// Diagnostic count of an in-flight scanout read still owning DDR when a
	// newer target row arrives. Such a read has missed its one-line deadline
	// and can overwrite the parity bank while that row is being displayed.
	output reg  [7:0] scanout_late_count,
	// Sticky pixel/order/line/descriptor/frame-pair fault receipt. This is a
	// compact observation of the existing internal checks, not new behavior.
	output wire [9:0] runtime_fault_flags,
	// Diagnostic-only snapshot of framebuffer-bank ownership plus sticky
	// violations. This is observational and does not affect arbitration.
	output wire [27:0] bank_diagnostic,

	// scanout fetch: pair address {row parity, screen, x[7:1]}
	input       [8:0] lb_raddr,
	output reg [35:0] lb_q,

	// ddram ch5: framebuffer write bursts (clk_sys)
	output     [27:1] fb5_addr,
	output     [63:0] fb5_din,
	output            fb5_req,
	input             fb5_next,
	input             fb5_ready,

	// ddram ch6: scanout prefetch read bursts (clk_sys)
	output     [27:1] fb6_addr,
	output            fb6_req,
	input      [63:0] fb6_dout,
	input             fb6_valid,
	input             fb6_ready
);

// ---- write side: merge bursts -> pair-packed line accumulators ----
// MLAB (async read) so the ch5 burst feeder needs no read-latency
// pipeline; per engine: 2 banks x 128 pixel pairs, 36 bits each. The
// engine always writes the bank the drain is not reading.
// Sync-read M10K (was MLAB): frees all 32 Memory LABs on the LAB-saturated
// device — the headroom the HDMI setup path needs. The drain feeder reads
// one word ahead (see feed_idx below) so the registered output holds
// mem[widx] every cycle, exactly matching the old async-read feeder timing
// into fb5_din. The engine always writes the bank the drain is not reading,
// so read and write never alias the same address (no_rw_check).
(* ramstyle = "M10K, no_rw_check" *) reg [35:0] acc_a[0:255];
(* ramstyle = "M10K, no_rw_check" *) reg [35:0] acc_b[0:255];
reg [17:0] hold_a, hold_b;            // even pixel awaiting its odd partner
reg        bank_a = 0, bank_b = 0;
reg  [1:0] render_frame_bank_a = 0, render_frame_bank_b = 0;
reg        render_frame_writable_a = 0, render_frame_writable_b = 0;
reg        job_tgl_a = 0, job_tgl_b = 0;
reg  [7:0] job_y_a, job_y_b;
reg        job_bank_a, job_bank_b;
reg  [1:0] job_frame_bank_a, job_frame_bank_b;

// ---- drain FSM: one pending line per engine -> ch5 write bursts ----
reg        dbusy = 0;
reg        dscr;                      // 0 = top screen (A), 1 = bottom (B)
reg  [7:0] dy;
reg        dbank;
reg  [1:0] dframe_bank;
reg  [6:0] widx;                      // feeder word (pixel pair) index
reg  [7:0] dsent;                     // beats already commanded this line
reg        drr = 0;                   // round-robin when both engines pend
reg        ack_a = 0, ack_b = 0;
reg        fb5_req_r = 0;
localparam [1:0] TJ_NORMAL = 2'd0;
localparam [1:0] TJ_LEGACY = 2'd1;
localparam [1:0] TJ_RUNTIME = 2'd2;
reg  [1:0] tjob_kind = TJ_NORMAL;
reg [21:0] telem_ctr = 0;
// NDS_FB_TELEMETRY: the telemetry burst below is a DEBUG-ONLY hack and it is
// VISIBLE. It reuses the ordinary line drain, so it writes a full 128-word
// (256-pixel) burst to screen A line 191 - the last visible scanline of the top
// screen - but telem_q_r only carries real data for feed_idx 0..5. Every word
// past that is {36{1'b1}}, i.e. white. telem_ctr is 22 bits at clk_sys
// (33.514 MHz), so that line is blown white every ~125 ms: an 8 Hz flicker
// along the bottom of the top screen.
//
// Off by default. Define NDS_FB_TELEMETRY to get the twelve state words back at
// 0x3FE2FC20 for devmem/SSH probing (see the NDS.sv dbg0..dbg11 map) - it is
// still the only channel that reports the main-RAM verify result without
// depending on rendering.
`ifdef NDS_FB_TELEMETRY
reg        telem_pending = 1;
`else
reg        telem_pending = 0;
`endif

// Optional debug telemetry uses two full ch5 bursts to screen-A padding line
// 192: hardware byte 0x0FE30000, HPS physical 0x3FE30000. Seqlock is word 0,
// so the odd marker is the first beat written. The even copy starts only after
// the complete odd copy is accepted. Bytes 32..1023 are zero. The legacy
// NDS_FB_TELEMETRY macro keeps its visible line-191 behavior only when the
// debug parameter is disabled. The alpha product sets RUNTIME_TELEMETRY to 0,
// which lets synthesis remove this complete cone.
localparam [31:0] RUNTIME_MAGIC = 32'h4e445446; // "NDTF"
localparam [31:0] RUNTIME_VERSION = 32'd2;
localparam [2:0] RP_IDLE = 3'd0;
localparam [2:0] RP_ODD_PENDING = 3'd1;
localparam [2:0] RP_ODD_ACTIVE = 3'd2;
localparam [2:0] RP_EVEN_PENDING = 3'd3;
localparam [2:0] RP_EVEN_ACTIVE = 3'd4;
reg [2:0] runtime_pub_state = RP_IDLE;
reg runtime_job_even = 0;
reg runtime_initialized = 0;
reg [31:0] runtime_even_seq = 0;
reg [31:0] runtime_snapshot_seq = 0;
reg [31:0] runtime_snapshot_clean = 0;
reg [31:0] runtime_snapshot_changed = 0;
reg [31:0] runtime_snapshot_hash = 0;
reg [31:0] runtime_snapshot_faults = 0;
reg [31:0] runtime_snapshot_session = 0;
reg [31:0] runtime_last_clean = 0;
reg [31:0] runtime_last_changed = 0;
reg [31:0] runtime_last_hash = 0;
reg [31:0] runtime_last_faults = 0;
reg [31:0] runtime_last_session = 0;

// Each frame must contain exactly x=0..255 for ordered lines y=0..191.
// The descriptor made at the last pixel follows that screen's y=191 drain.
reg track_a = 0, track_b = 0;
reg synchronized_a = 0, synchronized_b = 0;
reg [7:0] expect_x_a = 0, expect_y_a = 0;
reg [7:0] expect_x_b = 0, expect_y_b = 0;
reg [31:0] frame_hash_a = 0, frame_hash_b = 0;
reg [31:0] frame_id_a = 0, frame_id_b = 0;
reg frame_bad_a = 0, frame_bad_b = 0;
reg order_fault_a = 0, order_fault_b = 0;
reg line_overrun_a = 0, line_overrun_b = 0;
reg desc_overrun_a = 0, desc_overrun_b = 0;
reg [31:0] desc_hash_a = 0, desc_hash_b = 0;
reg [31:0] desc_frame_a = 0, desc_frame_b = 0;
reg desc_good_a = 0, desc_good_b = 0;
reg desc_tgl_a = 0, desc_tgl_b = 0;
reg desc_ack_a = 0, desc_ack_b = 0;
reg desc_fault_a = 0, desc_fault_b = 0;
reg pair_fault = 0;

reg dframe_good = 0;
reg [31:0] dframe_id = 0;
reg [31:0] dframe_hash = 0;
reg frame_commit_strobe = 0;
reg frame_commit_scr = 0;
reg frame_commit_good = 0;
reg [1:0] frame_commit_bank = 0;
reg [31:0] frame_commit_id = 0;
reg [31:0] frame_commit_hash = 0;
reg commit_valid_a = 0, commit_valid_b = 0;
reg commit_good_a = 0, commit_good_b = 0;
reg [1:0] commit_bank_a = 0, commit_bank_b = 0;
reg [31:0] commit_id_a = 0, commit_id_b = 0;
reg [31:0] commit_hash_a = 0, commit_hash_b = 0;
reg [31:0] clean_frame_seq = 0;
reg [31:0] changed_frame_seq = 0;
reg [31:0] content_hash = 0;
reg content_hash_valid = 0;

// Product publication retains one completed screen descriptor.  The next
// opposite-screen descriptor must carry the same source frame ID and bank;
// matching only the rotating bank can pair descriptors from different frames
// after an incomplete frame and expose a bank while it is being overwritten.
reg display_commit_valid = 0;
reg display_commit_scr = 0;
reg display_commit_good = 0;
reg [1:0] display_commit_bank = 0;
reg [31:0] display_commit_frame = 0;
// One complete bank may wait for scanout, but it must remain immutable until
// the first prefetch from that bank proves the video domain adopted it.  The
// prefetch toggle is already the return handshake from CLK_VIDEO, so no
// additional clock-domain crossing is required.
reg publication_pending = 0;
reg [1:0] scanout_frame_bank = 0;
reg [2:0] pf_sync = 0;
reg scanout_bank_valid = 0;
reg scanout_write_collision = 0;
reg published_write_collision = 0;
reg midframe_bank_switch = 0;
reg render_bank_split = 0;
reg source_frame_discard = 0;

// faults[9:0] = source FIFO, pair, descriptor B/A, descriptor overrun B/A,
// line-job overrun B/A, pixel order B/A. All fault sources are sticky.
wire [31:0] runtime_faults = {
	22'd0, source_fault, pair_fault, desc_fault_b, desc_fault_a,
	desc_overrun_b, desc_overrun_a, line_overrun_b, line_overrun_a,
	order_fault_b, order_fault_a
};
assign runtime_fault_flags = runtime_faults[9:0];
wire pend_a = job_tgl_a != ack_a;
wire pend_b = job_tgl_b != ack_b;
wire legacy_pending = !RUNTIME_TELEMETRY && telem_pending;
wire runtime_job_pending = RUNTIME_TELEMETRY &&
	((runtime_pub_state == RP_ODD_PENDING) ||
	 (runtime_pub_state == RP_EVEN_PENDING));
wire accept_a_now = !dbusy && !runtime_job_pending && !legacy_pending &&
	pend_a && (!pend_b || !drr);
wire accept_b_now = !dbusy && !runtime_job_pending && !legacy_pending &&
	pend_b && !(pend_a && (!pend_b || !drr));
wire accept_desc_a_now = accept_a_now && (job_y_a == 8'd191) &&
	(desc_tgl_a != desc_ack_a);
wire accept_desc_b_now = accept_b_now && (job_y_b == 8'd191) &&
	(desc_tgl_b != desc_ack_b);
wire line_overrun_event_a = pix_we && (pix_x == 8'd255) &&
	pend_a && !accept_a_now;
wire line_overrun_event_b = pixb_we && (pixb_x == 8'd255) &&
	pend_b && !accept_b_now;

function automatic [31:0] frame_hash_step;
	input [31:0] prior;
	input [17:0] pixel;
	reg [31:0] rotated_xor;
	begin
		rotated_xor = {prior[24:0], prior[31:25]} ^ {14'd0, pixel};
		frame_hash_step = rotated_xor + 32'h9e3779b9;
	end
endfunction

function automatic [31:0] pair_hash;
	input [31:0] hash_a;
	input [31:0] hash_b;
	begin
		pair_hash = hash_a ^ {hash_b[12:0], hash_b[31:13]} ^ 32'h4e445346;
	end
endfunction

function automatic [1:0] next_frame_bank;
	input [1:0] current;
	begin
		next_frame_bank = current + 1'd1;
	end
endfunction

// A frame that loses a renderer line is deliberately not published, but it
// still writes its surviving lines into a scratch bank. Reuse that bank when
// it remains free; repeated incomplete frames must never wrap the four-bank
// ring into the bank scanout was told to display.
// A good final line can still be queued, actively draining, or waiting for
// its other screen before publication.  That bank is already immutable even
// though published_frame_bank has not advanced yet.  Exclude every such bank
// when the next source frame chooses its scratch target; otherwise scanout can
// adopt a completed bank after the renderer has begun overwriting it.
wire queued_complete_final_a = pend_a && (job_y_a == 8'd191) &&
	(desc_tgl_a != desc_ack_a) && desc_good_a;
wire queued_complete_final_b = pend_b && (job_y_b == 8'd191) &&
	(desc_tgl_b != desc_ack_b) && desc_good_b;
wire active_complete_final = dbusy && (tjob_kind == TJ_NORMAL) &&
	(dy == 8'd191) && dframe_good;
wire [3:0] reserved_frame_banks =
	(4'b0001 << scanout_frame_bank) |
	(publication_pending ? (4'b0001 << published_frame_bank) : 4'b0000) |
	(queued_complete_final_a ? (4'b0001 << job_frame_bank_a) : 4'b0000) |
	(queued_complete_final_b ? (4'b0001 << job_frame_bank_b) : 4'b0000) |
	(active_complete_final ? (4'b0001 << dframe_bank) : 4'b0000) |
	((display_commit_valid && display_commit_good) ?
		(4'b0001 << display_commit_bank) : 4'b0000);
wire source_frame_bank_available = reserved_frame_banks != 4'b1111;

function automatic [1:0] source_frame_bank;
	input [1:0] current;
	input [3:0] reserved;
	reg [1:0] following;
	reg [1:0] second;
	reg [1:0] third;
	begin
		following = next_frame_bank(current);
		second = next_frame_bank(following);
		third = next_frame_bank(second);
		if (!reserved[current])
			source_frame_bank = current;
		else if (!reserved[following])
			source_frame_bank = following;
		else if (!reserved[second])
			source_frame_bank = second;
		else if (!reserved[third])
			source_frame_bank = third;
		else
			source_frame_bank = current;
	end
endfunction

wire ordered_pixel_a = track_a && (pix_x == expect_x_a) &&
	(pix_y == expect_y_a);
wire ordered_pixel_b = track_b && (pixb_x == expect_x_b) &&
	(pixb_y == expect_y_b);
wire [31:0] next_hash_a = frame_hash_step(frame_hash_a, pix_d);
wire [31:0] next_hash_b = frame_hash_step(frame_hash_b, pixb_d);

always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		hold_a <= 0; hold_b <= 0;
		bank_a <= 0; bank_b <= 0;
		render_frame_bank_a <= 0; render_frame_bank_b <= 0;
		render_frame_writable_a <= 0; render_frame_writable_b <= 0;
		job_tgl_a <= 0; job_tgl_b <= 0;
		job_y_a <= 0; job_y_b <= 0;
		job_bank_a <= 0; job_bank_b <= 0;
		job_frame_bank_a <= 0; job_frame_bank_b <= 0;
		track_a <= 0; track_b <= 0;
		synchronized_a <= 0; synchronized_b <= 0;
		expect_x_a <= 0; expect_y_a <= 0;
		expect_x_b <= 0; expect_y_b <= 0;
		frame_hash_a <= 0; frame_hash_b <= 0;
		frame_id_a <= 0; frame_id_b <= 0;
		frame_bad_a <= 0; frame_bad_b <= 0;
		order_fault_a <= 0; order_fault_b <= 0;
		line_overrun_a <= 0; line_overrun_b <= 0;
		desc_overrun_a <= 0; desc_overrun_b <= 0;
		desc_hash_a <= 0; desc_hash_b <= 0;
		desc_frame_a <= 0; desc_frame_b <= 0;
		desc_good_a <= 0; desc_good_b <= 0;
		desc_tgl_a <= 0; desc_tgl_b <= 0;
	end else begin
		if (pix_we && !external_frame_mode) begin
			if (!pix_x[0]) hold_a <= pix_d;
			else acc_a[{bank_a, pix_x[7:1]}] <= {pix_d, hold_a};
			if (pix_x == 8'd255) begin
				if (render_frame_writable_a) begin
					job_tgl_a <= ~job_tgl_a;
					job_y_a <= pix_y;
					job_bank_a <= bank_a;
					job_frame_bank_a <= render_frame_bank_a;
				end
				bank_a <= ~bank_a;
				if (render_frame_writable_a && line_overrun_event_a) begin
					line_overrun_a <= 1;
					frame_bad_a <= 1;
				end
			end
			if (!track_a) begin
				if ((pix_x == 0) && (pix_y == 0)) begin
					render_frame_bank_a <= source_frame_bank(
						render_frame_bank_a, reserved_frame_banks);
					render_frame_writable_a <= source_frame_bank_available;
					track_a <= 1; synchronized_a <= 1;
					expect_x_a <= 1; expect_y_a <= 0;
					frame_hash_a <= frame_hash_step(32'h243f6a88, pix_d);
					frame_id_a <= frame_id_a + 1'd1;
					frame_bad_a <= !source_frame_bank_available;
				end else if (synchronized_a) order_fault_a <= 1;
			end else if (ordered_pixel_a) begin
				frame_hash_a <= next_hash_a;
				if (pix_x == 8'd255) begin
					if (pix_y == 8'd191) track_a <= 0;
					else begin expect_x_a <= 0; expect_y_a <= pix_y + 1'd1; end
				end else expect_x_a <= pix_x + 1'd1;
			end else begin
				order_fault_a <= 1; frame_bad_a <= 1; track_a <= 0;
				if ((pix_x == 0) && (pix_y == 0)) begin
					render_frame_bank_a <= source_frame_bank(
						render_frame_bank_a, reserved_frame_banks);
					render_frame_writable_a <= source_frame_bank_available;
					track_a <= 1; expect_x_a <= 1; expect_y_a <= 0;
					frame_hash_a <= frame_hash_step(32'h243f6a88, pix_d);
					frame_id_a <= frame_id_a + 1'd1;
					frame_bad_a <= !source_frame_bank_available;
				end
			end
			if (render_frame_writable_a &&
			    (pix_x == 8'd255) && (pix_y == 8'd191)) begin
				if ((desc_tgl_a != desc_ack_a) && !accept_desc_a_now)
					desc_overrun_a <= 1;
				desc_hash_a <= ordered_pixel_a ? next_hash_a : 0;
				desc_frame_a <= frame_id_a;
				desc_good_a <= ordered_pixel_a && !frame_bad_a &&
					!line_overrun_event_a;
				desc_tgl_a <= ~desc_tgl_a;
			end
		end

		if (pixb_we && !external_frame_mode) begin
			if (!pixb_x[0]) hold_b <= pixb_d;
			else acc_b[{bank_b, pixb_x[7:1]}] <= {pixb_d, hold_b};
			if (pixb_x == 8'd255) begin
				if (render_frame_writable_b) begin
					job_tgl_b <= ~job_tgl_b;
					job_y_b <= pixb_y;
					job_bank_b <= bank_b;
					job_frame_bank_b <= render_frame_bank_b;
				end
				bank_b <= ~bank_b;
				if (render_frame_writable_b && line_overrun_event_b) begin
					line_overrun_b <= 1;
					frame_bad_b <= 1;
				end
			end
			if (!track_b) begin
				if ((pixb_x == 0) && (pixb_y == 0)) begin
					render_frame_bank_b <= source_frame_bank(
						render_frame_bank_b, reserved_frame_banks);
					render_frame_writable_b <= source_frame_bank_available;
					track_b <= 1; synchronized_b <= 1;
					expect_x_b <= 1; expect_y_b <= 0;
					frame_hash_b <= frame_hash_step(32'h85a308d3, pixb_d);
					frame_id_b <= frame_id_b + 1'd1;
					frame_bad_b <= !source_frame_bank_available;
				end else if (synchronized_b) order_fault_b <= 1;
			end else if (ordered_pixel_b) begin
				frame_hash_b <= next_hash_b;
				if (pixb_x == 8'd255) begin
					if (pixb_y == 8'd191) track_b <= 0;
					else begin expect_x_b <= 0; expect_y_b <= pixb_y + 1'd1; end
				end else expect_x_b <= pixb_x + 1'd1;
			end else begin
				order_fault_b <= 1; frame_bad_b <= 1; track_b <= 0;
				if ((pixb_x == 0) && (pixb_y == 0)) begin
					render_frame_bank_b <= source_frame_bank(
						render_frame_bank_b, reserved_frame_banks);
					render_frame_writable_b <= source_frame_bank_available;
					track_b <= 1; expect_x_b <= 1; expect_y_b <= 0;
					frame_hash_b <= frame_hash_step(32'h85a308d3, pixb_d);
					frame_id_b <= frame_id_b + 1'd1;
					frame_bad_b <= !source_frame_bank_available;
				end
			end
			if (render_frame_writable_b &&
			    (pixb_x == 8'd255) && (pixb_y == 8'd191)) begin
				if ((desc_tgl_b != desc_ack_b) && !accept_desc_b_now)
					desc_overrun_b <= 1;
				desc_hash_b <= ordered_pixel_b ? next_hash_b : 0;
				desc_frame_b <= frame_id_b;
				desc_good_b <= ordered_pixel_b && !frame_bad_b &&
					!line_overrun_event_b;
				desc_tgl_b <= ~desc_tgl_b;
			end
		end
	end
end

// Feeder reads one word ahead: fb5_next advances widx (drain FSM below) on
// exactly the cycles a burst word is consumed, so feed_idx points at the
// word fb5_din must present next cycle. The M10K registered outputs then
// hold mem[widx] every cycle. telem_q is registered with the identical
// scheme so telemetry bursts stay beat-aligned with the normal feeder.
//
// Base case (grant5 can fire the same cycle fb5_req is asserted): on a
// job-start cycle, pre-read word[0] of the job being selected — feed_idx=0
// and racc uses the selected bank — so the registered output holds word[0]
// when the burst is granted next cycle. Zero added latency vs the old MLAB.
wire        starting = !dbusy &&
	(runtime_job_pending || legacy_pending || pend_a || pend_b);
wire        sel_bank = (runtime_job_pending || legacy_pending) ? 1'b0 :
                       (pend_a && (!pend_b || !drr))    ? job_bank_a : job_bank_b;
wire  [6:0] feed_idx = starting ? 7'd0 : (widx + (fb5_next ? 7'd1 : 7'd0));
wire  [7:0] racc     = {starting ? sel_bank : dbank, feed_idx};
reg  [35:0] acc_a_q, acc_b_q, telem_q_r;
reg  [63:0] runtime_q_r;
wire runtime_feeding_even =
	(starting && runtime_job_pending) ?
		(runtime_pub_state == RP_EVEN_PENDING) : runtime_job_even;
wire [31:0] runtime_feed_seq = runtime_snapshot_seq +
	(runtime_feeding_even ? 1'd1 : 1'd0);

always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		acc_a_q <= 0;
		acc_b_q <= 0;
		telem_q_r <= 0;
		runtime_q_r <= 0;
	end else begin
		acc_a_q   <= acc_a[racc];
		acc_b_q   <= acc_b[racc];
		telem_q_r <= (feed_idx == 7'd0) ? {dbg1, dbg0} :
		             (feed_idx == 7'd1) ? {dbg3, dbg2} :
		             (feed_idx == 7'd2) ? {dbg5, dbg4} :
		             (feed_idx == 7'd3) ? {dbg7, dbg6} :
		             (feed_idx == 7'd4) ? {dbg9, dbg8} :
		             (feed_idx == 7'd5) ? {dbg11, dbg10} : {36{1'b1}};
		case (feed_idx)
			7'd0: runtime_q_r <= {RUNTIME_MAGIC, runtime_feed_seq};
			7'd1: runtime_q_r <= {runtime_snapshot_clean, RUNTIME_VERSION};
			7'd2: runtime_q_r <= {runtime_snapshot_hash,
			                         runtime_snapshot_changed};
			7'd3: runtime_q_r <= {runtime_snapshot_session,
			                         runtime_snapshot_faults};
			default: runtime_q_r <= 64'd0;
		endcase
	end
end

wire [35:0] acc_q = dscr ? acc_b_q : acc_a_q;

assign fb5_req  = fb5_req_r;
assign fb5_din  = (tjob_kind == TJ_RUNTIME) ? runtime_q_r :
	              (tjob_kind == TJ_LEGACY) ?
		{14'd0, telem_q_r[35:18], 14'd0, telem_q_r[17:0]} :
		{14'd0, acc_q[35:18], 14'd0, acc_q[17:0]};
// Diagnostic jobs retain their fixed legacy addresses in bank zero. Only
// ordinary visible lines participate in the complete-frame bank handoff.
assign fb5_addr = FB_HW_BASE +
	{(tjob_kind == TJ_NORMAL) ? dframe_bank : 2'd0, dscr, dy, 9'd0} +
	{17'd0, dsent, 2'd0};

wire [31:0] committed_pair_hash_a =
	pair_hash(frame_commit_hash, commit_hash_b);
wire [31:0] committed_pair_hash_b =
	pair_hash(commit_hash_a, frame_commit_hash);

// Match the two screen descriptors after their final visible-line DDR jobs
// complete. clean_frame_seq measures fully rendered and committed frame pairs.
// changed_frame_seq advances only when the combined visible-content hash
// changes, so a static title screen has renderer FPS but zero changed FPS.
always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		commit_valid_a <= 0; commit_valid_b <= 0;
		commit_good_a <= 0; commit_good_b <= 0;
		commit_bank_a <= 0; commit_bank_b <= 0;
		commit_id_a <= 0; commit_id_b <= 0;
		commit_hash_a <= 0; commit_hash_b <= 0;
		clean_frame_seq <= 0; changed_frame_seq <= 0;
		content_hash <= 0; content_hash_valid <= 0;
		pair_fault <= 0;
	end else if (frame_commit_strobe) begin
		if (!frame_commit_scr) begin
			if (commit_valid_b && (frame_commit_id == commit_id_b)) begin
				commit_valid_a <= 0; commit_valid_b <= 0;
				if (frame_commit_bank != commit_bank_b) begin
					pair_fault <= 1;
				end else if (frame_commit_good && commit_good_b) begin
					clean_frame_seq <= clean_frame_seq + 1'd1;
					content_hash <= committed_pair_hash_a;
					if (!content_hash_valid ||
					    (content_hash != committed_pair_hash_a))
						changed_frame_seq <= changed_frame_seq + 1'd1;
					content_hash_valid <= 1;
				end
			end else if (commit_valid_b) begin
				pair_fault <= 1;
				if (frame_commit_id > commit_id_b) begin
					commit_valid_a <= 1; commit_valid_b <= 0;
					commit_good_a <= frame_commit_good;
					commit_bank_a <= frame_commit_bank;
					commit_id_a <= frame_commit_id;
					commit_hash_a <= frame_commit_hash;
				end else commit_valid_a <= 0;
			end else begin
				if (commit_valid_a) pair_fault <= 1;
				commit_valid_a <= 1;
				commit_good_a <= frame_commit_good;
				commit_bank_a <= frame_commit_bank;
				commit_id_a <= frame_commit_id;
				commit_hash_a <= frame_commit_hash;
			end
		end else begin
			if (commit_valid_a && (frame_commit_id == commit_id_a)) begin
				commit_valid_a <= 0; commit_valid_b <= 0;
				if (frame_commit_bank != commit_bank_a) begin
					pair_fault <= 1;
				end else if (frame_commit_good && commit_good_a) begin
					clean_frame_seq <= clean_frame_seq + 1'd1;
					content_hash <= committed_pair_hash_b;
					if (!content_hash_valid ||
					    (content_hash != committed_pair_hash_b))
						changed_frame_seq <= changed_frame_seq + 1'd1;
					content_hash_valid <= 1;
				end
			end else if (commit_valid_a) begin
				pair_fault <= 1;
				if (frame_commit_id > commit_id_a) begin
					commit_valid_b <= 1; commit_valid_a <= 0;
					commit_good_b <= frame_commit_good;
					commit_bank_b <= frame_commit_bank;
					commit_id_b <= frame_commit_id;
					commit_hash_b <= frame_commit_hash;
				end else commit_valid_b <= 0;
			end else begin
				if (commit_valid_b) pair_fault <= 1;
				commit_valid_b <= 1;
				commit_good_b <= frame_commit_good;
				commit_bank_b <= frame_commit_bank;
				commit_id_b <= frame_commit_id;
				commit_hash_b <= frame_commit_hash;
			end
		end
	end
end

// Publish only after both order-valid screen-final line jobs have completed.
// Keep one publication outstanding until scanout's line-prefetch handshake
// acknowledges that bank.  A faster source may continue rendering into the
// third scratch bank, but complete intermediate frames are deliberately
// dropped instead of replacing a bank that scanout may already have selected.
wire scanout_prefetch_event = pf_sync[2] != pf_sync[1];
wire scanout_adopts_publication = publication_pending &&
	scanout_prefetch_event && (pf_frame_bank == published_frame_bank);
wire publication_slot_available = !publication_pending ||
	scanout_adopts_publication;
always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		display_commit_valid <= 0;
		display_commit_scr <= 0;
		display_commit_good <= 0;
		display_commit_bank <= 0;
		display_commit_frame <= 0;
		published_frame_toggle <= 0;
		published_frame_bank <= 0;
		publication_pending <= 0;
		external_frame_adopted <= 0;
	end else begin
		external_frame_adopted <= 0;
		if (scanout_adopts_publication) begin
			publication_pending <= 0;
			if (external_frame_mode)
				external_frame_adopted <= 1;
		end
		if (external_frame_mode) begin
			display_commit_valid <= 0;
			if (external_frame_publish &&
			    (!publication_pending || scanout_adopts_publication)) begin
				published_frame_toggle <= ~published_frame_toggle;
				published_frame_bank <= external_frame_bank;
				publication_pending <= 1;
			end
		end else if (dbusy && fb5_ready && (tjob_kind == TJ_NORMAL) &&
		    (dy == 8'd191)) begin
			if (display_commit_valid && (display_commit_scr != dscr) &&
			    (display_commit_frame == dframe_id)) begin
				display_commit_valid <= 0;
				if (display_commit_good && dframe_good &&
				    (display_commit_bank == dframe_bank) &&
				    publication_slot_available) begin
					published_frame_toggle <= ~published_frame_toggle;
					published_frame_bank <= dframe_bank;
					publication_pending <= 1;
				end
			end else begin
				display_commit_valid <= 1;
				display_commit_scr <= dscr;
				display_commit_good <= dframe_good;
				display_commit_bank <= dframe_bank;
				display_commit_frame <= dframe_id;
			end
		end
	end
end

wire runtime_snapshot_needed = !runtime_initialized ||
	(clean_frame_seq != runtime_last_clean) ||
	(changed_frame_seq != runtime_last_changed) ||
	(content_hash != runtime_last_hash) ||
	(runtime_faults != runtime_last_faults) ||
	(telemetry_session != runtime_last_session);

always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		dbusy <= 0;
		dscr <= 0;
		dy <= 0;
		dbank <= 0;
		dframe_bank <= 0;
		widx <= 0;
		dsent <= 0;
		drr <= 0;
		ack_a <= 0;
		ack_b <= 0;
		fb5_req_r <= 0;
		tjob_kind <= TJ_NORMAL;
		telem_ctr <= 0;
		telem_pending <= 0;
		desc_ack_a <= 0; desc_ack_b <= 0;
		desc_fault_a <= 0; desc_fault_b <= 0;
		dframe_good <= 0; dframe_id <= 0; dframe_hash <= 0;
		frame_commit_strobe <= 0; frame_commit_scr <= 0;
		frame_commit_good <= 0; frame_commit_bank <= 0;
		frame_commit_id <= 0;
		frame_commit_hash <= 0;
		runtime_pub_state <= RP_IDLE;
		runtime_job_even <= 0;
		runtime_initialized <= 0;
		runtime_even_seq <= 0;
		runtime_snapshot_seq <= 0;
		runtime_snapshot_clean <= 0;
		runtime_snapshot_changed <= 0;
		runtime_snapshot_hash <= 0;
		runtime_snapshot_faults <= 0;
		runtime_snapshot_session <= 0;
		runtime_last_clean <= 0;
		runtime_last_changed <= 0;
		runtime_last_hash <= 0;
		runtime_last_faults <= 0;
		runtime_last_session <= 0;
	end else begin
	telem_ctr <= telem_ctr + 1'd1;
`ifdef NDS_FB_TELEMETRY
	if (&telem_ctr) telem_pending <= 1;
`endif
	fb5_req_r <= 0;
	frame_commit_strobe <= 0;

	if (RUNTIME_TELEMETRY && (runtime_pub_state == RP_IDLE) &&
	    runtime_snapshot_needed) begin
		runtime_snapshot_seq <= runtime_even_seq + 1'd1;
		runtime_snapshot_clean <= clean_frame_seq;
		runtime_snapshot_changed <= changed_frame_seq;
		runtime_snapshot_hash <= content_hash;
		runtime_snapshot_faults <= runtime_faults;
		runtime_snapshot_session <= telemetry_session;
		runtime_pub_state <= RP_ODD_PENDING;
	end

	if (!dbusy) begin
		if (runtime_job_pending) begin
			dscr          <= 0;
			dy            <= 8'd192;
			dbank         <= 0;
			widx          <= 0;
			dsent         <= 0;
			tjob_kind     <= TJ_RUNTIME;
			runtime_job_even <= (runtime_pub_state == RP_EVEN_PENDING);
			runtime_pub_state <=
				(runtime_pub_state == RP_EVEN_PENDING) ?
				RP_EVEN_ACTIVE : RP_ODD_ACTIVE;
			fb5_req_r     <= 1;
			dbusy         <= 1;
		end
		else if (legacy_pending) begin
			dscr          <= 0;
			dy            <= 8'd191;
			dbank         <= 0;
			widx          <= 0;
			dsent         <= 0;
			tjob_kind     <= TJ_LEGACY;
			telem_pending <= 0;
			fb5_req_r     <= 1;
			dbusy         <= 1;
		end
		else if (pend_a && (!pend_b || !drr)) begin
			dscr      <= 0;
			dy        <= job_y_a;
			dbank     <= job_bank_a;
			dframe_bank <= job_frame_bank_a;
			ack_a     <= job_tgl_a;
			drr       <= 1;
			widx      <= 0;
			dsent     <= 0;
			fb5_req_r <= 1;
			dbusy     <= 1;
			tjob_kind <= TJ_NORMAL;
			if (job_y_a == 8'd191) begin
				if (desc_tgl_a != desc_ack_a) begin
					dframe_good <= desc_good_a;
					dframe_id <= desc_frame_a;
					dframe_hash <= desc_hash_a;
					desc_ack_a <= desc_tgl_a;
				end else begin
					dframe_good <= 0; dframe_id <= 0; dframe_hash <= 0;
					desc_fault_a <= 1;
				end
			end else dframe_good <= 0;
		end
		else if (pend_b) begin
			dscr      <= 1;
			dy        <= job_y_b;
			dbank     <= job_bank_b;
			dframe_bank <= job_frame_bank_b;
			ack_b     <= job_tgl_b;
			drr       <= 0;
			widx      <= 0;
			dsent     <= 0;
			fb5_req_r <= 1;
			dbusy     <= 1;
			tjob_kind <= TJ_NORMAL;
			if (job_y_b == 8'd191) begin
				if (desc_tgl_b != desc_ack_b) begin
					dframe_good <= desc_good_b;
					dframe_id <= desc_frame_b;
					dframe_hash <= desc_hash_b;
					desc_ack_b <= desc_tgl_b;
				end else begin
					dframe_good <= 0; dframe_id <= 0; dframe_hash <= 0;
					desc_fault_b <= 1;
				end
			end else dframe_good <= 0;
		end
	end
	else begin
		if (fb5_next) widx <= widx + 1'd1;
		if (fb5_ready) begin
			if (dsent + FB_BURST >= 8'd128) begin
				dbusy <= 0;
				if (tjob_kind == TJ_RUNTIME) begin
					if (runtime_pub_state == RP_ODD_ACTIVE)
						runtime_pub_state <= RP_EVEN_PENDING;
					else begin
						runtime_pub_state <= RP_IDLE;
						runtime_even_seq <= runtime_snapshot_seq + 1'd1;
						runtime_initialized <= 1;
						runtime_last_clean <= runtime_snapshot_clean;
						runtime_last_changed <= runtime_snapshot_changed;
						runtime_last_hash <= runtime_snapshot_hash;
						runtime_last_faults <= runtime_snapshot_faults;
						runtime_last_session <= runtime_snapshot_session;
					end
				end else if ((tjob_kind == TJ_NORMAL) &&
				             (dy == 8'd191)) begin
					frame_commit_strobe <= 1;
					frame_commit_scr <= dscr;
					frame_commit_good <= dframe_good;
					frame_commit_bank <= dframe_bank;
					frame_commit_id <= dframe_id;
					frame_commit_hash <= dframe_hash;
				end
			end
			else begin
				dsent     <= dsent + FB_BURST;
				fb5_req_r <= 1;
			end
		end
	end
	end
end

// ---- read side: scanout line prefetch -> ch6 read bursts ----
reg [35:0] linebuf[0:1023]; // 2 parities x 2 screens x 2 slots x 128 pairs
// The video domain cannot be backpressured. Retain the two screen requests
// for the newest output row, but never replay an older row after the next
// row's request arrives. The line RAM is indexed only by row parity: a late
// old-row read would otherwise overwrite the parity bank now being displayed
// and produce visible horizontal jumps. Two entries are sufficient because
// scanout emits exactly A then B for each target row.
reg [12:0] pf_q0, pf_q1;
reg  [2:0] pf_count = 0;
reg        rbusy = 0;
reg        rscr;
reg  [7:0] rline;
reg        rbank;
reg  [1:0] rframe_bank;
reg        rexternal;
reg        rslot;
reg        r_obsolete;
reg  [6:0] rwidx;
reg  [7:0] rsent;
reg        fb6_req_r = 0;
reg  [3:0] active_line_slot = 0;

// E[27:0] is sampled only by diagnostic builds through the existing FPGA
// heartbeat. The upper fields show live bank ownership; the low flags latch
// exactly the illegal aliases that could make an old BG position reappear.
assign bank_diagnostic = {
	scanout_frame_bank, published_frame_bank,
	render_frame_bank_a, render_frame_bank_b,
	dframe_bank, rframe_bank, reserved_frame_banks,
	publication_pending, dbusy, rbusy, source_frame_bank_available,
	scanout_write_collision, published_write_collision,
	midframe_bank_switch, render_bank_split, source_frame_discard,
	(scanout_late_count != 0), 2'b00
};

wire scanout_read_late = scanout_prefetch_event && rbusy &&
	((pf_external != rexternal) ||
	 (pf_frame_bank != rframe_bank) || (pf_line != rline));

assign fb6_req  = fb6_req_r;
assign fb6_addr = (rexternal ?
	ENGINE_B_HW_BASE + {rframe_bank[0], rline, 9'd0} :
	FB_HW_BASE + {rframe_bank, rscr, rline, 9'd0}) +
	{17'd0, rsent, 2'd0};

always @(posedge clk_sys or posedge reset_sys) begin
	if (reset_sys) begin
		pf_sync <= 0;
		scanout_frame_bank <= 0;
		scanout_bank_valid <= 0;
		scanout_write_collision <= 0;
		published_write_collision <= 0;
		midframe_bank_switch <= 0;
		render_bank_split <= 0;
		source_frame_discard <= 0;
		pf_q0 <= 0;
		pf_q1 <= 0;
		pf_count <= 0;
		rbusy <= 0;
		rscr <= 0;
		rline <= 0;
		rbank <= 0;
		rframe_bank <= 0;
		rexternal <= 0;
		rslot <= 0;
		r_obsolete <= 0;
		rwidx <= 0;
		rsent <= 0;
		fb6_req_r <= 0;
		scanout_late_count <= 0;
		active_line_slot <= 0;
	end else begin
	pf_sync <= {pf_sync[1:0], pf_tgl};
	fb6_req_r <= 0;
	if (fb5_req_r && (tjob_kind == TJ_NORMAL) &&
	    scanout_bank_valid && (dframe_bank == scanout_frame_bank))
		scanout_write_collision <= 1;
	if (fb5_req_r && (tjob_kind == TJ_NORMAL) && publication_pending &&
	    (dframe_bank == published_frame_bank))
		published_write_collision <= 1;
	if (scanout_prefetch_event && !pf_external && scanout_bank_valid &&
	    (pf_frame_bank != scanout_frame_bank) &&
	    !(pf_scr == 1'b0 && pf_line == 8'd0))
		midframe_bank_switch <= 1;
	if (track_a && track_b &&
	    (render_frame_bank_a != render_frame_bank_b))
		render_bank_split <= 1;
	if (((pix_we && pix_x == 8'd0 && pix_y == 8'd0) ||
	     (pixb_we && pixb_x == 8'd0 && pixb_y == 8'd0)) &&
	    !source_frame_bank_available)
		source_frame_discard <= 1;
	if (scanout_read_late && scanout_late_count != 8'hff)
		scanout_late_count <= scanout_late_count + 1'd1;
	if (scanout_read_late)
		r_obsolete <= 1;
	case ({scanout_prefetch_event, (pf_count != 0) && !rbusy})
		2'b10: begin
			if (pf_count == 0) begin
				pf_q0 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 1;
			end else if (pf_q0[8:1] == pf_line &&
			             pf_q0[0] != pf_scr) begin
				// The opposite screen for the same target row remains useful.
				pf_q1 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 2;
			end else begin
				// A newer target row makes every queued older row obsolete.
				pf_q0 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 1;
			end
		end
		2'b01: begin
			pf_q0 <= pf_q1;
			pf_count <= pf_count - 1'd1;
		end
		2'b11: begin
			if (pf_count == 1) begin
				pf_q0 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 1;
			end else if (pf_q1[8:1] == pf_line &&
			             pf_q1[0] != pf_scr) begin
				pf_q0 <= pf_q1;
				pf_q1 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 2;
			end else begin
				pf_q0 <= {pf_external,pf_frame_bank,pf_bank,pf_line,pf_scr};
				pf_count <= 1;
			end
		end
		default: begin end
	endcase
	if (scanout_prefetch_event && !pf_external) begin
		scanout_frame_bank <= pf_frame_bank;
		scanout_bank_valid <= 1;
	end
	if ((pf_count != 0) && !rbusy) begin
		{rexternal,rframe_bank,rbank,rline,rscr} <= pf_q0;
		rslot <= ~active_line_slot[{pf_q0[9], pf_q0[0]}];
		r_obsolete <= 0;
		rwidx     <= 0;
		rsent     <= 0;
		fb6_req_r <= 1;
		rbusy     <= 1;
	end
	if (rbusy && fb6_valid) begin
		linebuf[{rbank, rscr, rslot, rwidx}] <=
			{fb6_dout[49:32], fb6_dout[17:0]};
		rwidx <= rwidx + 1'd1;
	end
	if (rbusy && fb6_ready) begin
		if (rsent + FB_BURST >= 8'd128) begin
			rbusy <= 0;
			// A newer target row makes this completed fetch obsolete. Keep
			// the previously promoted complete line rather than expose stale
			// data at the new row's parity slot.
			if (!r_obsolete && !scanout_read_late)
				active_line_slot[{rbank, rscr}] <= rslot;
		end
		else begin
			rsent     <= rsent + FB_BURST;
			fb6_req_r <= 1;
		end
	end
	end
end

// ---- scanout fetch: runs every clock, pair stable 4 clocks per dot ----
(* async_reg = "true" *) reg [3:0] active_line_slot_meta = 0;
(* async_reg = "true" *) reg [3:0] active_line_slot_sync = 0;
reg [3:0] video_line_slot = 0;
wire [1:0] lb_line_index = lb_raddr[8:7];
wire lb_slot = (lb_raddr[6:0] == 7'd0) ?
	active_line_slot_sync[lb_line_index] : video_line_slot[lb_line_index];
always @(posedge CLK_VIDEO or posedge reset_video) begin
	if (reset_video) begin
		lb_q <= 0;
		active_line_slot_meta <= 0;
		active_line_slot_sync <= 0;
		video_line_slot <= 0;
	end else begin
		active_line_slot_meta <= active_line_slot;
		active_line_slot_sync <= active_line_slot_meta;
		// Hold the chosen complete slot for the full visible row. A DDR
		// completion in the middle of scanout takes effect at the next x=0
		// instead of creating a horizontal seam.
		if (lb_raddr[6:0] == 7'd0)
			video_line_slot[lb_line_index] <=
				active_line_slot_sync[lb_line_index];
		lb_q <= linebuf[{lb_raddr[8:7], lb_slot, lb_raddr[6:0]}];
	end
end

endmodule
