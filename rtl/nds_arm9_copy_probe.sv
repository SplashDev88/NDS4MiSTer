module nds_arm9_copy_probe #(
    parameter bit BUILDTIME_PROBE = 0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic        done,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] address,
    input  logic [31:0] write_data,
    input  logic [31:0] read_data,
    input  logic [31:0] execute_pc,
    output logic [2:0]  phase,
    output logic [7:0]  value,
    output logic        ready
);
    logic [17:0] phase_counter;
    logic copy_window_seen;
    logic source_seen;
    logic destination_write_seen;
    logic destination_read_seen;
    logic [15:0] source_halfword;
    logic [15:0] destination_write_halfword;
    logic [15:0] destination_read_halfword;
    logic alignment_snapshot_seen;
    logic [31:0] alignment_snapshot;
    logic argument_preload_seen;
    logic argument_postload_seen;
    logic argument_postadd_seen;
    logic [31:0] argument_preload;
    logic [31:0] argument_postload;
    logic [31:0] argument_postadd;
    logic [1:0] destination_write_access;
    logic [31:0] destination_write_address;
    logic [31:0] destination_write_pc;
    logic [1:0] buildtime_source_hits;
    logic [1:0] buildtime_write_hits;
    logic buildtime_copy_started;
    logic buildtime_snapshot_complete;
    logic pending;
    logic pending_read_not_write;
    logic [1:0] pending_access;
    logic [31:0] pending_address;
    logic [31:0] pending_write_data;
    logic [31:0] pending_execute_pc;

    wire copy_window =
        execute_pc >= 32'h02067070 && execute_pc <= 32'h020671a8;
    wire completion_valid = done && (pending || request);
    wire completion_read_not_write =
        pending ? pending_read_not_write : read_not_write;
    wire [31:0] completion_address =
        pending ? pending_address : address;
    wire [31:0] completion_write_data =
        pending ? pending_write_data : write_data;
    wire [1:0] completion_access =
        pending ? pending_access : access;
    wire [31:0] completion_execute_pc =
        pending ? pending_execute_pc : execute_pc;
    wire completion_copy_window =
        completion_execute_pc >= 32'h02067070 &&
        completion_execute_pc <= 32'h020671a8;
    wire completion_filesystem_callback = BUILDTIME_PROBE
        ? completion_execute_pc >= 32'h020697c0 &&
          completion_execute_pc <= 32'h020697d0
        : completion_execute_pc >= 32'h020694b8 &&
          completion_execute_pc <= 32'h02069518;
    wire completion_source_window = BUILDTIME_PROBE
        ? completion_address[31:1] == 31'h0104b544
        : completion_address >= 32'h02096a80 &&
          completion_address < 32'h02096b00;
    wire completion_destination_word = BUILDTIME_PROBE
        ? completion_address[31:1] == 31'h013f1bec
        : completion_address[31:1] == 31'h013f1bc6;

    assign phase = phase_counter[17:15];
    assign ready = BUILDTIME_PROBE
        ? buildtime_snapshot_complete
        : argument_preload_seen && argument_postload_seen &&
          argument_postadd_seen;

    always_comb begin
        if (BUILDTIME_PROBE) begin
            case (phase)
                3'd0: value = source_halfword[7:0];
                3'd1: value = source_halfword[15:8];
                3'd2: value = destination_write_halfword[7:0];
                3'd3: value = destination_write_halfword[15:8];
                3'd4: value = destination_read_halfword[7:0];
                3'd5: value = destination_read_halfword[15:8];
                3'd6: value = {
                    source_seen,
                    destination_write_seen,
                    destination_read_seen,
                    destination_write_access,
                    destination_write_address[2:0]
                };
                default: value = destination_write_pc[7:0];
            endcase
        end else if (ready) begin
            case (phase)
                3'd0: value = argument_preload[7:0];
                3'd1: value = argument_preload[15:8];
                3'd2: value = argument_preload[23:16];
                3'd3: value = argument_postload[7:0];
                3'd4: value = argument_postload[15:8];
                3'd5: value = argument_postadd[7:0];
                3'd6: value = argument_postadd[15:8];
                default: value = argument_postadd[23:16];
            endcase
        end else if (alignment_snapshot_seen) begin
            case (phase)
                3'd0: value = alignment_snapshot[7:0];
                3'd1: value = alignment_snapshot[15:8];
                3'd2: value = alignment_snapshot[23:16];
                3'd3: value = alignment_snapshot[31:24];
                3'd4: value = 8'h01;
                default: value = execute_pc[7:0];
            endcase
        end else begin
            case (phase)
                3'd0: value = source_halfword[7:0];
                3'd1: value = source_halfword[15:8];
                3'd2: value = destination_write_halfword[7:0];
                3'd3: value = destination_write_halfword[15:8];
                3'd4: value = destination_read_halfword[7:0];
                3'd5: value = destination_read_halfword[15:8];
                3'd6: value = {
                    copy_window_seen,
                    source_seen,
                    destination_write_seen,
                    destination_read_seen,
                    source_halfword[7:0] == 8'h07 ||
                        source_halfword[15:8] == 8'h07,
                    destination_write_halfword[7:0] == 8'h07,
                    destination_read_halfword[7:0] == 8'h07,
                    destination_read_halfword[7:0] ==
                        destination_write_halfword[7:0]
                };
                default: value = execute_pc[7:0];
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            phase_counter <= 0;
            copy_window_seen <= 0;
            source_seen <= 0;
            destination_write_seen <= 0;
            destination_read_seen <= 0;
            source_halfword <= 0;
            destination_write_halfword <= 0;
            destination_read_halfword <= 0;
            alignment_snapshot_seen <= 0;
            alignment_snapshot <= 0;
            argument_preload_seen <= 0;
            argument_postload_seen <= 0;
            argument_postadd_seen <= 0;
            argument_preload <= 0;
            argument_postload <= 0;
            argument_postadd <= 0;
            destination_write_access <= 0;
            destination_write_address <= 0;
            destination_write_pc <= 0;
            buildtime_source_hits <= 0;
            buildtime_write_hits <= 0;
            buildtime_copy_started <= 0;
            buildtime_snapshot_complete <= 0;
            pending <= 0;
            pending_read_not_write <= 1;
            pending_access <= 0;
            pending_address <= 0;
            pending_write_data <= 0;
            pending_execute_pc <= 0;
        end else begin
            phase_counter <= phase_counter + 1'b1;
            if (copy_window)
                copy_window_seen <= 1;
            if (!alignment_snapshot_seen &&
                execute_pc[31:28] == 4'hd) begin
                alignment_snapshot_seen <= 1;
                alignment_snapshot <= execute_pc;
            end
            if (!argument_preload_seen &&
                execute_pc[31:28] == 4'ha) begin
                argument_preload_seen <= 1;
                argument_preload <= execute_pc;
            end
            if (!argument_postload_seen &&
                execute_pc[31:28] == 4'hb) begin
                argument_postload_seen <= 1;
                argument_postload <= execute_pc;
            end
            if (!argument_postadd_seen &&
                execute_pc[31:28] == 4'hc) begin
                argument_postadd_seen <= 1;
                argument_postadd <= execute_pc;
            end
            if (BUILDTIME_PROBE) begin
                // NSMB reuses this SDK scratch buffer. The first copy writes
                // an earlier directory field; BUILDTIME is the second copy.
                // Address 0x02096a88 is read once at the tail of the earlier
                // odd-length copy and again as BUILDTIME's unaligned seed.
                // Likewise 0x027e37d8 is the first destination halfword of
                // both copies. Select the second completed occurrence of
                // each, independently of its data, then freeze the first
                // comparison read that follows the target copy.
                if (completion_valid && completion_read_not_write &&
                    completion_copy_window && completion_source_window &&
                    buildtime_source_hits != 2) begin
                    buildtime_source_hits <= buildtime_source_hits + 1'b1;
                    if (buildtime_source_hits == 1) begin
                        source_seen <= 1;
                        source_halfword <= read_data[15:0];
                        buildtime_copy_started <= 1;
                    end
                end
                if (completion_valid && !completion_read_not_write &&
                    completion_copy_window && completion_destination_word &&
                    buildtime_write_hits != 2) begin
                    buildtime_write_hits <= buildtime_write_hits + 1'b1;
                    if (buildtime_write_hits == 1) begin
                        destination_write_seen <= 1;
                        destination_write_halfword <=
                            completion_write_data[15:0];
                        destination_write_access <= completion_access;
                        destination_write_address <= completion_address;
                        destination_write_pc <= completion_execute_pc;
                        buildtime_copy_started <= 1;
                    end
                end
                if (completion_valid && completion_read_not_write &&
                    completion_filesystem_callback &&
                    completion_destination_word &&
                    buildtime_copy_started &&
                    !buildtime_snapshot_complete) begin
                    destination_read_seen <= 1;
                    destination_read_halfword <= read_data[15:0];
                    buildtime_snapshot_complete <= 1;
                end
            end else begin
                if (completion_valid && completion_read_not_write &&
                    completion_copy_window && completion_source_window &&
                    !source_seen) begin
                    source_seen <= 1;
                    source_halfword <= read_data[15:0];
                end
                if (completion_valid && !completion_read_not_write &&
                    completion_copy_window && completion_destination_word &&
                    !destination_write_seen) begin
                    destination_write_seen <= 1;
                    destination_write_halfword <=
                        completion_write_data[15:0];
                    destination_write_access <= completion_access;
                    destination_write_address <= completion_address;
                    destination_write_pc <= completion_execute_pc;
                end
                if (completion_valid && completion_read_not_write &&
                    completion_filesystem_callback &&
                    completion_destination_word &&
                    !destination_read_seen) begin
                    destination_read_seen <= 1;
                    destination_read_halfword <= read_data[15:0];
                end
            end

            // gba_cpu pulses request only when launching a transfer and may
            // launch its next transfer on the edge that completes the prior
            // one. Preserve the accepted transaction metadata until done so
            // this passive probe observes the production handshake without
            // requiring request and done to overlap.
            if (done && pending) begin
                if (request) begin
                    pending <= 1;
                    pending_read_not_write <= read_not_write;
                    pending_access <= access;
                    pending_address <= address;
                    pending_write_data <= write_data;
                    pending_execute_pc <= execute_pc;
                end else begin
                    pending <= 0;
                end
            end else if (request) begin
                if (!done) begin
                    pending <= 1;
                    pending_read_not_write <= read_not_write;
                    pending_access <= access;
                    pending_address <= address;
                    pending_write_data <= write_data;
                    pending_execute_pc <= execute_pc;
                end else begin
                    pending <= 0;
                end
            end
        end
    end
endmodule
