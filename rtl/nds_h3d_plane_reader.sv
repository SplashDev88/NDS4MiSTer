`timescale 1ps/1ps

// Clock-safe H3D1 frame descriptor and scan-line reader.
//
// The DDR port and the Nitro GPU2D pixel port have unrelated clocks.  This
// block consequently has no combinational or single-clock shortcut between
// them:
//
//   * descriptor and line requests cross through a four-entry asynchronous
//     FIFO;
//   * the DDR side fills one of three logical 256x32 line banks;
//   * each logical bank is implemented as even/odd 128x32 simple dual-port
//     memories, allowing one 64-bit DDR beat to be written per DDR clock and
//     one 32-bit pixel to be read per pixel clock;
//   * a completed bank is published with a bundled, stable tag and a ready
//     toggle, and is not written again until its acknowledge toggle returns;
//   * the pixel side selects a complete bank only at line_start.  A line that
//     is absent at that deadline remains transparent through line_end.
//
// HPS publishes a descriptor by making frame_publish_sequence odd, writing
// the descriptor, then publishing the final nonzero even sequence.  The FPGA
// accepts only two identical sequence reads around the four descriptor beats.
// Every line fetch snapshots the accepted descriptor and DDR-domain session,
// then revalidates both after all 128 beats before publishing the line.
//
// The product QIP instantiates this between the 60 MHz DDR fabric and the
// Nitro clk1x engine-A merge seam.  Both resets must be asserted together;
// each may deassert synchronously to its own clock at a different time.  A
// reset recovery or ownership discontinuity must also use a new session
// value.
module nds_h3d_plane_reader #(
    parameter logic [28:0] CONTROL_BASE_WORD = 29'h01f80000,
    parameter logic [28:0] BANK0_BASE_WORD = 29'h01fa0000,
    parameter logic [28:0] BANK1_BASE_WORD = 29'h01fa8000,
    parameter logic [31:0] PIXEL_FORMAT = 32'd1
) (
    input  logic        ddr_clk,
    input  logic        ddr_reset,
    input  logic        pixel_clk,
    input  logic        pixel_reset,

    // Domain-local copies of the session epoch.  The surrounding reset/
    // session owner must update each copy synchronously in its own domain.
    input  logic [31:0] ddr_session,
    input  logic [31:0] pixel_session,

    // Pixel-domain request source.  Hold a request and its payload until the
    // corresponding ready is high.  Descriptor requests have priority if
    // both request inputs are asserted in one pixel clock.
    input  logic        descriptor_request,
    output logic        descriptor_request_ready,
    input  logic        line_request,
    output logic        line_request_ready,
    input  logic [31:0] line_frame,
    input  logic [7:0]  line_y,

    // Pixel-domain architectural frame boundary. A newly verified HPS
    // descriptor is staged until this pulse so one scanout frame never mixes
    // two independently rendered 3D planes.
    input  logic        frame_boundary,

    // Raw architectural scanline position. This advances even when the
    // best-effort 2D renderer drops a drawline.
    input  logic        scanline_tick,
    input  logic [7:0]  scanline_y,

    // Pixel-domain merge-line interface.  line_start is the availability
    // deadline and may accompany pixel_x=0.  line_end may accompany x=255;
    // that final registered read remains valid after the bank is released.
    input  logic        line_start,
    input  logic        line_end,
    input  logic [31:0] merge_frame,
    input  logic [7:0]  merge_y,
    input  logic [7:0]  pixel_x,
    output logic        line_valid,
    output logic [1:0]  line_bank,
    output logic [31:0] pixel_packed,
    output logic        pixel_valid,
    // Pixel-domain pulse when a valid plane has no matching completed line
    // at the merge deadline. This is the event that makes 3D transparent for
    // one complete scanline; DDR-side line_missed does not cover it.
    output logic        pixel_line_missed,
    // Counts from the last completed visible frame: matching lines, misses
    // with no completed bank, misses with current banks for another Y, and
    // misses where only stale descriptor-tagged banks were present. The first
    // three fields cannot exceed 192; the stale count saturates at 15.
    output logic [27:0] pixel_frame_diagnostic,

    // DDR-domain status pulses/state.
    output logic        busy,
    output logic        descriptor_busy,
    output logic        line_fetch_busy,
    output logic        descriptor_accepted,
    output logic        descriptor_rejected,
    output logic        line_loaded,
    output logic        line_missed,
    output logic        active_descriptor_valid,
    output logic [31:0] active_descriptor_sequence,
    output logic [31:0] active_descriptor_frame,
    output logic        active_descriptor_bank,

    // Pixel-domain copy of the descriptor, transferred by bundled-data
    // ready/ack handshake rather than by sampling the DDR registers live.
    output logic        pixel_descriptor_valid,
    output logic        pixel_descriptor_pending,
    output logic [31:0] pixel_descriptor_sequence,
    output logic [31:0] pixel_descriptor_frame,
    output logic        pixel_descriptor_bank,

    // Complete ARM-rendered framebuffer publication. The bank is already
    // immutable in shared DDR. ACK is deferred until scanout confirms that
    // it adopted this publication, so HPS cannot recycle the live bank.
    output logic        full_frame_publish,
    output logic [1:0]  full_frame_bank,
    input  logic        full_frame_adopted,

    // MiSTer DDR client port.  command_accepted means that the command has
    // reached the physical DDR port, not merely an outer arbiter queue.
    output logic        ddram_active,
    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic        ddram_command_accepted,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    localparam logic [28:0] PUBLISH_SEQUENCE_WORD = 29'd6;
    localparam logic [28:0] ACK_SEQUENCE_WORD = 29'd7;
    localparam logic [28:0] DESCRIPTOR_WORD = 29'd8;
    localparam logic [31:0] EXPECTED_WIDTH_HEIGHT = 32'h00c00100;
    localparam logic [31:0] EXPECTED_STRIDE = 32'd1024;
    localparam logic [31:0] FULL_FRAME_PIXEL_FORMAT = 32'd2;
    localparam logic [7:0] LINE_BURST_WORDS = 8'd128;
    localparam integer REQUEST_WIDTH = 89;

    typedef enum logic [3:0] {
        IDLE,
        DESC_SEQUENCE0_ISSUE,
        DESC_SEQUENCE0_WAIT,
        DESC_BODY_ISSUE,
        DESC_BODY_WAIT,
        DESC_SEQUENCE1_ISSUE,
        DESC_SEQUENCE1_WAIT,
        DESC_ACK_ISSUE,
        LINE_ISSUE,
        LINE_WAIT
    } state_t;
    state_t state;

    // ---------------------------------------------------------------------
    // Pixel-to-DDR request FIFO.
    // Entry: {descriptor, session, frame, y, scanline_generation_gray}.
    // The generation lets the DDR side discard queued visible-line work whose
    // fixed raster deadline has passed. Product requests are issued two lines
    // ahead, so age one still has a full scanline of useful slack; age two is
    // obsolete. The wider counter prevents normal stalls from reviving an old
    // request at the former eight-bit wrap. Descriptor traffic remains
    // lossless.
    // ---------------------------------------------------------------------
    logic [REQUEST_WIDTH-1:0] request_write_data;
    logic request_write;
    logic request_write_ready;
    logic [REQUEST_WIDTH-1:0] request_read_data;
    logic request_read_valid;
    logic request_read;

    wire request_is_descriptor = request_read_data[88];
    wire [31:0] request_session = request_read_data[87:56];
    wire [31:0] request_frame = request_read_data[55:24];
    wire [7:0] request_y = request_read_data[23:16];
    wire [15:0] request_scanline_generation_gray = request_read_data[15:0];

    logic [15:0] scanline_generation_binary_pixel;
    logic [15:0] scanline_generation_gray_pixel;
    (* async_reg = "true" *) logic [15:0] scanline_generation_gray_ddr_meta;
    (* async_reg = "true" *) logic [15:0] scanline_generation_gray_ddr_sync;

    function automatic logic [15:0] binary_to_gray(
        input logic [15:0] value
    );
        binary_to_gray = (value >> 1) ^ value;
    endfunction

    function automatic logic [15:0] gray_to_binary(
        input logic [15:0] value
    );
        integer bit_index;
        begin
            gray_to_binary[15] = value[15];
            for (bit_index = 14; bit_index >= 0; bit_index = bit_index - 1)
                gray_to_binary[bit_index] =
                    gray_to_binary[bit_index + 1] ^ value[bit_index];
        end
    endfunction

    always_ff @(posedge pixel_clk) begin
        if (pixel_reset) begin
            scanline_generation_binary_pixel <= 16'd0;
            scanline_generation_gray_pixel <= 16'd0;
        end else if (scanline_tick) begin
            scanline_generation_binary_pixel <=
                scanline_generation_binary_pixel + 1'b1;
            scanline_generation_gray_pixel <= binary_to_gray(
                scanline_generation_binary_pixel + 1'b1
            );
        end
    end

    always_ff @(posedge ddr_clk) begin
        if (ddr_reset) begin
            scanline_generation_gray_ddr_meta <= 16'd0;
            scanline_generation_gray_ddr_sync <= 16'd0;
        end else begin
            scanline_generation_gray_ddr_meta <=
                scanline_generation_gray_pixel;
            scanline_generation_gray_ddr_sync <=
                scanline_generation_gray_ddr_meta;
        end
    end

    wire [15:0] request_write_scanline_generation_gray = scanline_tick
        ? binary_to_gray(scanline_generation_binary_pixel + 1'b1)
        : scanline_generation_gray_pixel;
    wire [15:0] request_scanline_generation_binary =
        gray_to_binary(request_scanline_generation_gray);
    wire [15:0] scanline_generation_binary_ddr =
        gray_to_binary(scanline_generation_gray_ddr_sync);
    wire [15:0] request_scanline_age =
        scanline_generation_binary_ddr -
        request_scanline_generation_binary;
    wire request_line_is_stale = !request_is_descriptor &&
        !request_scanline_age[15] && request_scanline_age >= 16'd2;

    always_comb begin
        descriptor_request_ready = !pixel_reset && request_write_ready;
        line_request_ready = !pixel_reset && request_write_ready &&
            !descriptor_request;
        request_write = 1'b0;
        request_write_data = '0;
        if (descriptor_request && descriptor_request_ready) begin
            request_write = 1'b1;
            request_write_data = {
                1'b1, pixel_session, 32'd0, 8'd0, 16'd0
            };
        end else if (line_request && line_request_ready) begin
            request_write = 1'b1;
            request_write_data = {
                1'b0, pixel_session, line_frame, line_y,
                request_write_scanline_generation_gray
            };
        end
    end

    nds_h3d_plane_reader_request_fifo request_fifo (
        .write_clk(pixel_clk),
        .write_reset(pixel_reset),
        .write_valid(request_write),
        .write_ready(request_write_ready),
        .write_data(request_write_data),
        .read_clk(ddr_clk),
        .read_reset(ddr_reset),
        .read_valid(request_read_valid),
        .read_ready(request_read),
        .read_data(request_read_data)
    );

    // ---------------------------------------------------------------------
    // Dual-clock line memories.  Each even/odd pair is one logical 256x32
    // bank.  There is one DDR write port and one registered pixel read port
    // per physical array, with no reset on RAM contents.
    // ---------------------------------------------------------------------
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank0_even [0:127];
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank0_odd [0:127];
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank1_even [0:127];
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank1_odd [0:127];
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank2_even [0:127];
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] line_bank2_odd [0:127];

    logic [31:0] bank0_even_q;
    logic [31:0] bank0_odd_q;
    logic [31:0] bank1_even_q;
    logic [31:0] bank1_odd_q;
    logic [31:0] bank2_even_q;
    logic [31:0] bank2_odd_q;
    logic read_lane_q;
    logic [1:0] read_bank_q;
    logic read_valid_q;

    // ---------------------------------------------------------------------
    // DDR-owned bank tags and ready toggles.  A tag changes only while its
    // bank is free, and remains stable from ready publication through ack.
    // ---------------------------------------------------------------------
    logic [31:0] bank_tag_sequence_ddr [0:2];
    logic [31:0] bank_tag_session_ddr [0:2];
    logic [31:0] bank_tag_frame_ddr [0:2];
    logic        bank_tag_source_ddr [0:2];
    logic [7:0]  bank_tag_y_ddr [0:2];
    logic [2:0] bank_ready_toggle_ddr;
    logic [2:0] bank_ack_toggle_pixel;
    (* async_reg = "true" *) logic [2:0] bank_ack_meta_ddr;
    (* async_reg = "true" *) logic [2:0] bank_ack_sync_ddr;

    logic descriptor_meta_valid_ddr;
    logic [31:0] descriptor_meta_sequence_ddr;
    logic [31:0] descriptor_meta_session_ddr;
    logic [31:0] descriptor_meta_frame_ddr;
    logic descriptor_meta_bank_ddr;
    logic descriptor_meta_full_frame_ddr;
    logic [1:0] descriptor_meta_full_bank_ddr;
    logic descriptor_activation_pending_ddr;
    logic descriptor_ready_toggle_ddr;
    logic descriptor_active_toggle_ddr;
    logic descriptor_ack_toggle_pixel;
    (* async_reg = "true" *) logic descriptor_ack_meta_ddr;
    (* async_reg = "true" *) logic descriptor_ack_sync_ddr;

    always_ff @(posedge ddr_clk) begin
        if (ddr_reset) begin
            bank_ack_meta_ddr <= 3'b000;
            bank_ack_sync_ddr <= 3'b000;
            descriptor_ack_meta_ddr <= 1'b0;
            descriptor_ack_sync_ddr <= 1'b0;
        end else begin
            bank_ack_meta_ddr <= bank_ack_toggle_pixel;
            bank_ack_sync_ddr <= bank_ack_meta_ddr;
            descriptor_ack_meta_ddr <= descriptor_ack_toggle_pixel;
            descriptor_ack_sync_ddr <= descriptor_ack_meta_ddr;
        end
    end

    wire bank0_free =
        bank_ack_sync_ddr[0] == bank_ready_toggle_ddr[0];
    wire bank1_free =
        bank_ack_sync_ddr[1] == bank_ready_toggle_ddr[1];
    wire bank2_free =
        bank_ack_sync_ddr[2] == bank_ready_toggle_ddr[2];
    wire descriptor_link_free =
        descriptor_ack_sync_ddr == descriptor_ready_toggle_ddr;

    // ---------------------------------------------------------------------
    // Descriptor reader and DDR line fetcher.
    // ---------------------------------------------------------------------
    logic [31:0] candidate_sequence;
    logic [63:0] descriptor_word0;
    logic [63:0] descriptor_word1;
    logic [63:0] descriptor_word2;
    logic [63:0] descriptor_word3;
    logic [2:0] descriptor_beat_index;
    logic [31:0] ack_sequence;
    logic [31:0] ack_session;
    logic full_ack_pending;
    logic [31:0] active_session;
    logic active_descriptor_full_frame;
    logic session_invalidate_pending;

    logic [1:0] next_fill_bank;
    logic [1:0] fill_bank;
    logic [31:0] fetch_sequence;
    logic [31:0] fetch_session;
    logic [31:0] fetch_frame;
    logic fetch_source_bank;
    logic [7:0] fetch_y;
    // Number of response beats already accepted, 0 through 128.
    logic [7:0] fetch_beat_count;

    wire candidate_is_plane =
        descriptor_word2[31:0] <= 32'd1 &&
        descriptor_word2[63:32] == PIXEL_FORMAT;
    wire candidate_is_full_frame =
        descriptor_word2[31:0] <= 32'd3 &&
        descriptor_word2[63:32] == FULL_FRAME_PIXEL_FORMAT;
    wire candidate_fields_valid =
        descriptor_word0[31:0] == candidate_sequence &&
        descriptor_word0[63:32] == 32'd0 &&
        descriptor_word1[31:0] == ddr_session &&
        (candidate_is_plane || candidate_is_full_frame) &&
        descriptor_word3[31:0] == EXPECTED_WIDTH_HEIGHT &&
        descriptor_word3[63:32] == EXPECTED_STRIDE;

    wire fetch_still_current =
        active_descriptor_valid &&
        active_session == ddr_session &&
        fetch_session == ddr_session &&
        active_descriptor_sequence == fetch_sequence &&
        active_descriptor_frame == fetch_frame &&
        active_descriptor_bank == fetch_source_bank;

    wire [28:0] fetch_bank_base = fetch_source_bank
        ? BANK1_BASE_WORD : BANK0_BASE_WORD;
    wire [28:0] fetch_line_address =
        fetch_bank_base + ({21'd0, fetch_y} << 7);

    initial begin
        if (PIXEL_FORMAT == 0)
            $fatal(1, "H3D plane reader requires a nonzero pixel format");
        if (BANK0_BASE_WORD == BANK1_BASE_WORD)
            $fatal(1, "H3D frame banks must use different DDR ranges");
    end

    always_comb begin
        busy = state != IDLE;
        descriptor_busy =
            state == DESC_SEQUENCE0_ISSUE ||
            state == DESC_SEQUENCE0_WAIT ||
            state == DESC_BODY_ISSUE ||
            state == DESC_BODY_WAIT ||
            state == DESC_SEQUENCE1_ISSUE ||
            state == DESC_SEQUENCE1_WAIT ||
            state == DESC_ACK_ISSUE;
        line_fetch_busy = state == LINE_ISSUE || state == LINE_WAIT;

        ddram_active = descriptor_busy || line_fetch_busy;
        ddram_read = 1'b0;
        ddram_write = 1'b0;
        ddram_burst_count = 8'd1;
        ddram_address = CONTROL_BASE_WORD + PUBLISH_SEQUENCE_WORD;
        ddram_write_data = 64'd0;
        ddram_byte_enable = 8'hff;

        case (state)
            DESC_SEQUENCE0_ISSUE,
            DESC_SEQUENCE1_ISSUE: begin
                ddram_read = !ddram_busy;
                ddram_address =
                    CONTROL_BASE_WORD + PUBLISH_SEQUENCE_WORD;
            end

            DESC_BODY_ISSUE: begin
                ddram_read = !ddram_busy;
                ddram_burst_count = 8'd4;
                ddram_address = CONTROL_BASE_WORD + DESCRIPTOR_WORD;
            end

            DESC_ACK_ISSUE: begin
                ddram_write = !ddram_busy && ack_session == ddr_session;
                ddram_address = CONTROL_BASE_WORD + ACK_SEQUENCE_WORD;
                ddram_write_data = {32'd0, ack_sequence};
                ddram_byte_enable = 8'h0f;
            end

            LINE_ISSUE: begin
                ddram_read = !ddram_busy;
                ddram_burst_count = LINE_BURST_WORDS;
                ddram_address = fetch_line_address;
            end

            default: begin end
        endcase
    end

    // Pop a descriptor only when the previous descriptor bundle was acked.
    // Invalid line requests are consumed as explicit misses.  A valid line
    // request, however, remains at the FIFO head while all line banks are
    // owned by the pixel side.  That ownership normally clears at line_end;
    // dropping the request during this short interval creates a guaranteed
    // transparent stripe even though the DDR fetch still has time to finish.
    always_comb begin
        request_read = 1'b0;
        if (state == IDLE && !session_invalidate_pending &&
            request_read_valid) begin
            if (request_is_descriptor) begin
                request_read = descriptor_link_free && !full_ack_pending;
            end else if (
                request_session != ddr_session ||
                request_line_is_stale ||
                !active_descriptor_valid ||
                active_descriptor_full_frame ||
                active_session != ddr_session ||
                request_frame != active_descriptor_frame ||
                request_y >= 8'd192
            ) begin
                request_read = 1'b1;
            end else begin
                // A verified replacement may wait here until the next pixel
                // VBlank.  Continue serving the still-active descriptor in
                // that interval; stopping line fetches at verification time
                // blanks the remainder of the current scanout frame.
                request_read = bank0_free || bank1_free || bank2_free;
            end
        end
    end

    // Three banks make the product's y+2 request genuinely two lines early:
    // the current and next lines may remain owned while DDR starts the third.
    // Rotate the first-free choice so no physical RAM is needlessly favored.
    logic [1:0] free_bank_choice;
    always_comb begin
        free_bank_choice = 2'd0;
        case (next_fill_bank)
            2'd0: begin
                if (bank0_free) free_bank_choice = 2'd0;
                else if (bank1_free) free_bank_choice = 2'd1;
                else free_bank_choice = 2'd2;
            end
            2'd1: begin
                if (bank1_free) free_bank_choice = 2'd1;
                else if (bank2_free) free_bank_choice = 2'd2;
                else free_bank_choice = 2'd0;
            end
            default: begin
                if (bank2_free) free_bank_choice = 2'd2;
                else if (bank0_free) free_bank_choice = 2'd0;
                else free_bank_choice = 2'd1;
            end
        endcase
    end

    always_ff @(posedge ddr_clk) begin
        if (ddr_reset) begin
            state <= IDLE;
            candidate_sequence <= 32'd0;
            descriptor_word0 <= 64'd0;
            descriptor_word1 <= 64'd0;
            descriptor_word2 <= 64'd0;
            descriptor_word3 <= 64'd0;
            descriptor_beat_index <= 3'd0;
            ack_sequence <= 32'd0;
            ack_session <= 32'd0;
            full_ack_pending <= 1'b0;
            full_frame_publish <= 1'b0;
            full_frame_bank <= 2'd0;
            active_descriptor_valid <= 1'b0;
            active_descriptor_sequence <= 32'd0;
            active_descriptor_frame <= 32'd0;
            active_descriptor_bank <= 1'b0;
            active_descriptor_full_frame <= 1'b0;
            active_session <= 32'd0;
            session_invalidate_pending <= 1'b0;
            descriptor_meta_valid_ddr <= 1'b0;
            descriptor_meta_sequence_ddr <= 32'd0;
            descriptor_meta_session_ddr <= 32'd0;
            descriptor_meta_frame_ddr <= 32'd0;
            descriptor_meta_bank_ddr <= 1'b0;
            descriptor_meta_full_frame_ddr <= 1'b0;
            descriptor_meta_full_bank_ddr <= 2'd0;
            descriptor_activation_pending_ddr <= 1'b0;
            descriptor_ready_toggle_ddr <= 1'b0;
            descriptor_active_toggle_ddr <= 1'b0;
            next_fill_bank <= 2'd0;
            fill_bank <= 2'd0;
            fetch_sequence <= 32'd0;
            fetch_session <= 32'd0;
            fetch_frame <= 32'd0;
            fetch_source_bank <= 1'b0;
            fetch_y <= 8'd0;
            fetch_beat_count <= 8'd0;
            bank_ready_toggle_ddr <= 3'b000;
            bank_tag_sequence_ddr[0] <= 32'd0;
            bank_tag_sequence_ddr[1] <= 32'd0;
            bank_tag_sequence_ddr[2] <= 32'd0;
            bank_tag_session_ddr[0] <= 32'd0;
            bank_tag_session_ddr[1] <= 32'd0;
            bank_tag_session_ddr[2] <= 32'd0;
            bank_tag_frame_ddr[0] <= 32'd0;
            bank_tag_frame_ddr[1] <= 32'd0;
            bank_tag_frame_ddr[2] <= 32'd0;
            bank_tag_source_ddr[0] <= 1'b0;
            bank_tag_source_ddr[1] <= 1'b0;
            bank_tag_source_ddr[2] <= 1'b0;
            bank_tag_y_ddr[0] <= 8'd0;
            bank_tag_y_ddr[1] <= 8'd0;
            bank_tag_y_ddr[2] <= 8'd0;
            descriptor_accepted <= 1'b0;
            descriptor_rejected <= 1'b0;
            line_loaded <= 1'b0;
            line_missed <= 1'b0;
            full_frame_publish <= 1'b0;
        end else begin
            descriptor_accepted <= 1'b0;
            descriptor_rejected <= 1'b0;
            line_loaded <= 1'b0;
            line_missed <= 1'b0;

            // Session is an epoch, not telemetry.  It invalidates the active
            // descriptor immediately and prevents an in-flight fetch from
            // publishing on its final beat.
            if (active_descriptor_valid && active_session != ddr_session) begin
                active_descriptor_valid <= 1'b0;
                active_descriptor_full_frame <= 1'b0;
                descriptor_activation_pending_ddr <= 1'b0;
                session_invalidate_pending <= 1'b1;
            end
            if (full_ack_pending && ack_session != ddr_session)
                full_ack_pending <= 1'b0;

            case (state)
                IDLE: begin
                    if (full_ack_pending && full_frame_adopted) begin
                        full_ack_pending <= 1'b0;
                        state <= DESC_ACK_ISSUE;
                    end else if (session_invalidate_pending) begin
                        if (descriptor_link_free) begin
                            descriptor_meta_valid_ddr <= 1'b0;
                            descriptor_meta_sequence_ddr <= 32'd0;
                            descriptor_meta_session_ddr <= ddr_session;
                            descriptor_meta_frame_ddr <= 32'd0;
                            descriptor_meta_bank_ddr <= 1'b0;
                            descriptor_meta_full_frame_ddr <= 1'b0;
                            descriptor_meta_full_bank_ddr <= 2'd0;
                            descriptor_ready_toggle_ddr <=
                                !descriptor_ready_toggle_ddr;
                            session_invalidate_pending <= 1'b0;
                        end
                    end else if (descriptor_activation_pending_ddr &&
                            descriptor_link_free) begin
                        // The pixel side accepted the staged descriptor at an
                        // architectural frame boundary. Only now may DDR line
                        // requests switch planes and HPS reclaim the old bank.
                        active_descriptor_valid <= descriptor_meta_valid_ddr;
                        active_descriptor_sequence <=
                            descriptor_meta_sequence_ddr;
                        active_session <= descriptor_meta_session_ddr;
                        active_descriptor_frame <=
                            descriptor_meta_frame_ddr;
                        active_descriptor_bank <= descriptor_meta_bank_ddr;
                        active_descriptor_full_frame <=
                            descriptor_meta_full_frame_ddr;
                        descriptor_activation_pending_ddr <= 1'b0;
                        // Confirm the DDR-side switch before the pixel side
                        // exposes the replacement descriptor.  Until this
                        // toggle crosses, the old descriptor and its line
                        // banks remain mutually coherent in both domains.
                        descriptor_active_toggle_ddr <=
                            !descriptor_active_toggle_ddr;
                        if (descriptor_meta_full_frame_ddr) begin
                            full_frame_publish <= 1'b1;
                            full_frame_bank <= descriptor_meta_full_bank_ddr;
                            full_ack_pending <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= DESC_ACK_ISSUE;
                        end
                    end else if (request_read_valid && request_read) begin
                        if (request_is_descriptor) begin
                            // A descriptor refresh is observational. Keep the
                            // last verified plane active until a complete,
                            // tear-free replacement is accepted below.
                            session_invalidate_pending <= 1'b0;
                            if (request_session == ddr_session) begin
                                state <= DESC_SEQUENCE0_ISSUE;
                            end else begin
                                descriptor_rejected <= 1'b1;
                            end
                        end else if (request_line_is_stale) begin
                            // This request was valid when queued, but its fixed
                            // raster deadline has since passed.  Discarding it
                            // is the intended recovery path, not a current-line
                            // failure: do not feed the fatal line_missed fault.
                        end else if (
                            request_session != ddr_session ||
                            !active_descriptor_valid ||
                            active_descriptor_full_frame ||
                            active_session != ddr_session ||
                            request_frame != active_descriptor_frame ||
                            request_y >= 8'd192
                        ) begin
                            line_missed <= 1'b1;
                        end else if (
                            bank0_free || bank1_free || bank2_free
                        ) begin
                            fill_bank <= free_bank_choice;
                            next_fill_bank <= free_bank_choice == 2'd2
                                ? 2'd0 : free_bank_choice + 1'b1;
                            fetch_sequence <= active_descriptor_sequence;
                            fetch_session <= active_session;
                            fetch_frame <= request_frame;
                            fetch_source_bank <= active_descriptor_bank;
                            fetch_y <= request_y;
                            fetch_beat_count <= 8'd0;
                            state <= LINE_ISSUE;
                        end
                    end
                end

                DESC_SEQUENCE0_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[31:0] != 0 &&
                                !ddram_read_data[0] &&
                                ddram_read_data[63:32] == 0) begin
                                if (active_descriptor_valid &&
                                    active_session == ddr_session &&
                                    ddram_read_data[31:0] ==
                                        active_descriptor_sequence) begin
                                    descriptor_accepted <= 1'b1;
                                    state <= IDLE;
                                end else begin
                                    candidate_sequence <=
                                        ddram_read_data[31:0];
                                    state <= DESC_BODY_ISSUE;
                                end
                            end else begin
                                descriptor_rejected <= 1'b1;
                                state <= IDLE;
                            end
                        end else begin
                            state <= DESC_SEQUENCE0_WAIT;
                        end
                    end
                end

                DESC_SEQUENCE0_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (ddram_read_data[31:0] != 0 &&
                            !ddram_read_data[0] &&
                            ddram_read_data[63:32] == 0) begin
                            if (active_descriptor_valid &&
                                active_session == ddr_session &&
                                ddram_read_data[31:0] ==
                                    active_descriptor_sequence) begin
                                // The producer has not published anything
                                // new. Avoid invalidating or republishing the
                                // stable pixel-domain descriptor.
                                descriptor_accepted <= 1'b1;
                                state <= IDLE;
                            end else begin
                                candidate_sequence <=
                                    ddram_read_data[31:0];
                                state <= DESC_BODY_ISSUE;
                            end
                        end else begin
                            descriptor_rejected <= 1'b1;
                            state <= IDLE;
                        end
                    end
                end

                DESC_BODY_ISSUE: begin
                    if (ddram_command_accepted) begin
                        descriptor_beat_index <= 3'd0;
                        if (ddram_read_data_ready) begin
                            descriptor_word0 <= ddram_read_data;
                            descriptor_beat_index <= 3'd1;
                        end
                        state <= DESC_BODY_WAIT;
                    end
                end

                DESC_BODY_WAIT: begin
                    if (ddram_read_data_ready) begin
                        case (descriptor_beat_index)
                            3'd0: descriptor_word0 <= ddram_read_data;
                            3'd1: descriptor_word1 <= ddram_read_data;
                            3'd2: descriptor_word2 <= ddram_read_data;
                            default: descriptor_word3 <= ddram_read_data;
                        endcase
                        if (descriptor_beat_index == 3'd3)
                            state <= DESC_SEQUENCE1_ISSUE;
                        else
                            descriptor_beat_index <=
                                descriptor_beat_index + 1'b1;
                    end
                end

                DESC_SEQUENCE1_ISSUE: begin
                    if (ddram_command_accepted) begin
                        if (ddram_read_data_ready) begin
                            if (ddram_read_data[31:0] ==
                                    candidate_sequence &&
                                ddram_read_data[63:32] == 0 &&
                                candidate_fields_valid) begin
                                descriptor_meta_valid_ddr <= 1'b1;
                                descriptor_meta_sequence_ddr <=
                                    candidate_sequence;
                                descriptor_meta_session_ddr <=
                                    descriptor_word1[31:0];
                                descriptor_meta_frame_ddr <=
                                    descriptor_word1[63:32];
                                descriptor_meta_bank_ddr <=
                                    descriptor_word2[0];
                                descriptor_meta_full_frame_ddr <=
                                    candidate_is_full_frame;
                                descriptor_meta_full_bank_ddr <=
                                    descriptor_word2[1:0];
                                descriptor_ready_toggle_ddr <=
                                    !descriptor_ready_toggle_ddr;
                                descriptor_activation_pending_ddr <= 1'b1;
                                session_invalidate_pending <= 1'b0;
                                ack_sequence <= candidate_sequence;
                                ack_session <= ddr_session;
                                descriptor_accepted <= 1'b1;
                                state <= IDLE;
                            end else begin
                                descriptor_rejected <= 1'b1;
                                state <= IDLE;
                            end
                        end else begin
                            state <= DESC_SEQUENCE1_WAIT;
                        end
                    end
                end

                DESC_SEQUENCE1_WAIT: begin
                    if (ddram_read_data_ready) begin
                        if (ddram_read_data[31:0] ==
                                candidate_sequence &&
                            ddram_read_data[63:32] == 0 &&
                            candidate_fields_valid) begin
                            descriptor_meta_valid_ddr <= 1'b1;
                            descriptor_meta_sequence_ddr <=
                                candidate_sequence;
                            descriptor_meta_session_ddr <=
                                descriptor_word1[31:0];
                            descriptor_meta_frame_ddr <=
                                descriptor_word1[63:32];
                            descriptor_meta_bank_ddr <=
                                descriptor_word2[0];
                            descriptor_meta_full_frame_ddr <=
                                candidate_is_full_frame;
                            descriptor_meta_full_bank_ddr <=
                                descriptor_word2[1:0];
                            descriptor_ready_toggle_ddr <=
                                !descriptor_ready_toggle_ddr;
                            descriptor_activation_pending_ddr <= 1'b1;
                            session_invalidate_pending <= 1'b0;
                            ack_sequence <= candidate_sequence;
                            ack_session <= ddr_session;
                            descriptor_accepted <= 1'b1;
                            state <= IDLE;
                        end else begin
                            descriptor_rejected <= 1'b1;
                            state <= IDLE;
                        end
                    end
                end

                DESC_ACK_ISSUE: begin
                    if (ack_session != ddr_session)
                        state <= IDLE;
                    else if (ddram_command_accepted)
                        state <= IDLE;
                end

                LINE_ISSUE: begin
                    if (ddram_command_accepted) begin
                        fetch_beat_count <= 8'd0;
                        if (ddram_read_data_ready) begin
                            case (fill_bank)
                                2'd0: begin
                                    line_bank0_even[0] <=
                                        ddram_read_data[31:0];
                                    line_bank0_odd[0] <=
                                        ddram_read_data[63:32];
                                end
                                2'd1: begin
                                    line_bank1_even[0] <=
                                        ddram_read_data[31:0];
                                    line_bank1_odd[0] <=
                                        ddram_read_data[63:32];
                                end
                                default: begin
                                    line_bank2_even[0] <=
                                        ddram_read_data[31:0];
                                    line_bank2_odd[0] <=
                                        ddram_read_data[63:32];
                                end
                            endcase
                            fetch_beat_count <= 8'd1;
                        end
                        state <= LINE_WAIT;
                    end
                end

                LINE_WAIT: begin
                    if (ddram_read_data_ready) begin
                        case (fill_bank)
                            2'd0: begin
                                line_bank0_even[fetch_beat_count[6:0]] <=
                                    ddram_read_data[31:0];
                                line_bank0_odd[fetch_beat_count[6:0]] <=
                                    ddram_read_data[63:32];
                            end
                            2'd1: begin
                                line_bank1_even[fetch_beat_count[6:0]] <=
                                    ddram_read_data[31:0];
                                line_bank1_odd[fetch_beat_count[6:0]] <=
                                    ddram_read_data[63:32];
                            end
                            default: begin
                                line_bank2_even[fetch_beat_count[6:0]] <=
                                    ddram_read_data[31:0];
                                line_bank2_odd[fetch_beat_count[6:0]] <=
                                    ddram_read_data[63:32];
                            end
                        endcase

                        if (fetch_beat_count == 8'd127) begin
                            fetch_beat_count <= 8'd128;
                            if (fetch_still_current) begin
                                bank_tag_sequence_ddr[fill_bank] <=
                                    fetch_sequence;
                                bank_tag_session_ddr[fill_bank] <=
                                    fetch_session;
                                bank_tag_frame_ddr[fill_bank] <=
                                    fetch_frame;
                                bank_tag_source_ddr[fill_bank] <=
                                    fetch_source_bank;
                                bank_tag_y_ddr[fill_bank] <= fetch_y;
                                bank_ready_toggle_ddr[fill_bank] <=
                                    !bank_ready_toggle_ddr[fill_bank];
                                line_loaded <= 1'b1;
                            end else begin
                                line_missed <= 1'b1;
                            end
                            state <= IDLE;
                        end else begin
                            fetch_beat_count <= fetch_beat_count + 1'b1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Pixel-side ready/tag capture, descriptor copy, bank selection and ack.
    // Tags are bundled data: DDR writes them before toggling ready and keeps
    // them unchanged until ack.  Two synchronizer clocks plus this explicit
    // one-clock capture delay give the bundle time to settle.
    // ---------------------------------------------------------------------
    (* async_reg = "true" *) logic [2:0] bank_ready_meta_pixel;
    (* async_reg = "true" *) logic [2:0] bank_ready_sync_pixel;
    logic [2:0] bank_ready_seen_pixel;
    logic [2:0] bank_capture_pending_pixel;
    logic [2:0] bank_available_pixel;

    logic [31:0] bank_tag_sequence_pixel [0:2];
    logic [31:0] bank_tag_session_pixel [0:2];
    logic [31:0] bank_tag_frame_pixel [0:2];
    logic        bank_tag_source_pixel [0:2];
    logic [7:0]  bank_tag_y_pixel [0:2];

    (* async_reg = "true" *) logic descriptor_ready_meta_pixel;
    (* async_reg = "true" *) logic descriptor_ready_sync_pixel;
    (* async_reg = "true" *) logic descriptor_active_meta_pixel;
    (* async_reg = "true" *) logic descriptor_active_sync_pixel;
    logic descriptor_ready_seen_pixel;
    logic descriptor_capture_pending_pixel;
    logic descriptor_active_seen_pixel;
    logic descriptor_activation_requested_pixel;
    logic pending_descriptor_valid_pixel;
    logic [31:0] pending_descriptor_sequence_pixel;
    logic [31:0] pending_descriptor_session_pixel;
    logic [31:0] pending_descriptor_frame_pixel;
    logic pending_descriptor_bank_pixel;
    logic pending_descriptor_full_frame_pixel;
    logic [31:0] pixel_descriptor_session;
    logic [31:0] pixel_session_q;

    // Same-domain scheduler feedback. Once a replacement descriptor has
    // crossed into the pixel domain, stop issuing observational refreshes
    // until the existing VBlank-only activation handshake consumes it.
    always_comb begin
        pixel_descriptor_pending = pending_descriptor_valid_pixel ||
            descriptor_activation_requested_pixel;
    end

    logic selected_line_valid;
    logic [1:0] selected_line_bank;
    logic [31:0] selected_line_session;
    logic selected_line_ready_token;

    always_ff @(posedge pixel_clk) begin
        if (pixel_reset) begin
            bank_ready_meta_pixel <= 3'b000;
            bank_ready_sync_pixel <= 3'b000;
            descriptor_ready_meta_pixel <= 1'b0;
            descriptor_ready_sync_pixel <= 1'b0;
            descriptor_active_meta_pixel <= 1'b0;
            descriptor_active_sync_pixel <= 1'b0;
        end else begin
            bank_ready_meta_pixel <= bank_ready_toggle_ddr;
            bank_ready_sync_pixel <= bank_ready_meta_pixel;
            descriptor_ready_meta_pixel <= descriptor_ready_toggle_ddr;
            descriptor_ready_sync_pixel <= descriptor_ready_meta_pixel;
            descriptor_active_meta_pixel <= descriptor_active_toggle_ddr;
            descriptor_active_sync_pixel <= descriptor_active_meta_pixel;
        end
    end

    wire bank0_tag_current =
        bank_available_pixel[0] && pixel_descriptor_valid &&
        bank_tag_sequence_pixel[0] == pixel_descriptor_sequence &&
        bank_tag_session_pixel[0] == pixel_session &&
        bank_tag_session_pixel[0] == pixel_descriptor_session &&
        bank_tag_frame_pixel[0] == pixel_descriptor_frame &&
        bank_tag_source_pixel[0] == pixel_descriptor_bank;
    wire bank1_tag_current =
        bank_available_pixel[1] && pixel_descriptor_valid &&
        bank_tag_sequence_pixel[1] == pixel_descriptor_sequence &&
        bank_tag_session_pixel[1] == pixel_session &&
        bank_tag_session_pixel[1] == pixel_descriptor_session &&
        bank_tag_frame_pixel[1] == pixel_descriptor_frame &&
        bank_tag_source_pixel[1] == pixel_descriptor_bank;
    wire bank2_tag_current =
        bank_available_pixel[2] && pixel_descriptor_valid &&
        bank_tag_sequence_pixel[2] == pixel_descriptor_sequence &&
        bank_tag_session_pixel[2] == pixel_session &&
        bank_tag_session_pixel[2] == pixel_descriptor_session &&
        bank_tag_frame_pixel[2] == pixel_descriptor_frame &&
        bank_tag_source_pixel[2] == pixel_descriptor_bank;

    wire line_start_hit0 = bank0_tag_current &&
        bank_tag_frame_pixel[0] == merge_frame &&
        bank_tag_y_pixel[0] == merge_y;
    wire line_start_hit1 = bank1_tag_current &&
        bank_tag_frame_pixel[1] == merge_frame &&
        bank_tag_y_pixel[1] == merge_y;
    wire line_start_hit2 = bank2_tag_current &&
        bank_tag_frame_pixel[2] == merge_frame &&
        bank_tag_y_pixel[2] == merge_y;
    wire line_start_hit = line_start_hit0 || line_start_hit1 ||
        line_start_hit2;
    assign pixel_line_missed = line_start && pixel_descriptor_valid &&
        !line_start_hit;
    wire [1:0] line_start_bank = line_start_hit0 ? 2'd0 :
        line_start_hit1 ? 2'd1 : 2'd2;

    logic [7:0] frame_line_hit_count_pixel;
    logic [7:0] frame_line_empty_count_pixel;
    logic [7:0] frame_line_wrong_y_count_pixel;
    logic [3:0] frame_line_stale_count_pixel;

    function automatic logic scanline_tag_is_past(
        input logic [7:0] current_y,
        input logic [7:0] tag_y
    );
        logic [8:0] distance;
        begin
            if (current_y >= tag_y)
                distance = {1'b0, current_y} - {1'b0, tag_y};
            else
                distance = {1'b0, current_y} + 9'd192 -
                    {1'b0, tag_y};
            scanline_tag_is_past = distance != 0 && distance < 9'd96;
        end
    endfunction

    // A completed prefetch normally leaves the available set at line_start.
    // If 2D drops that drawline, no line_start arrives. Retire such a line
    // once its architectural deadline is behind us; future y+1/y+2 tags have
    // modular distances 191/190 and survive frame wrap.
    wire bank0_deadline_passed = scanline_tick &&
        bank_available_pixel[0] && bank0_tag_current &&
        scanline_tag_is_past(scanline_y, bank_tag_y_pixel[0]);
    wire bank1_deadline_passed = scanline_tick &&
        bank_available_pixel[1] && bank1_tag_current &&
        scanline_tag_is_past(scanline_y, bank_tag_y_pixel[1]);
    wire bank2_deadline_passed = scanline_tick &&
        bank_available_pixel[2] && bank2_tag_current &&
        scanline_tag_is_past(scanline_y, bank_tag_y_pixel[2]);

    always_ff @(posedge pixel_clk) begin
        if (pixel_reset) begin
            bank_ready_seen_pixel <= 3'b000;
            bank_capture_pending_pixel <= 3'b000;
            bank_available_pixel <= 3'b000;
            bank_ack_toggle_pixel <= 3'b000;
            bank_tag_sequence_pixel[0] <= 32'd0;
            bank_tag_sequence_pixel[1] <= 32'd0;
            bank_tag_sequence_pixel[2] <= 32'd0;
            bank_tag_session_pixel[0] <= 32'd0;
            bank_tag_session_pixel[1] <= 32'd0;
            bank_tag_session_pixel[2] <= 32'd0;
            bank_tag_frame_pixel[0] <= 32'd0;
            bank_tag_frame_pixel[1] <= 32'd0;
            bank_tag_frame_pixel[2] <= 32'd0;
            bank_tag_source_pixel[0] <= 1'b0;
            bank_tag_source_pixel[1] <= 1'b0;
            bank_tag_source_pixel[2] <= 1'b0;
            bank_tag_y_pixel[0] <= 8'd0;
            bank_tag_y_pixel[1] <= 8'd0;
            bank_tag_y_pixel[2] <= 8'd0;
            descriptor_ready_seen_pixel <= 1'b0;
            descriptor_capture_pending_pixel <= 1'b0;
            descriptor_active_seen_pixel <= 1'b0;
            descriptor_activation_requested_pixel <= 1'b0;
            pending_descriptor_valid_pixel <= 1'b0;
            pending_descriptor_sequence_pixel <= 32'd0;
            pending_descriptor_session_pixel <= 32'd0;
            pending_descriptor_frame_pixel <= 32'd0;
            pending_descriptor_bank_pixel <= 1'b0;
            pending_descriptor_full_frame_pixel <= 1'b0;
            descriptor_ack_toggle_pixel <= 1'b0;
            pixel_descriptor_valid <= 1'b0;
            pixel_descriptor_sequence <= 32'd0;
            pixel_descriptor_session <= 32'd0;
            pixel_descriptor_frame <= 32'd0;
            pixel_descriptor_bank <= 1'b0;
            pixel_session_q <= 32'd0;
            selected_line_valid <= 1'b0;
            selected_line_bank <= 2'd0;
            selected_line_session <= 32'd0;
            selected_line_ready_token <= 1'b0;
            frame_line_hit_count_pixel <= 8'd0;
            frame_line_empty_count_pixel <= 8'd0;
            frame_line_wrong_y_count_pixel <= 8'd0;
            frame_line_stale_count_pixel <= 4'd0;
            pixel_frame_diagnostic <= 28'd0;
        end else begin
            // Detect a synchronized publication, then wait one more pixel
            // clock before sampling its stable bundled fields.
            if (bank_ready_sync_pixel[0] != bank_ready_seen_pixel[0] &&
                !bank_capture_pending_pixel[0]) begin
                bank_capture_pending_pixel[0] <= 1'b1;
            end else if (bank_capture_pending_pixel[0]) begin
                bank_tag_sequence_pixel[0] <= bank_tag_sequence_ddr[0];
                bank_tag_session_pixel[0] <= bank_tag_session_ddr[0];
                bank_tag_frame_pixel[0] <= bank_tag_frame_ddr[0];
                bank_tag_source_pixel[0] <= bank_tag_source_ddr[0];
                bank_tag_y_pixel[0] <= bank_tag_y_ddr[0];
                bank_ready_seen_pixel[0] <= bank_ready_sync_pixel[0];
                bank_available_pixel[0] <= 1'b1;
                bank_capture_pending_pixel[0] <= 1'b0;
            end
            if (bank_ready_sync_pixel[1] != bank_ready_seen_pixel[1] &&
                !bank_capture_pending_pixel[1]) begin
                bank_capture_pending_pixel[1] <= 1'b1;
            end else if (bank_capture_pending_pixel[1]) begin
                bank_tag_sequence_pixel[1] <= bank_tag_sequence_ddr[1];
                bank_tag_session_pixel[1] <= bank_tag_session_ddr[1];
                bank_tag_frame_pixel[1] <= bank_tag_frame_ddr[1];
                bank_tag_source_pixel[1] <= bank_tag_source_ddr[1];
                bank_tag_y_pixel[1] <= bank_tag_y_ddr[1];
                bank_ready_seen_pixel[1] <= bank_ready_sync_pixel[1];
                bank_available_pixel[1] <= 1'b1;
                bank_capture_pending_pixel[1] <= 1'b0;
            end
            if (bank_ready_sync_pixel[2] != bank_ready_seen_pixel[2] &&
                !bank_capture_pending_pixel[2]) begin
                bank_capture_pending_pixel[2] <= 1'b1;
            end else if (bank_capture_pending_pixel[2]) begin
                bank_tag_sequence_pixel[2] <= bank_tag_sequence_ddr[2];
                bank_tag_session_pixel[2] <= bank_tag_session_ddr[2];
                bank_tag_frame_pixel[2] <= bank_tag_frame_ddr[2];
                bank_tag_source_pixel[2] <= bank_tag_source_ddr[2];
                bank_tag_y_pixel[2] <= bank_tag_y_ddr[2];
                bank_ready_seen_pixel[2] <= bank_ready_sync_pixel[2];
                bank_available_pixel[2] <= 1'b1;
                bank_capture_pending_pixel[2] <= 1'b0;
            end

            if (descriptor_ready_sync_pixel !=
                    descriptor_ready_seen_pixel &&
                !descriptor_capture_pending_pixel) begin
                descriptor_capture_pending_pixel <= 1'b1;
            end else if (descriptor_capture_pending_pixel) begin
                descriptor_ready_seen_pixel <=
                    descriptor_ready_sync_pixel;
                if (descriptor_meta_valid_ddr &&
                        descriptor_meta_session_ddr == pixel_session) begin
                    pending_descriptor_valid_pixel <= 1'b1;
                    pending_descriptor_sequence_pixel <=
                        descriptor_meta_sequence_ddr;
                    pending_descriptor_session_pixel <=
                        descriptor_meta_session_ddr;
                    pending_descriptor_frame_pixel <=
                        descriptor_meta_frame_ddr;
                    pending_descriptor_bank_pixel <=
                        descriptor_meta_bank_ddr;
                    pending_descriptor_full_frame_pixel <=
                        descriptor_meta_full_frame_ddr;
                end else begin
                    pixel_descriptor_valid <= 1'b0;
                    pending_descriptor_valid_pixel <= 1'b0;
                    descriptor_activation_requested_pixel <= 1'b0;
                    descriptor_ack_toggle_pixel <=
                        descriptor_ready_sync_pixel;
                end
                descriptor_capture_pending_pixel <= 1'b0;
            end

            // At VBlank request the DDR-side switch, but continue displaying
            // the old plane until that switch is confirmed. Committing here
            // would create a deterministic transparent interval: pixels
            // would reject old banks while DDR still rejected new requests.
            if (frame_boundary && pending_descriptor_valid_pixel &&
                    !descriptor_activation_requested_pixel) begin
                descriptor_activation_requested_pixel <= 1'b1;
                descriptor_ack_toggle_pixel <= descriptor_ready_seen_pixel;
            end

            // The active toggle is the descriptor commit point.  It crosses
            // only after DDR has changed the line-fetch descriptor, so there
            // is never a split-brain old/new tag interval between domains.
            if (descriptor_active_sync_pixel !=
                    descriptor_active_seen_pixel) begin
                descriptor_active_seen_pixel <=
                    descriptor_active_sync_pixel;
                if (descriptor_activation_requested_pixel &&
                        pending_descriptor_valid_pixel &&
                        pending_descriptor_session_pixel == pixel_session) begin
                    pixel_descriptor_valid <=
                        !pending_descriptor_full_frame_pixel;
                    pixel_descriptor_sequence <=
                        pending_descriptor_sequence_pixel;
                    pixel_descriptor_session <=
                        pending_descriptor_session_pixel;
                    pixel_descriptor_frame <=
                        pending_descriptor_frame_pixel;
                    pixel_descriptor_bank <=
                        pending_descriptor_bank_pixel;
                end else begin
                    pixel_descriptor_valid <= 1'b0;
                end
                descriptor_activation_requested_pixel <= 1'b0;
                pending_descriptor_valid_pixel <= 1'b0;
            end

            // An epoch change makes existing local metadata stale.  A line
            // already being clocked is held until line_end, but pixel_valid
            // is live-qualified by selected_line_session below.
            pixel_session_q <= pixel_session;
            if (pixel_session_q != pixel_session) begin
                pixel_descriptor_valid <= 1'b0;
                pending_descriptor_valid_pixel <= 1'b0;
                descriptor_activation_requested_pixel <= 1'b0;
                descriptor_active_seen_pixel <= descriptor_active_sync_pixel;
                descriptor_ack_toggle_pixel <= descriptor_ready_seen_pixel;
            end

            // Return complete but stale, unused banks without exposing them.
            if (bank_available_pixel[0] && !bank0_tag_current) begin
                bank_available_pixel[0] <= 1'b0;
                bank_ack_toggle_pixel[0] <= bank_ready_seen_pixel[0];
            end
            if (bank_available_pixel[1] && !bank1_tag_current) begin
                bank_available_pixel[1] <= 1'b0;
                bank_ack_toggle_pixel[1] <= bank_ready_seen_pixel[1];
            end
            if (bank_available_pixel[2] && !bank2_tag_current) begin
                bank_available_pixel[2] <= 1'b0;
                bank_ack_toggle_pixel[2] <= bank_ready_seen_pixel[2];
            end

            if (bank0_deadline_passed) begin
                bank_available_pixel[0] <= 1'b0;
                bank_ack_toggle_pixel[0] <= bank_ready_seen_pixel[0];
            end
            if (bank1_deadline_passed) begin
                bank_available_pixel[1] <= 1'b0;
                bank_ack_toggle_pixel[1] <= bank_ready_seen_pixel[1];
            end
            if (bank2_deadline_passed) begin
                bank_available_pixel[2] <= 1'b0;
                bank_ack_toggle_pixel[2] <= bank_ready_seen_pixel[2];
            end

            if (line_start) begin
                // A malformed caller that starts a new line without ending
                // the old one still releases the old ownership token.
                if (selected_line_valid)
                    bank_ack_toggle_pixel[selected_line_bank] <=
                        selected_line_ready_token;

                selected_line_valid <= line_start_hit;
                selected_line_bank <= line_start_bank;
                if (line_start_hit0) begin
                    selected_line_session <= bank_tag_session_pixel[0];
                    selected_line_ready_token <=
                        bank_ready_seen_pixel[0];
                    bank_available_pixel[0] <= 1'b0;
                end else if (line_start_hit1) begin
                    selected_line_session <= bank_tag_session_pixel[1];
                    selected_line_ready_token <=
                        bank_ready_seen_pixel[1];
                    bank_available_pixel[1] <= 1'b0;
                end else if (line_start_hit2) begin
                    selected_line_session <= bank_tag_session_pixel[2];
                    selected_line_ready_token <=
                        bank_ready_seen_pixel[2];
                    bank_available_pixel[2] <= 1'b0;
                end else begin
                    selected_line_session <= pixel_session;
                    selected_line_ready_token <= 1'b0;
                end
            end

            // Classify every active-plane merge deadline without changing
            // bank ownership or request scheduling. At the final line_end,
            // publish the whole completed frame and restart the counters.
            if (line_start && pixel_descriptor_valid) begin
                if (line_start_hit) begin
                    frame_line_hit_count_pixel <=
                        frame_line_hit_count_pixel + 1'b1;
                end else if (bank_available_pixel == 3'b000) begin
                    frame_line_empty_count_pixel <=
                        frame_line_empty_count_pixel + 1'b1;
                end else if (!(bank0_tag_current || bank1_tag_current ||
                               bank2_tag_current)) begin
                    if (frame_line_stale_count_pixel != 4'hf)
                        frame_line_stale_count_pixel <=
                            frame_line_stale_count_pixel + 1'b1;
                end else begin
                    frame_line_wrong_y_count_pixel <=
                        frame_line_wrong_y_count_pixel + 1'b1;
                end
            end

            if (frame_boundary) begin
                pixel_frame_diagnostic <= {
                    frame_line_hit_count_pixel,
                    frame_line_empty_count_pixel,
                    frame_line_wrong_y_count_pixel,
                    frame_line_stale_count_pixel
                };
                frame_line_hit_count_pixel <= 8'd0;
                frame_line_empty_count_pixel <= 8'd0;
                frame_line_wrong_y_count_pixel <= 8'd0;
                frame_line_stale_count_pixel <= 4'd0;
            end

            if (line_end && !line_start) begin
                if (selected_line_valid)
                    bank_ack_toggle_pixel[selected_line_bank] <=
                        selected_line_ready_token;
                selected_line_valid <= 1'b0;
            end
        end
    end

    // Registered dual-clock RAM read.  The selection for x=0 is computed
    // directly from the line_start hit, so line_start may accompany address
    // zero without adding another bubble.
    always_ff @(posedge pixel_clk) begin
        bank0_even_q <= line_bank0_even[pixel_x[7:1]];
        bank0_odd_q <= line_bank0_odd[pixel_x[7:1]];
        bank1_even_q <= line_bank1_even[pixel_x[7:1]];
        bank1_odd_q <= line_bank1_odd[pixel_x[7:1]];
        bank2_even_q <= line_bank2_even[pixel_x[7:1]];
        bank2_odd_q <= line_bank2_odd[pixel_x[7:1]];
        if (pixel_reset) begin
            read_lane_q <= 1'b0;
            read_bank_q <= 2'd0;
            read_valid_q <= 1'b0;
        end else begin
            read_lane_q <= pixel_x[0];
            if (line_start) begin
                read_bank_q <= line_start_bank;
                case (line_start_bank)
                    2'd0: read_valid_q <= line_start_hit0 &&
                        bank_tag_session_pixel[0] == pixel_session;
                    2'd1: read_valid_q <= line_start_hit1 &&
                        bank_tag_session_pixel[1] == pixel_session;
                    default: read_valid_q <= line_start_hit2 &&
                        bank_tag_session_pixel[2] == pixel_session;
                endcase
            end else begin
                read_bank_q <= selected_line_bank;
                read_valid_q <= selected_line_valid &&
                    selected_line_session == pixel_session;
            end
        end
    end

    always_comb begin
        line_valid = selected_line_valid &&
            selected_line_session == pixel_session;
        line_bank = selected_line_bank;
        pixel_valid = read_valid_q;
        pixel_packed = 32'd0;
        if (read_valid_q) begin
            case (read_bank_q)
                2'd0: pixel_packed = read_lane_q
                    ? bank0_odd_q : bank0_even_q;
                2'd1: pixel_packed = read_lane_q
                    ? bank1_odd_q : bank1_even_q;
                default: pixel_packed = read_lane_q
                    ? bank2_odd_q : bank2_even_q;
            endcase
        end
    end
endmodule

// Four-entry asynchronous FIFO used only for compact request metadata.  Its
// payload RAM is written before the Gray write pointer crosses; the read side
// samples an entry only after two read clocks of pointer synchronization.
module nds_h3d_plane_reader_request_fifo (
    input  logic        write_clk,
    input  logic        write_reset,
    input  logic        write_valid,
    output logic        write_ready,
    input  logic [88:0] write_data,
    input  logic        read_clk,
    input  logic        read_reset,
    output logic        read_valid,
    input  logic        read_ready,
    output logic [88:0] read_data
);
    logic [88:0] memory [0:3];
    logic [2:0] write_binary;
    logic [2:0] write_gray;
    logic [2:0] read_binary;
    logic [2:0] read_gray;
    (* async_reg = "true" *) logic [2:0] read_gray_write_meta;
    (* async_reg = "true" *) logic [2:0] read_gray_write_sync;
    (* async_reg = "true" *) logic [2:0] write_gray_read_meta;
    (* async_reg = "true" *) logic [2:0] write_gray_read_sync;

    wire write_fire = write_valid && write_ready;
    wire read_fire = read_valid && read_ready;
    wire [2:0] write_binary_next =
        write_binary + {2'b00, write_fire};
    wire [2:0] write_gray_next =
        (write_binary_next >> 1) ^ write_binary_next;
    wire [2:0] read_binary_next =
        read_binary + {2'b00, read_fire};
    wire [2:0] read_gray_next =
        (read_binary_next >> 1) ^ read_binary_next;
    wire fifo_full = write_gray == {
        ~read_gray_write_sync[2:1], read_gray_write_sync[0]
    };
    wire fifo_empty = read_gray == write_gray_read_sync;

    assign write_ready = !fifo_full;
    assign read_valid = !fifo_empty;
    assign read_data = memory[read_binary[1:0]];

    always_ff @(posedge write_clk) begin
        if (write_reset) begin
            write_binary <= 3'd0;
            write_gray <= 3'd0;
            read_gray_write_meta <= 3'd0;
            read_gray_write_sync <= 3'd0;
        end else begin
            read_gray_write_meta <= read_gray;
            read_gray_write_sync <= read_gray_write_meta;
            if (write_fire) begin
                memory[write_binary[1:0]] <= write_data;
                write_binary <= write_binary_next;
                write_gray <= write_gray_next;
            end
        end
    end

    always_ff @(posedge read_clk) begin
        if (read_reset) begin
            read_binary <= 3'd0;
            read_gray <= 3'd0;
            write_gray_read_meta <= 3'd0;
            write_gray_read_sync <= 3'd0;
        end else begin
            write_gray_read_meta <= write_gray;
            write_gray_read_sync <= write_gray_read_meta;
            if (read_fire) begin
                read_binary <= read_binary_next;
                read_gray <= read_gray_next;
            end
        end
    end
endmodule
