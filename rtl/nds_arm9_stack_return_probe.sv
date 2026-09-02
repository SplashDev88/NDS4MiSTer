// Passive diagnostic for the ARM9 SDK/BIOS return that currently ends at
// 0x01ffd280. The final LDMIA sp!,{r11,pc} reads DTCM words 0x027e3924 and
// 0x027e3928. Native execution reads 0x0204d4c8 from the second word, while
// hardware subsequently requests instruction address 0xe5823004.
//
// Record both the last completed write to the saved-PC word and the two
// completed reads performed by the return. This distinguishes corrupt stack
// production from a local TCM storage/response failure without changing CPU
// traffic or completion timing.
module nds_arm9_stack_return_probe (
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
    output logic [3:0]  phase,
    output logic [7:0]  value,
    output logic        ready
);
    localparam logic [31:0] STACK_WORD0 = 32'h027e3924;
    localparam logic [31:0] STACK_WORD1 = 32'h027e3928;
    localparam logic [31:0] RETURN_PC   = 32'h01ffd280;

    logic [18:0] phase_counter;
    logic pending;
    logic pending_read_not_write;
    logic [1:0] pending_access;
    logic [31:0] pending_address;
    logic [31:0] pending_write_data;
    logic [31:0] pending_execute_pc;

    logic write_seen;
    logic word0_read_seen;
    logic word1_read_seen;
    logic [31:0] word1_write_data;
    logic [31:0] word1_write_pc;
    logic [31:0] word0_read_data;
    logic [31:0] word1_read_data;

    wire completion_valid = done && (pending || request);
    wire completion_read_not_write =
        pending ? pending_read_not_write : read_not_write;
    wire [1:0] completion_access =
        pending ? pending_access : access;
    wire [31:0] completion_address =
        pending ? pending_address : address;
    wire [31:0] completion_write_data =
        pending ? pending_write_data : write_data;
    wire [31:0] completion_execute_pc =
        pending ? pending_execute_pc : execute_pc;

    assign phase = phase_counter[18:15];
    assign ready = write_seen && word0_read_seen && word1_read_seen;

    always_comb begin
        case (phase)
            4'd0:  value = word1_write_data[7:0];
            4'd1:  value = word1_write_data[15:8];
            4'd2:  value = word1_write_data[23:16];
            4'd3:  value = word1_write_data[31:24];
            4'd4:  value = word1_read_data[7:0];
            4'd5:  value = word1_read_data[15:8];
            4'd6:  value = word1_read_data[23:16];
            4'd7:  value = word1_read_data[31:24];
            4'd8:  value = word1_write_pc[7:0];
            4'd9:  value = word1_write_pc[15:8];
            4'd10: value = word1_write_pc[23:16];
            4'd11: value = word1_write_pc[31:24];
            4'd12: value = word0_read_data[7:0];
            4'd13: value = word0_read_data[15:8];
            4'd14: value = word0_read_data[23:16];
            default: value = word0_read_data[31:24];
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            phase_counter <= 0;
            pending <= 0;
            pending_read_not_write <= 1;
            pending_access <= 0;
            pending_address <= 0;
            pending_write_data <= 0;
            pending_execute_pc <= 0;
            write_seen <= 0;
            word0_read_seen <= 0;
            word1_read_seen <= 0;
            word1_write_data <= 0;
            word1_write_pc <= 0;
            word0_read_data <= 0;
            word1_read_data <= 0;
        end else begin
            phase_counter <= phase_counter + 1'b1;

            if (completion_valid && !word1_read_seen &&
                !completion_read_not_write &&
                completion_address[31:2] == STACK_WORD1[31:2]) begin
                // The native stack producer uses a full word. Retain the
                // access check in the completion qualifier so a later narrow
                // unrelated write cannot replace the saved return value.
                if (completion_access == 2'b10) begin
                    word1_write_data <= completion_write_data;
                    word1_write_pc <= completion_execute_pc;
                    write_seen <= 1;
                end
            end

            if (completion_valid && completion_read_not_write &&
                completion_access == 2'b10 &&
                completion_execute_pc == RETURN_PC) begin
                if (completion_address == STACK_WORD0) begin
                    word0_read_data <= read_data;
                    word0_read_seen <= 1;
                end else if (completion_address == STACK_WORD1) begin
                    word1_read_data <= read_data;
                    word1_read_seen <= 1;
                end
            end

            // gba_cpu pulses request at launch and removes it while waiting
            // for done. It may also launch the next transfer on the same edge
            // that completes the previous one, so preserve that replacement
            // request rather than clearing pending unconditionally.
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
