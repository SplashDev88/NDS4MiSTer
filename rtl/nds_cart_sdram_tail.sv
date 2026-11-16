// SPDX-License-Identifier: GPL-3.0-or-later
// Exact cartridge bytes 464..512 MiB live at SDRAM byte addresses 16..64 MiB.
// One bundled-data toggle transaction owns channel 3 until its physical reply.
// Guest reset never resets this bridge or discards an accepted SDRAM request.
module nds_cart_sdram_tail #(
    parameter logic [26:0] TAIL_BYTES = 27'h3000000
) (
    input logic clk, mem_clk, reset,
    input logic cart_download, full_download, ioctl_wr,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_data,
    output logic ioctl_wait, loaded, fault,
    input logic read_req,
    input logic [25:0] read_addr,
    output logic read_ready,
    output logic [31:0] read_data,
    output logic [26:1] ram_addr,
    output logic [15:0] ram_data,
    output logic ram_req, ram_rnw,
    input logic ram_ready,
    input logic [63:0] ram_result
);
    logic download_d, full_active;
    logic [26:0] received;
    logic command_toggle, response_toggle, response_seen;
    logic command_read, pending_read, pending_high;
    logic [22:0] pending_tag, cache_tag;
    logic [63:0] response_data, cache_data;
    logic cache_valid;
    (* async_reg="true" *) logic [2:0] response_sync;
    wire busy = command_toggle != response_sync[2];
    assign ioctl_wait = full_download && busy;
    assign loaded = !full_active ||
        (!cart_download && received == TAIL_BYTES && !busy && !fault);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            download_d<=0; full_active<=0; received<=0; fault<=0;
            command_toggle<=0; response_seen<=0; response_sync<=0;
            command_read<=0; pending_read<=0; pending_high<=0; pending_tag<=0;
            ram_addr<=0; ram_data<=0; cache_valid<=0; cache_tag<=0; cache_data<=0;
            read_ready<=0; read_data<=0;
        end else begin
            download_d<=cart_download;
            response_sync<={response_sync[1:0],response_toggle};
            read_ready<=0;
            if (cart_download) cache_valid<=0;
            if (cart_download && !download_d) begin
                full_active<=full_download; received<=0; fault<=0;
            end
            if (response_sync[2] != response_seen) begin
                response_seen<=response_sync[2];
                if (pending_read) begin
                    read_data<=pending_high ? response_data[63:32] : response_data[31:0];
                    read_ready<=1;
                    cache_data<=response_data; cache_tag<=pending_tag;
                    cache_valid<=!cart_download && received==TAIL_BYTES && !fault;
                end
                pending_read<=0;
            end
            if (ioctl_wr && full_download) begin
                // Monotonic complete upload only. A malformed transfer cannot
                // expose an old cartridge's unwritten tail to either CPU.
                if (busy || ioctl_addr!=received || received>=TAIL_BYTES || ioctl_addr[0])
                    fault<=1;
                else if (!fault) begin
                    ram_addr<=26'h0800000 + {1'b0,ioctl_addr[25:1]};
                    ram_data<=ioctl_data; command_read<=0; pending_read<=0;
                    command_toggle<=~command_toggle; received<=received+27'd2;
                end
            end else if (read_req && !cart_download && full_active && loaded && !busy) begin
                if ({1'b0,read_addr} >= TAIL_BYTES) begin
                    read_data<=32'hffffffff; read_ready<=1;
                end else if (cache_valid && cache_tag==read_addr[25:3]) begin
                    read_data<=read_addr[2] ? cache_data[63:32] : cache_data[31:0];
                    read_ready<=1;
                end else begin
                    ram_addr<=26'h0800000 + {1'b0,read_addr[25:3],2'b00};
                    command_read<=1; pending_read<=1; pending_high<=read_addr[2];
                    pending_tag<=read_addr[25:3]; command_toggle<=~command_toggle;
                end
            end
        end
    end

    (* async_reg="true" *) logic [2:0] command_sync;
    logic command_seen, mem_busy;
    assign ram_rnw=command_read;
    always_ff @(posedge mem_clk or posedge reset) begin
        if (reset) begin
            command_sync<=0;command_seen<=0;mem_busy<=0;ram_req<=0;
            response_toggle<=0;response_data<=0;
        end else begin
            command_sync<={command_sync[1:0],command_toggle}; ram_req<=0;
            if (!mem_busy && command_sync[2]!=command_seen) begin
                command_seen<=command_sync[2];ram_req<=1;mem_busy<=1;
            end else if (mem_busy && ram_ready) begin
                response_data<=ram_result;response_toggle<=command_seen;mem_busy<=0;
            end
        end
    end
endmodule
