// SPDX-License-Identifier: GPL-3.0-or-later
// Native firmware lifecycle and BIOS upload channel. All new control paths
// remain idle during normal cartridge play. Assets change only while held.
module nds_firmware_control #(parameter bit SIMULATE = 0) (
    input logic clk, clk7, clk9, reset,
    input logic io_enable, io_strobe,
    input logic [15:0] io_din,
    output logic io_override,
    output logic [15:0] io_dout,
    input logic ioctl_download, ioctl_wr,
    input logic [15:0] ioctl_index, ioctl_dout,
    input logic [26:0] ioctl_addr,
    output logic ioctl_wait,
    input logic mounted, clean, cache_fault, persist_pending,
    input logic [15:0] persist_sequence,
    output logic hold_console, native_mode,
    output logic bios7_ready, bios9_ready, profile_ready, direct_profile_ready,
    output logic fault,
    output logic flush_req, commit_ack,
    output logic [15:0] commit_sequence,
    output logic [11:0] bios7_addr,
    output logic [31:0] bios7_data,
    output logic [3:0] bios7_be,
    output logic bios7_we,
    output logic [9:0] bios9_addr,
    output logic [31:0] bios9_data,
    output logic [3:0] bios9_be,
    output logic bios9_we,
    output logic [6:0] builtin_addr,
    output logic [31:0] builtin_data,
    output logic [3:0] builtin_be,
    output logic builtin_we,
    input logic [4:0] profile_addr,
    output logic [31:0] profile_data,
    output logic [31:0] profile_fw_offset, profile_fw_checksums
);
    logic control_fault=0;
    logic [15:0] error_code=0, operation=0;
    logic [2:0] io_count=0;
    logic selected=0;
    logic active=0, finishing=0, transfer_bad=0;
    logic [2:0] asset=0;
    logic [14:0] received=0;
    wire asset_index=ioctl_index==4 || ioctl_index==5 || ioctl_index==6 || ioctl_index==7;
    wire asset_download=ioctl_download && asset_index;
    wire [14:0] expected=asset==4?15'd16384:asset==5?15'd4096:asset==7?15'd512:15'd120;
    wire [15:0] flags={6'd0,direct_profile_ready,persist_pending,fault,mounted,clean,
        profile_ready,bios9_ready,bios7_ready,native_mode,hold_console};
    assign fault=control_fault | cache_fault;
    assign io_override=io_enable && selected;

    logic send7=0,send9=0,send_builtin=0;
    logic [13:0] upload_addr=0;
    logic [15:0] upload_data=0;
    wire busy7,busy9,busy_builtin;
    assign ioctl_wait=busy7 || busy9 || busy_builtin || send7 || send9 || send_builtin || finishing;
    nds_firmware_upload_cdc #(.ADDR_BITS(12)) upload7 (
        .clk,.target_clk(clk7),.reset,.send(send7),.addr(upload_addr[13:1]),
        .data(upload_data),.busy(busy7),.write_addr(bios7_addr),
        .write_data(bios7_data),.write_be(bios7_be),.write_enable(bios7_we)
    );
    nds_firmware_upload_cdc #(.ADDR_BITS(10)) upload9 (
        .clk,.target_clk(clk9),.reset,.send(send9),.addr(upload_addr[11:1]),
        .data(upload_data),.busy(busy9),.write_addr(bios9_addr),
        .write_data(bios9_data),.write_be(bios9_be),.write_enable(bios9_we)
    );
    // FIO7 contains only two generated user-settings pages. The generated
    // SPI RAM has one registered config-write stage; acknowledge after commit.
    nds_firmware_upload_cdc #(.ADDR_BITS(7),.EXTRA_ACK_CYCLE(1)) upload_builtin (
        .clk,.target_clk(clk7),.reset,.send(send_builtin),.addr(upload_addr[8:1]),
        .data(upload_data),.busy(busy_builtin),.write_addr(builtin_addr),
        .write_data(builtin_data),.write_be(builtin_be),.write_enable(builtin_we)
    );

    // Profile is immutable while the CPUs run. A mixed-width dual-clock M10K
    // accepts one host halfword and returns one little-endian loader word.
    // Explicit RAM avoids Quartus implementing the partial-write array as FFs.
    wire profile_write=active && !transfer_bad && ioctl_wr &&
        ioctl_download && ioctl_index=={13'd0,asset} && ioctl_addr=={12'd0,received} &&
        ((asset==6 && received>=8 && received<120) ||
         (asset==7 && received<112)) && hold_console;
    wire [5:0] profile_write_addr=asset==7?received[6:1]:received[6:1]-6'd4;
    generate if(SIMULATE) begin : g_sim_profile
        logic [15:0] profile_halfwords[0:63];
        always_ff @(posedge clk) if(profile_write)
            profile_halfwords[profile_write_addr]<=ioctl_dout;
        always_ff @(posedge clk7)
            profile_data<={profile_halfwords[{profile_addr,1'b1}],
                           profile_halfwords[{profile_addr,1'b0}]};
    end else begin : g_m10k_profile
        altsyncram #(
            .operation_mode("DUAL_PORT"),.intended_device_family("Cyclone V"),
            .ram_block_type("M10K"),.lpm_type("altsyncram"),
            .power_up_uninitialized("TRUE"),
            .numwords_a(64),.widthad_a(6),.width_a(16),.width_byteena_a(1),
            .numwords_b(32),.widthad_b(5),.width_b(32),.width_byteena_b(1),
            .address_reg_b("CLOCK1"),.outdata_reg_b("UNREGISTERED"),
            .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
            .clock_enable_output_a("BYPASS"),.clock_enable_output_b("BYPASS"),
            .read_during_write_mode_mixed_ports("DONT_CARE")
        ) profile_ram (
            .clock0(clk),.clock1(clk7),
            .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),
            .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
            .address_a(profile_write_addr),.data_a(ioctl_dout),
            .byteena_a(1'b1),.wren_a(profile_write),.rden_a(1'b1),
            .address_b(profile_addr),.data_b(32'b0),.byteena_b(1'b1),
            .wren_b(1'b0),.rden_b(1'b1),.q_b(profile_data)
        );
    end endgenerate

    always_ff @(posedge clk) begin
        send7<=0;send9<=0;send_builtin<=0;flush_req<=0;commit_ack<=0;
        if(reset) begin
            hold_console<=0;native_mode<=0;bios7_ready<=0;bios9_ready<=0;
            profile_ready<=0;direct_profile_ready<=0;control_fault<=0;error_code<=0;
            io_count<=0;selected<=0;io_dout<=0;operation<=0;
            active<=0;finishing<=0;transfer_bad<=0;asset<=0;received<=0;
            profile_fw_offset<=32'h0001fe00;profile_fw_checksums<=32'h00000000;
            commit_sequence<=0;upload_addr<=0;upload_data<=0;
        end else begin
            if(!io_enable) begin io_count<=0;selected<=0;io_dout<=0;end
            else if(io_strobe) begin
                if(io_count!=7) io_count<=io_count+1'b1;
                if(io_count==0) begin
                    selected<=io_din==16'h45;
                    io_dout<=io_din==16'h45 ? 16'h4657 : 16'd0;
                end else if(selected) case(io_count)
                    1: begin operation<=io_din;io_dout<=flags;end
                    2: begin
                        io_dout<=persist_sequence;
                        case(operation)
                            0: ;
                            1: begin hold_console<=1;control_fault<=0;error_code<=0;end
                            2: begin
                                if(hold_console && bios7_ready && bios9_ready &&
                                   profile_ready && !direct_profile_ready && mounted && clean && !fault &&
                                   !active && !ioctl_wait) begin
                                    native_mode<=1;hold_console<=0;
                                end else begin control_fault<=1;error_code<=16'd2;end
                            end
                            3: begin
                                if(hold_console && !fault && !active && !ioctl_wait &&
                                   bios7_ready && bios9_ready && direct_profile_ready &&
                                   (!mounted || clean)) begin
                                    native_mode<=0;hold_console<=0;
                                end else begin control_fault<=1;error_code<=16'd3;end
                            end
                            4: flush_req<=1;
                            5: begin commit_ack<=1;commit_sequence<=io_din;end
                            6: begin hold_console<=1;control_fault<=1;error_code<=16'd6;end
                            default: begin control_fault<=1;error_code<=16'd7;end
                        endcase
                    end
                    3: io_dout<=cache_fault?16'h8001:error_code;
                    default: io_dout<=0;
                endcase
            end
            if(!active && !finishing && asset_download) begin
                active<=1;asset<=ioctl_index[2:0];received<=0;
                transfer_bad<=!hold_console;
                case(ioctl_index)
                    4: bios7_ready<=0;
                    5: bios9_ready<=0;
                    6: begin profile_ready<=0;direct_profile_ready<=0;end
                    7: begin
                        profile_ready<=0;direct_profile_ready<=0;
                        // Metadata belongs to the generated firmware, never
                        // to the optional native GUI image.
                        profile_fw_offset<=32'h0001fe00;
                        profile_fw_checksums<=32'h00000000;
                    end
                endcase
                if(!hold_console) begin control_fault<=1;error_code<=16'd8;end
            end
            if(active && ioctl_wr && ioctl_download) begin
                if(!hold_console || ioctl_index!={13'd0,asset} ||
                   ioctl_addr!={12'd0,received} || received>=expected ||
                   busy7 || busy9 || busy_builtin || send7 || send9 || send_builtin) begin
                    transfer_bad<=1;control_fault<=1;error_code<=16'd9;
                end else if(!transfer_bad) begin
                    received<=received+15'd2;
                    upload_addr<=ioctl_addr[13:0];upload_data<=ioctl_dout;
                    if(asset==4) send7<=1;
                    else if(asset==5) send9<=1;
                    else if(asset==7) send_builtin<=1;
                    else case(received)
                        0: profile_fw_offset[15:0]<=ioctl_dout;
                        2: profile_fw_offset[31:16]<=ioctl_dout;
                        4: profile_fw_checksums[15:0]<=ioctl_dout;
                        6: profile_fw_checksums[31:16]<=ioctl_dout;
                    endcase
                end
            end
            if(active && !asset_download) begin active<=0;finishing<=1;end
            if(finishing && !busy7 && !busy9 && !busy_builtin && !send7 && !send9 && !send_builtin) begin
                finishing<=0;
                if(!transfer_bad && received==expected) case(asset)
                    4: bios7_ready<=1;
                    5: bios9_ready<=1;
                    6: profile_ready<=1;
                    7: begin profile_ready<=1;direct_profile_ready<=1;end
                endcase
                else begin control_fault<=1;error_code<=16'd10;end
            end
        end
    end
endmodule

// One-word bundled-data mailbox. The acknowledgement is delayed until the
// target RAM has sampled its write pulse, including when target clocks differ.
module nds_firmware_upload_cdc #(parameter ADDR_BITS=12, parameter bit EXTRA_ACK_CYCLE=0) (
    input logic clk,target_clk,reset,send,
    input logic [ADDR_BITS:0] addr,
    input logic [15:0] data,
    output logic busy,
    output logic [ADDR_BITS-1:0] write_addr,
    output logic [31:0] write_data,
    output logic [3:0] write_be,
    output logic write_enable
);
    logic request=0,ack=0;
    logic [ADDR_BITS:0] held_addr;
    logic [15:0] held_data;
    (* async_reg="true" *) logic [1:0] ack_sync=0,request_sync=0;
    logic seen=0,write_pending=0;
    assign busy=request!=ack_sync[1];
    always_ff @(posedge clk) begin
        ack_sync<={ack_sync[0],ack};
        if(reset) begin request<=0;ack_sync<=0;held_addr<=0;held_data<=0;end
        else if(send && !busy) begin
            held_addr<=addr;held_data<=data;request<=~request;
        end
    end
    always_ff @(posedge target_clk) begin
        request_sync<={request_sync[0],request};
        write_enable<=0;
        if(reset) begin
            request_sync<=0;seen<=0;ack<=0;write_enable<=0;write_pending<=0;
            write_addr<=0;write_data<=0;write_be<=0;
        end else if(write_enable) begin
            if(EXTRA_ACK_CYCLE) write_pending<=1;
            else ack<=seen;
        end else if(write_pending) begin ack<=seen;write_pending<=0;end
        else if(request_sync[1]!=seen) begin
            seen<=request_sync[1];write_addr<=held_addr[ADDR_BITS:1];
            write_data<={held_data,held_data};
            write_be<=held_addr[0]?4'b1100:4'b0011;write_enable<=1;
        end
    end
endmodule
