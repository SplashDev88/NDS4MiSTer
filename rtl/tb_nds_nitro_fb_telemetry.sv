`timescale 1ns/1ps

module tb_nds_nitro_fb_telemetry;
    localparam [27:1] FB_BASE = 27'h7f00000;
    localparam [27:1] TELEMETRY_ADDR = 27'h7f18000;
    localparam [31:0] MAGIC = 32'h4e445446;

    logic clk_sys = 0;
    logic clk_video = 0;
    logic reset_sys = 1;
    logic reset_video = 1;
    // Product DDR clock is 60 MHz from the generated live PLL implementation.
    always #8.333 clk_sys = ~clk_sys;
    always #7 clk_video = ~clk_video;

    logic [7:0] pix_x = 0, pix_y = 0, pixb_x = 0, pixb_y = 0;
    logic [17:0] pix_d = 0, pixb_d = 0;
    logic pix_we = 0, pixb_we = 0;
    logic source_fault = 0;
    logic [31:0] telemetry_session = 32'd1;
    logic pf_tgl = 0, pf_scr = 0, pf_bank = 0;
    logic [1:0] pf_frame_bank = 0;
    logic [7:0] pf_line = 0;
    logic [8:0] lb_raddr = 0;
    wire [35:0] lb_q;
    wire [27:1] fb5_addr, fb6_addr;
    wire [63:0] fb5_din;
    wire fb5_req;
    wire fb5_next;
    logic fb5_ready = 0;
    wire fb6_req;
    wire published_frame_toggle;
    wire [1:0] published_frame_bank;

    nds_nitro_fb_ddr3 #(
        .FB_HW_BASE(FB_BASE), .FB_BURST(8'd128),
        .RUNTIME_TELEMETRY(1'b1)
    ) dut (
        .clk_sys, .CLK_VIDEO(clk_video), .reset_sys, .reset_video,
        .pix_x, .pix_y, .pix_d, .pix_we,
        .pixb_x, .pixb_y, .pixb_d, .pixb_we, .source_fault,
        .telemetry_session,
        .external_frame_mode(1'b0), .external_frame_publish(1'b0),
        .external_frame_bank(2'd0), .external_frame_adopted(),
        .dbg0(18'd0), .dbg1(18'd0), .dbg2(18'd0), .dbg3(18'd0),
        .dbg4(18'd0), .dbg5(18'd0), .dbg6(18'd0), .dbg7(18'd0),
        .dbg8(18'd0), .dbg9(18'd0), .dbg10(18'd0), .dbg11(18'd0),
        .pf_tgl, .pf_scr, .pf_line, .pf_bank, .pf_frame_bank,
        .published_frame_toggle, .published_frame_bank, .lb_raddr, .lb_q,
        .fb5_addr, .fb5_din, .fb5_req, .fb5_next, .fb5_ready,
        .fb6_addr, .fb6_req, .fb6_dout(64'd0),
        .fb6_valid(1'b0), .fb6_ready(1'b1)
    );

    logic service_busy = 0;
    logic service_is_telemetry = 0;
    integer service_cycle = 0;
    integer service_word = 0;
    integer service_latency_cycles = 128;
    logic [63:0] service_words [0:3];
    integer normal_bursts = 0;
    integer telemetry_bursts = 0;
    integer published_updates = 0;
    logic [31:0] last_odd_seq = 0;
    logic have_odd = 0;
    logic [31:0] published_clean = 0;
    logic [31:0] published_changed = 0;
    logic [31:0] published_hash = 0;
    logic [31:0] published_faults = 0;
    logic [31:0] published_session = 0;

    assign fb5_next = (!service_busy && fb5_req) ||
                      (service_busy && (service_word < 128));

    task automatic check_visible_address(input logic [27:1] address);
        begin
            if (!(((address >= FB_BASE) &&
                   (address <= FB_BASE + 27'h17e00)) ||
                  ((address >= FB_BASE + 27'h20000) &&
                   (address <= FB_BASE + 27'h37e00)) ||
                  ((address >= FB_BASE + 27'h40000) &&
                   (address <= FB_BASE + 27'h57e00)) ||
                  ((address >= FB_BASE + 27'h60000) &&
                   (address <= FB_BASE + 27'h77e00)) ||
                  ((address >= FB_BASE + 27'h80000) &&
                   (address <= FB_BASE + 27'h97e00)) ||
                  ((address >= FB_BASE + 27'ha0000) &&
                   (address <= FB_BASE + 27'hb7e00)) ||
                  ((address >= FB_BASE + 27'hc0000) &&
                   (address <= FB_BASE + 27'hd7e00)) ||
                  ((address >= FB_BASE + 27'he0000) &&
                   (address <= FB_BASE + 27'hf7e00))))
                $fatal(1, "normal drain escaped visible buffers: %h", address);
        end
    endtask

    always @(posedge clk_sys) begin
        fb5_ready <= 0;
        if (!service_busy && fb5_req) begin
            service_busy <= 1;
            service_cycle <= 1;
            service_word <= 1;
            service_is_telemetry <= (fb5_addr == TELEMETRY_ADDR);
            service_words[0] <= fb5_din;
            if (fb5_addr != TELEMETRY_ADDR) begin
                check_visible_address(fb5_addr);
                if (((fb5_addr - FB_BASE) >> 18) !== dut.dframe_bank)
                    $fatal(1,
                           "normal write address used bank %0d, job carried bank %0d",
                           (fb5_addr - FB_BASE) >> 18, dut.dframe_bank);
            end
        end else if (service_busy) begin
            service_cycle <= service_cycle + 1;
            if (fb5_next) service_word <= service_word + 1;
            if (fb5_next && (service_word < 4))
                service_words[service_word] <= fb5_din;
            if (service_is_telemetry && fb5_next &&
                (service_word >= 4) &&
                (fb5_din !== 64'd0))
                $fatal(1, "runtime telemetry padding beat %0d is not zero: %h",
                       service_word, fb5_din);
            if (service_cycle == service_latency_cycles - 1) begin
                service_busy <= 0;
                fb5_ready <= 1;
                if (service_is_telemetry) begin
                    telemetry_bursts <= telemetry_bursts + 1;
                    if (service_words[0][63:32] !== MAGIC)
                        $fatal(1, "bad runtime magic: %h", service_words[0]);
                    if (service_words[1][31:0] !== 32'd2)
                        $fatal(1, "bad runtime version: %h", service_words[1]);
                    if (service_words[0][0]) begin
                        last_odd_seq <= service_words[0][31:0];
                        have_odd <= 1;
                    end else begin
                        if (!have_odd ||
                            (last_odd_seq + 1'd1 != service_words[0][31:0]))
                            $fatal(1, "even record has no adjacent odd record: %h",
                                   service_words[0]);
                        have_odd <= 0;
                        published_updates <= published_updates + 1;
                        published_clean <= service_words[1][63:32];
                        published_changed <= service_words[2][31:0];
                        published_hash <= service_words[2][63:32];
                        published_faults <= service_words[3][31:0];
                        published_session <= service_words[3][63:32];
                    end
                end else begin
                    normal_bursts <= normal_bursts + 1;
                end
            end
        end
    end

    task automatic drive_frame(
        input integer content_variant,
        input integer malformed_a
    );
        integer x, y;
        integer line_target;
        logic [17:0] a_data, b_data;
        begin
            for (y = 0; y < 192; y = y + 1) begin
                line_target = normal_bursts + 2;
                for (x = 0; x < 256; x = x + 1) begin
                    @(negedge clk_sys);
                    pix_we = 1;
                    pixb_we = 1;
                    pix_x = (malformed_a && (y == 10) && (x == 128)) ?
                            8'd129 : x[7:0];
                    pix_y = y[7:0];
                    pixb_x = x[7:0];
                    pixb_y = y[7:0];
                    a_data = ((x * 13) + (y * 29)) & 18'h3ffff;
                    b_data = ((x * 7) + (y * 31) + 18'h1234) & 18'h3ffff;
                    if (content_variant && (x == 37) && (y == 80))
                        a_data = a_data ^ 18'h15555;
                    pix_d = a_data;
                    pixb_d = b_data;
                end
                @(negedge clk_sys);
                pix_we = 0;
                pixb_we = 0;
                wait (normal_bursts >= line_target);
            end
        end
    endtask

    task automatic drive_frame_product_cadence(input integer content_variant);
        integer x, y;
        logic [17:0] a_data, b_data;
        begin
            for (y = 0; y < 192; y = y + 1) begin
                for (x = 0; x < 256; x = x + 1) begin
                    @(negedge clk_sys);
                    pix_we = 1;
                    pixb_we = 1;
                    pix_x = x[7:0];
                    pix_y = y[7:0];
                    pixb_x = x[7:0];
                    pixb_y = y[7:0];
                    a_data = ((x * 13) + (y * 29)) & 18'h3ffff;
                    b_data = ((x * 7) + (y * 31) + 18'h1234) & 18'h3ffff;
                    if (content_variant && (x == 37) && (y == 80))
                        a_data = a_data ^ 18'h15555;
                    pix_d = a_data;
                    pixb_d = b_data;
                    // This live-state change queues odd/even telemetry at the
                    // same boundary as both screen line jobs.
                    if ((y == 0) && (x == 254)) source_fault = 1;
                end
                @(negedge clk_sys);
                pix_we = 0;
                pixb_we = 0;
                if (y != 191) repeat (3104) @(posedge clk_sys);
            end
        end
    endtask

    task automatic wait_record(
        input [31:0] clean_value,
        input [31:0] changed_value,
        input [31:0] required_faults
    );
        integer timeout;
        begin
            timeout = 0;
            while (((published_clean != clean_value) ||
                    (published_changed != changed_value) ||
                    ((published_faults & required_faults) != required_faults)) &&
                   (timeout < 200000)) begin
                @(posedge clk_sys);
                timeout = timeout + 1;
            end
            if (timeout == 200000)
                $fatal(1,
                       "record timeout clean=%0d/%0d changed=%0d/%0d faults=%h/%h",
                       published_clean, clean_value,
                       published_changed, changed_value,
                       published_faults, required_faults);
        end
    endtask

    task automatic adopt_published_frame;
        begin
            @(negedge clk_video);
            pf_scr = 0;
            pf_line = 0;
            pf_bank = 0;
            pf_frame_bank = published_frame_bank;
            pf_tgl = ~pf_tgl;
            wait (!dut.publication_pending);
            repeat (2) @(posedge clk_sys);
        end
    endtask

    logic [31:0] first_hash;
    integer initial_updates;
    integer normal_before_contention;
    integer telemetry_before_contention;
    integer sys_cycles = 0;
    integer contention_start_cycle = 0;
    integer contention_done_cycle = 0;
    logic contention_active = 0;
    logic [1:0] delayed_published_bank = 0;
    logic [1:0] delayed_complete_bank = 0;
    always @(posedge clk_sys) begin
        sys_cycles <= sys_cycles + 1;
        if (contention_active && (contention_done_cycle == 0) &&
            (normal_bursts >= normal_before_contention + 2) &&
            (telemetry_bursts >= telemetry_before_contention + 2))
            contention_done_cycle <= sys_cycles;
    end
    initial begin
        repeat (5) @(posedge clk_sys);
        reset_sys = 0;
        reset_video = 0;

        wait_record(0, 0, 0);
        initial_updates = published_updates;
        if (telemetry_bursts != initial_updates * 2)
            $fatal(1, "publication did not use odd/even pairs");

        drive_frame(0, 0);
        wait_record(1, 1, 0);
        if (published_frame_toggle !== 1'b1 ||
            published_frame_bank !== 2'd1)
            $fatal(1, "first complete frame did not publish bank one");
        adopt_published_frame();
        if (published_faults != 0) $fatal(1, "clean frame raised faults");
        first_hash = published_hash;

        drive_frame(0, 0);
        wait_record(2, 1, 0);
        if (published_frame_toggle !== 1'b0 ||
            published_frame_bank !== 2'd2)
            $fatal(1, "second complete frame did not publish bank two");
        adopt_published_frame();
        if (published_hash != first_hash)
            $fatal(1, "static frame changed the visible hash");

        drive_frame(1, 0);
        wait_record(3, 2, 0);
        if (published_frame_toggle !== 1'b1 ||
            published_frame_bank !== 2'd3)
            $fatal(1, "third complete frame did not publish bank three");
        adopt_published_frame();
        if (published_hash == first_hash)
            $fatal(1, "changed frame kept the static hash");

        drive_frame(1, 1);
        wait_record(3, 2, 32'h00000001);
        if (published_frame_toggle !== 1'b1 ||
            published_frame_bank !== 2'd3)
            $fatal(1, "malformed frame replaced the last complete bank");
        repeat (1000) @(posedge clk_sys);
        if (published_clean != 3 || published_changed != 2)
            $fatal(1, "malformed frame advanced a frame counter");
        if (have_odd) $fatal(1, "test ended inside an odd seqlock phase");

        // Incomplete source frames may use either scratch bank while a final
        // screen descriptor is still draining, but must never wrap into the
        // bank scanout still owns.
        drive_frame(1, 1);
        drive_frame(1, 1);
        if (dut.render_frame_bank_a !== dut.render_frame_bank_b)
            $fatal(1,
                   "incomplete screens selected different scratch banks A=%0d B=%0d",
                   dut.render_frame_bank_a, dut.render_frame_bank_b);
        if (dut.render_frame_bank_a === published_frame_bank ||
            dut.render_frame_bank_b === published_frame_bank)
            $fatal(1, "incomplete frames overwrote published bank %0d",
                   published_frame_bank);

        // Exact documented contention bound: both engines finish one line
        // every 3,360 product clocks (56 us at 60 MHz). Each ch5 job takes the
        // complete documented 600-clock bound (10 us). Queue safe telemetry
        // odd/even with both line jobs and keep line production continuous.
        wait (!service_busy && !dut.dbusy && (dut.runtime_pub_state == 0));
        service_latency_cycles = 600;
        normal_before_contention = normal_bursts;
        telemetry_before_contention = telemetry_bursts;
        contention_done_cycle = 0;
        contention_active = 1;
        fork
            begin
                wait (pix_we && (pix_x == 8'd255) && (pix_y == 8'd0));
                @(posedge clk_sys);
                contention_start_cycle = sys_cycles;
            end
            drive_frame_product_cadence(1);
        join
        wait_record(4, 2, 32'h00000201);
        if (published_frame_toggle !== 1'b0 ||
            published_frame_bank === 2'd0 ||
            published_frame_bank !== dut.render_frame_bank_a ||
            published_frame_bank !== dut.render_frame_bank_b)
            $fatal(1, "good frame after malformed input did not publish its safe scratch bank toggle=%b bank=%0d render=%0d/%0d reserved=%b",
                   published_frame_toggle, published_frame_bank,
                   dut.render_frame_bank_a, dut.render_frame_bank_b,
                   dut.reserved_frame_banks);
        contention_active = 0;
        if (contention_done_cycle == 0)
            $fatal(1, "bounded telemetry/line contention did not drain");
        if ((contention_done_cycle - contention_start_cycle) > 2410)
            $fatal(1, "four bounded ch5 jobs took %0d clocks",
                   contention_done_cycle - contention_start_cycle);
        if ((normal_bursts - normal_before_contention) != 384)
            $fatal(1, "continuous frame lost a screen line job: %0d",
                   normal_bursts - normal_before_contention);
        if (published_faults[3:2] != 0)
            $fatal(1, "bounded contention raised a line-overrun fault: %h",
                   published_faults);
        if (published_session != telemetry_session)
            $fatal(1, "published cartridge session mismatch");
        adopt_published_frame();

        // Keep a completed frame's bank immutable while its final DDR line
        // jobs are still draining.  The next source frame begins before that
        // publication under a long but legal ch5 stall.  Reusing the same
        // unpublished scratch bank here lets scanout adopt it mid-overwrite,
        // producing horizontal bands and apparent backward/forward scrolling.
        wait (!service_busy && !dut.dbusy && !dut.pend_a && !dut.pend_b &&
              (dut.runtime_pub_state == 0));
        delayed_published_bank = published_frame_bank;
        service_latency_cycles = 128;
        for (integer delayed_y = 0; delayed_y < 191; delayed_y++) begin
            integer delayed_target;
            delayed_target = normal_bursts + 2;
            for (integer delayed_x = 0; delayed_x < 256; delayed_x++) begin
                @(negedge clk_sys);
                pix_we = 1;
                pixb_we = 1;
                pix_x = delayed_x[7:0];
                pix_y = delayed_y[7:0];
                pixb_x = delayed_x[7:0];
                pixb_y = delayed_y[7:0];
                pix_d = ((delayed_x * 13) + (delayed_y * 29)) & 18'h3ffff;
                pixb_d = ((delayed_x * 7) + (delayed_y * 31) +
                          18'h1234) & 18'h3ffff;
            end
            @(negedge clk_sys);
            pix_we = 0;
            pixb_we = 0;
            wait (normal_bursts >= delayed_target);
        end
        service_latency_cycles = 200000;
        for (integer delayed_x = 0; delayed_x < 256; delayed_x++) begin
            @(negedge clk_sys);
            pix_we = 1;
            pixb_we = 1;
            pix_x = delayed_x[7:0];
            pix_y = 8'd191;
            pixb_x = delayed_x[7:0];
            pixb_y = 8'd191;
            pix_d = ((delayed_x * 13) + (191 * 29)) & 18'h3ffff;
            pixb_d = ((delayed_x * 7) + (191 * 31) +
                      18'h1234) & 18'h3ffff;
        end
        @(negedge clk_sys);
        pix_we = 0;
        pixb_we = 0;
        wait (service_busy && dut.dbusy && dut.dy == 8'd191);
        delayed_complete_bank = dut.dframe_bank;
        if (delayed_complete_bank === delayed_published_bank)
            $fatal(1, "delayed complete frame reused published bank %0d",
                   delayed_published_bank);
        @(negedge clk_sys);
        pix_we = 1;
        pixb_we = 1;
        pix_x = 0;
        pix_y = 0;
        pixb_x = 0;
        pixb_y = 0;
        pix_d = 18'h12345;
        pixb_d = 18'h23456;
        @(posedge clk_sys);
        #1;
        if ((dut.render_frame_bank_a === delayed_published_bank) ||
            (dut.render_frame_bank_a === delayed_complete_bank) ||
            (dut.render_frame_bank_b !== dut.render_frame_bank_a))
            $fatal(1,
                   "new frame reused immutable bank A=%0d B=%0d published=%0d complete=%0d",
                   dut.render_frame_bank_a, dut.render_frame_bank_b,
                   delayed_published_bank, delayed_complete_bank);
        @(negedge clk_sys);
        pix_we = 0;
        pixb_we = 0;

        // Reproduce the oracle-visible two-position flip directly.  HDMI is
        // still fetching bank zero while the renderer completes two frames.
        // The first completed frame may wait in bank one, but the second must
        // not replace that unacknowledged publication: doing so frees bank one
        // for overwrite even though scanout may already have selected it for
        // its next raster.
        service_latency_cycles = service_cycle + 2;
        wait (!service_busy);
        wait (!dut.dbusy && !dut.pend_a && !dut.pend_b);
        reset_sys = 1;
        repeat (5) @(posedge clk_sys);
        reset_sys = 0;
        drive_frame(0, 0);
        wait (published_frame_toggle == 1'b1 &&
              published_frame_bank == 2'd1);
        drive_frame(1, 0);
        wait (!dut.dbusy && !dut.pend_a && !dut.pend_b);
        if (published_frame_toggle !== 1'b1 ||
            published_frame_bank !== 2'd1)
            $fatal(1,
                   "unacknowledged framebuffer publication was replaced toggle=%b bank=%0d",
                   published_frame_toggle, published_frame_bank);

        // All three current product banks can be live at once: one belongs
        // to scanout, one is an unacknowledged publication, and one is a
        // completed pair waiting in the publication matcher.  Starting a
        // new source frame must not select any of those immutable banks.
        wait (!service_busy && !dut.dbusy && !dut.pend_a && !dut.pend_b);
        force dut.scanout_frame_bank = 2'd0;
        force dut.publication_pending = 1'b1;
        force dut.published_frame_bank = 2'd1;
        force dut.display_commit_valid = 1'b1;
        force dut.display_commit_good = 1'b1;
        force dut.display_commit_bank = 2'd2;
        force dut.render_frame_bank_a = 2'd0;
        force dut.render_frame_bank_b = 2'd0;
        @(negedge clk_sys);
        pix_we = 1;
        pixb_we = 1;
        pix_x = 0;
        pix_y = 0;
        pixb_x = 0;
        pixb_y = 0;
        pix_d = 18'h12345;
        pixb_d = 18'h23456;
        release dut.render_frame_bank_a;
        release dut.render_frame_bank_b;
        @(posedge clk_sys);
        #1;
        if ((dut.render_frame_bank_a == 2'd0) ||
            (dut.render_frame_bank_a == 2'd1) ||
            (dut.render_frame_bank_a == 2'd2) ||
            (dut.render_frame_bank_b != dut.render_frame_bank_a))
            $fatal(1,
                   "three-bank exhaustion reused immutable bank A=%0d B=%0d reserved=%b",
                   dut.render_frame_bank_a, dut.render_frame_bank_b,
                   dut.reserved_frame_banks);
        @(negedge clk_sys);
        pix_we = 0;
        pixb_we = 0;
        release dut.scanout_frame_bank;
        release dut.publication_pending;
        release dut.published_frame_bank;
        release dut.display_commit_valid;
        release dut.display_commit_good;
        release dut.display_commit_bank;

        // A fourth simultaneous owner is handled fail-safe: consume the
        // renderer stream, but enqueue no DDR line from the discarded frame.
        reset_sys = 1;
        repeat (5) @(posedge clk_sys);
        reset_sys = 0;
        wait (!service_busy && !dut.dbusy && !dut.pend_a && !dut.pend_b);
        force dut.reserved_frame_banks = 4'b1111;
        force dut.render_frame_bank_a = 2'd0;
        force dut.render_frame_bank_b = 2'd0;
        @(negedge clk_sys);
        pix_we = 1;
        pixb_we = 1;
        pix_x = 0;
        pix_y = 0;
        pixb_x = 0;
        pixb_y = 0;
        pix_d = 18'h12345;
        pixb_d = 18'h23456;
        release dut.render_frame_bank_a;
        release dut.render_frame_bank_b;
        @(posedge clk_sys);
        #1;
        if (dut.render_frame_writable_a || dut.render_frame_writable_b)
            $fatal(1, "four-bank exhaustion did not discard source frame");
        release dut.reserved_frame_banks;
        for (integer drop_x = 1; drop_x < 256; drop_x++) begin
            @(negedge clk_sys);
            pix_x = drop_x[7:0];
            pixb_x = drop_x[7:0];
        end
        @(negedge clk_sys);
        pix_we = 0;
        pixb_we = 0;
        @(posedge clk_sys);
        #1;
        if (dut.pend_a || dut.pend_b)
            $fatal(1, "discarded source frame enqueued a DDR line");
        if (!dut.bank_diagnostic[3])
            $fatal(1, "discarded source frame did not latch bank diagnostic");

        // The live diagnostic must also latch an attempted write to the bank
        // currently owned by scanout. Let the renderer select a legal scratch
        // bank first, then make only the observed scanout owner alias it while
        // an otherwise normal frame drains.
        reset_sys = 1;
        repeat (5) @(posedge clk_sys);
        reset_sys = 0;
        force dut.scanout_bank_valid = 1'b1;
        fork
            begin
                wait (pix_we && pix_x == 8'd0 && pix_y == 8'd0);
                @(posedge clk_sys);
                #1;
                force dut.scanout_frame_bank = dut.render_frame_bank_a;
            end
            drive_frame(0, 0);
        join
        wait (!dut.dbusy && !dut.pend_a && !dut.pend_b);
        if (!dut.bank_diagnostic[7])
            $fatal(1, "scanout-bank write did not latch bank diagnostic");
        release dut.scanout_frame_bank;
        release dut.scanout_bank_valid;

        $display("PASS: framebuffer telemetry separates clean renderer frames from changed content, latches order faults, writes only 0x3FE30000 padding, and drains four 10us jobs in %0d clocks inside the 3360-clock line interval",
                 contention_done_cycle - contention_start_cycle);
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "global timeout");
    end
endmodule
