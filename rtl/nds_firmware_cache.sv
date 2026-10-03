// SPDX-License-Identifier: GPL-3.0-or-later
// Four 512-byte firmware sectors. Slot 1 transfers bytes; only a matching
// commit_ack after host durable storage clears a dirty line. Session reset
// must not drive reset: an unexpected reset during work is a sticky fault and
// retains dirty data. A clean reset followed by remount is the recovery path.
module nds_firmware_cache #(parameter bit SIMULATE = 0) (
    input logic clk, input logic guest_clk, input logic reset,
    input logic enable, input logic img_mounted, input logic img_readonly,
    input logic [63:0] img_size,
    input logic [15:0] fw_addr, input logic fw_req, input logic fw_wr,
    input logic [1:0] fw_wlane, input logic [7:0] fw_wdata,
    input logic fw_release,
    output logic fw_done, output logic [31:0] fw_data,
    output logic fw_busy,
    input logic flush_req, input logic commit_ack,
    input logic [15:0] commit_sequence,
    output logic mounted = 0, output logic clean,
    output logic persist_pending, output logic [15:0] persist_sequence = 0,
    output logic fault = 0,
    output logic [31:0] sd_lba = 0, output logic sd_rd = 0, output logic sd_wr = 0,
    input logic sd_ack, input logic [12:0] sd_buff_addr,
    input logic [15:0] sd_buff_dout, input logic sd_buff_wr,
    output logic [15:0] sd_buff_din
);
    // Asynchronous assertion, locally synchronized release. Mailbox toggles
    // and payloads reset together, including when one clock is temporarily off.
    (* async_reg="true" *) logic [1:0] reset_g = 2'b11, reset_c = 2'b11;
    always_ff @(posedge guest_clk or posedge reset)
        if (reset) reset_g <= 2'b11; else reset_g <= {reset_g[0],1'b0};
    always_ff @(posedge clk or posedge reset)
        if (reset) reset_c <= 2'b11; else reset_c <= {reset_c[0],1'b0};

    logic req_toggle=0, release_toggle=0, response_toggle=0, release_ack=0;
    logic [15:0] guest_addr=0;
    logic guest_write=0;
    logic [1:0] guest_lane=0;
    logic [7:0] guest_byte=0;
    logic [31:0] response_data=0;
    logic guest_fault=0, release_pending=0;
    (* async_reg="true" *) logic [1:0] response_sync=0, busy_sync=0,
        release_ack_sync=0, enable_sync=0;
    logic response_seen=0;
    wire guest_inflight = req_toggle != response_sync[1];
    wire writeback_busy;
    always_ff @(posedge guest_clk) begin
        fw_done <= 0;
        response_sync <= {response_sync[0],response_toggle};
        release_ack_sync <= {release_ack_sync[0],release_ack};
        enable_sync <= {enable_sync[0],enable};
        busy_sync <= {busy_sync[0],writeback_busy};
        if (reset_g[1]) begin
            req_toggle<=0; release_toggle<=0; response_seen<=0;
            response_sync<=0; release_ack_sync<=0; enable_sync<=0;
            busy_sync<=0; fw_data<=0; guest_fault<=0; release_pending<=0;
        end else begin
            if (enable_sync[1] && (fw_req || fw_wr)) begin
                if (guest_inflight || (fw_req && fw_wr)) guest_fault <= 1;
                else begin
                    guest_addr<=fw_addr; guest_write<=fw_wr;
                    guest_lane<=fw_wlane; guest_byte<=fw_wdata;
                    req_toggle<=~req_toggle;
                end
            end
            // A release can accompany the final byte before its acknowledgement.
            // Wait for that byte to land before forwarding the flush event.
            // Multiple releases coalesce: flushing all dirty lines covers them.
            if (enable_sync[1] && fw_release) release_pending <= 1;
            if (release_pending && !guest_inflight && !fw_req && !fw_wr &&
                release_toggle == release_ack_sync[1]) begin
                release_toggle <= ~release_toggle;
                release_pending <= fw_release;
            end
            if (response_sync[1]!=response_seen) begin
                fw_data<=response_data; fw_done<=1;
                response_seen<=response_sync[1];
            end
        end
    end
    assign fw_busy = enable_sync[1] && (busy_sync[1] || guest_fault || release_pending);

    (* async_reg="true" *) logic [1:0] req_sync=0, release_sync=0, fault_sync=0,
        guest_ready_sync=0;
    logic req_seen=0, release_seen=0;
    logic [3:0] valid=0, dirty=0;
    logic [6:0] tags[0:3];
    logic [15:0] pending_addr=0;
    logic pending_write=0;
    logic [1:0] pending_lane=0, line=0;
    logic [7:0] pending_byte=0;
    logic [1:0] sweep=0;
    logic flush_requested=0, guest_pending=0;
    logic [15:0] lower_half=0;
    logic [8:0] refill_count=0;
    logic refill_bad=0;
    logic [1:0] sd_ack_history=0, drain_count=0;
    always_ff @(posedge clk) sd_ack_history <= {sd_ack_history[0],sd_ack};
    logic [9:0] ram_addr_a;
    logic [15:0] ram_data_a, ram_q_a;
    logic [1:0] ram_be_a;
    logic ram_wr_a;
    typedef enum logic [3:0] {IDLE,LOOKUP,HIT_READ_LO,HIT_READ_HI,HIT_READ_DONE,
        HIT_WRITE,READ_WAIT_ACK,READ_WAIT_END,READ_DRAIN,WRITE_WAIT_ACK,WRITE_WAIT_END,
        WRITE_WAIT_COMMIT} state_t;
    state_t state=IDLE;
    wire reading = state == READ_WAIT_ACK || state == READ_WAIT_END || state == READ_DRAIN;
    wire writing = state == WRITE_WAIT_ACK || state == WRITE_WAIT_END || state == WRITE_WAIT_COMMIT;
    wire release_event = release_sync[1] != release_seen;
    wire request_event = req_sync[1] != req_seen;
    // Incoming sectors are an ordered stream. hps_io's shared absolute buffer
    // address can begin at a stale offset (also handled by the cartridge-save
    // bridge); index from the start of this transfer and require exactly 256
    // halfwords. A short/long sector never becomes valid.
    wire refill_strobe = reading && (sd_ack || |sd_ack_history) && sd_buff_wr;
    wire accept_refill = refill_strobe && refill_count < 256 && !reset_c[1];
    wire [9:0] ram_addr_b = reading ? {line,refill_count[7:0]} : {line,sd_buff_addr[7:0]};
    // One 1024x16 true-dual-port RAM occupies two Cyclone V M10Ks. Explicit
    // instantiation avoids Quartus expanding unsupported inferred old-data
    // read-during-write semantics into registers. Both ports register addresses
    // on CLOCK0 and have unregistered outputs: exactly one read clock.
    // Guest accesses and sector traffic are mutually exclusive, so no consumer
    // uses a read-during-write result. The simulation model poisons those reads.
    generate if(SIMULATE) begin : g_sim_ram
        logic [15:0] ram[0:1023];
        always_ff @(posedge clk) begin
            if(ram_wr_a && ram_be_a[0]) ram[ram_addr_a][7:0]<=ram_data_a[7:0];
            if(ram_wr_a && ram_be_a[1]) ram[ram_addr_a][15:8]<=ram_data_a[15:8];
            if(accept_refill) ram[ram_addr_b]<=sd_buff_dout;
            ram_q_a <= ram_wr_a || (accept_refill && ram_addr_a==ram_addr_b)
                ? 16'hxxxx : ram[ram_addr_a];
            sd_buff_din <= accept_refill || (ram_wr_a && ram_addr_a==ram_addr_b)
                ? 16'hxxxx : ram[ram_addr_b];
        end
    end else begin : g_m10k_ram
        altsyncram #(
            .operation_mode("BIDIR_DUAL_PORT"),
            .intended_device_family("Cyclone V"),.ram_block_type("M10K"),
            .lpm_type("altsyncram"),.power_up_uninitialized("TRUE"),
            .numwords_a(1024),.numwords_b(1024),
            .widthad_a(10),.widthad_b(10),.width_a(16),.width_b(16),
            .width_byteena_a(2),.width_byteena_b(2),.byte_size(8),
            .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),
            .byteena_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
            .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
            .clock_enable_output_a("BYPASS"),.clock_enable_output_b("BYPASS"),
            .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
            .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
            .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
            .read_during_write_mode_mixed_ports("DONT_CARE")
        ) cache_ram (
            .clock0(clk),
            .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),
            .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
            .address_a(ram_addr_a),.data_a(ram_data_a),.byteena_a(ram_be_a),
            .wren_a(ram_wr_a),.rden_a(1'b1),.q_a(ram_q_a),
            .address_b(ram_addr_b),.data_b(sd_buff_dout),.byteena_b(2'b11),
            .wren_b(accept_refill),.rden_b(1'b1),.q_b(sd_buff_din)
        );
    end endgenerate
    assign persist_pending = state==WRITE_WAIT_COMMIT;
    assign writeback_busy = fault || dirty!=0 || writing || flush_requested;
    assign clean = !fault && dirty==0 && state==IDLE && !guest_pending &&
        !request_event && !release_event && !flush_requested && (mounted || !enable) &&
        (!enable || (guest_ready_sync[1] && !reset_c[1]));
    always_comb begin
        ram_addr_a={line,pending_addr[6:0],1'b0};
        ram_data_a={pending_byte,pending_byte};
        ram_be_a=0;ram_wr_a=0;
        if(state==HIT_READ_HI || state==HIT_READ_DONE) ram_addr_a[0]=1;
        if(state==HIT_WRITE && !fault && !reset_c[1]) begin
            ram_addr_a[0]=pending_lane[1];
            ram_be_a=pending_lane[0]?2'b10:2'b01;
            ram_wr_a=1;
        end
    end
    always_ff @(posedge clk) begin
        guest_ready_sync <= {guest_ready_sync[0],!reset_g[1]};
        // A stopped guest clock may still expose pre-reset toggle levels.
        // Discard them until that domain has actually executed its reset.
        if(guest_ready_sync[1]) begin
            req_sync<={req_sync[0],req_toggle};
            release_sync<={release_sync[0],release_toggle};
            fault_sync<={fault_sync[0],guest_fault};
        end else begin req_sync<=0;release_sync<=0;fault_sync<=0;end
        if(reset_c[1]) begin
            guest_ready_sync<=0;
            req_sync<=0; release_sync<=0; fault_sync<=0;
            req_seen<=0; release_seen<=0; release_ack<=0;
            response_toggle<=0; response_data<=0; guest_pending<=0;
            // Never silently erase acknowledged but uncommitted writes, nor
            // mistake a late sector ack for a request after a reset.
            if(dirty!=0 || state!=IDLE || sd_ack) begin
                fault<=1;
                if(!reading && !writing) state<=IDLE;
            end else begin
                valid<=0; mounted<=0; fault<=0; flush_requested<=0;
                state<=IDLE; sd_rd<=0; sd_wr<=0; sd_lba<=0;
                sweep<=0; line<=0; refill_count<=0; refill_bad<=0;
                // Do not reuse a sequence after a clean runtime reset.
            end
        end else begin
            if(fault_sync[1]) fault<=1;
            if(flush_req || release_event) flush_requested<=1;
            if(release_event) begin
                release_seen<=release_sync[1]; release_ack<=release_sync[1];
            end
            if(img_mounted) begin
                if(dirty!=0 || state!=IDLE || guest_pending || request_event || sd_ack ||
                   img_readonly || img_size!=262144) fault<=1;
                else begin mounted<=1; valid<=0; flush_requested<=0; end
            end
            if(request_event && !guest_pending && !fault && !fault_sync[1]) begin
                pending_addr<=guest_addr; pending_write<=guest_write;
                pending_lane<=guest_lane; pending_byte<=guest_byte;
                req_seen<=req_sync[1]; guest_pending<=1;
            end
            if(refill_strobe) begin
                if(refill_count==256) begin refill_bad<=1; fault<=1; end
                else refill_count<=refill_count+1'b1;
            end
            case(state)
                IDLE: begin
                    if(guest_pending && !fault && !fault_sync[1]) begin
                        if(!mounted || !enable) fault<=1;
                        else begin line<=pending_addr[8:7];state<=LOOKUP;end
                    end else if(flush_requested) begin
                        if(dirty==0) begin
                            if(!flush_req && !release_event && !request_event) flush_requested<=0;
                        end else if(dirty[sweep]) begin
                            line<=sweep; sd_lba<={23'd0,tags[sweep],sweep};
                            sd_wr<=1; persist_sequence<=persist_sequence+1'b1;
                            state<=WRITE_WAIT_ACK;
                        end else sweep<=sweep+1'b1;
                    end
                end
                LOOKUP: if(!fault && !fault_sync[1]) begin
                    if(valid[line] && tags[line]==pending_addr[15:9]) begin
                        if(pending_write) state<=HIT_WRITE;
                        else state<=HIT_READ_LO;
                    end
                    else if(valid[line] && dirty[line]) begin
                        sd_lba<={23'd0,tags[line],line};sd_wr<=1;
                        persist_sequence<=persist_sequence+1'b1;
                        state<=WRITE_WAIT_ACK;
                    end else begin
                        sd_lba<={23'd0,pending_addr[15:7]};sd_rd<=1;
                        valid[line]<=0;refill_count<=0;refill_bad<=0;state<=READ_WAIT_ACK;
                    end
                end else state<=IDLE;
                HIT_READ_LO: if(!fault) state<=HIT_READ_HI; else state<=IDLE;
                HIT_READ_HI: if(!fault) begin lower_half<=ram_q_a;state<=HIT_READ_DONE;end else state<=IDLE;
                HIT_READ_DONE: if(!fault) begin
                    response_data<={ram_q_a,lower_half};response_toggle<=req_seen;
                    guest_pending<=0;state<=IDLE;
                end else state<=IDLE;
                HIT_WRITE: if(!fault) begin
                    dirty[line]<=1;response_data<=0;response_toggle<=req_seen;
                    guest_pending<=0;state<=IDLE;
                end else state<=IDLE;
                READ_WAIT_ACK: if(sd_ack) state<=READ_WAIT_END;
                READ_WAIT_END: if(!sd_ack) begin
                    // hps_io registers its buffer strobe; the final halfword
                    // can arrive after ack falls. Drain before publishing valid.
                    sd_rd<=0;drain_count<=2;state<=READ_DRAIN;
                end
                READ_DRAIN: if(drain_count!=0) drain_count<=drain_count-1'b1;
                else begin
                    if(refill_count!=256 || refill_bad || fault || fault_sync[1]) begin
                        fault<=1;valid[line]<=0;state<=IDLE;
                    end else begin
                        valid[line]<=1;tags[line]<=pending_addr[15:9];state<=LOOKUP;
                    end
                end
                WRITE_WAIT_ACK: if(sd_ack) state<=WRITE_WAIT_END;
                WRITE_WAIT_END: if(!sd_ack) begin sd_wr<=0;state<=WRITE_WAIT_COMMIT;end
                WRITE_WAIT_COMMIT: if(commit_ack && commit_sequence==persist_sequence) begin
                    dirty[line]<=0;state<=IDLE;
                end
                default: begin fault<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
