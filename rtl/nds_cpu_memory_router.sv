module nds_cpu_memory_router #(
    parameter logic [28:0] MAIN_RAM_BASE_WORD = 29'h05820000,
    parameter logic [28:0] SHARED_WRAM_BASE_WORD = 29'h05802000,
    parameter logic [28:0] ARM7_WRAM_BASE_WORD = 29'h05804000,
    // DMA is a separate ARM9 bus master and cannot see CPU ITCM or DTCM.
    // Default off keeps every existing CPU-only instantiation unchanged.
    parameter bit DMA_TCM_BYPASS_ENABLE = 0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        request,
    input  logic        cpu_is_arm9,
    input  logic        request_is_dma,
    input  logic [1:0]  wramcnt,
    input  logic [31:0] arm9_dtcm_region,
    input  logic        arm9_dtcm_enable,
    input  logic        arm9_dtcm_seed_valid,
    input  logic [31:0] arm9_dtcm_irq_vector,
    input  logic [31:0] address,
    input  logic        read_not_write,
    input  logic [1:0]  access,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,
    output logic        done,

    output logic        oracle_request,
    output logic [31:0] oracle_address,
    output logic        oracle_read_not_write,
    output logic [1:0]  oracle_access,
    output logic [31:0] oracle_write_data,
    input  logic [31:0] oracle_read_data,
    input  logic        oracle_done,

    output logic        ddram_read,
    output logic        ddram_write,
    output logic [7:0]  ddram_burst_count,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_write_data,
    output logic [7:0]  ddram_byte_enable,
    input  logic        ddram_busy,
    input  logic [63:0] ddram_read_data,
    input  logic        ddram_read_data_ready
);
    logic main_ram_hit;
    logic zero_fill_hit;
    logic shared_wram_hit;
    logic arm7_wram_hit;
    logic arm7_bios_hit;
    logic arm9_itcm_hit;
    logic arm9_dtcm_hit;
    logic local_ram_hit;
    logic [31:0] main_ram_address;
    logic [31:0] shared_wram_address;
    logic [31:0] arm7_wram_address;
    logic [31:0] main_ram_read_data;
    logic [31:0] shared_wram_read_data;
    logic [31:0] arm7_wram_read_data;
    logic [31:0] arm7_bios_read_data;
    logic [31:0] arm9_itcm_read_data;
    logic [31:0] arm9_dtcm_read_data;
    logic main_ram_done;
    logic shared_wram_done;
    logic arm7_wram_done;
    logic arm7_bios_done;
    logic arm9_itcm_done;
    logic arm9_dtcm_done;
    logic main_rd, main_we, shared_rd, shared_we, arm7_rd, arm7_we;
    logic [7:0] main_burst, main_be, shared_burst, shared_be;
    logic [7:0] arm7_burst, arm7_be;
    logic [28:0] main_addr, shared_addr, arm7_addr;
    logic [63:0] main_din, shared_din, arm7_din;
    wire dma_tcm_bypass = DMA_TCM_BYPASS_ENABLE && request_is_dma;

    assign arm7_bios_hit = !cpu_is_arm9 && address < 32'h00004000;
    // Direct-boot CP15 defaults provide a 32 MiB ITCM aperture mirrored over
    // 32 KiB. DTCM is a 16 KiB CPU-private memory whose base is relocatable
    // through CP15 c9,c1,0 and whose enable is CP15 control bit 16.
    assign arm9_itcm_hit = cpu_is_arm9 && !dma_tcm_bypass &&
                           address < 32'h02000000;
    assign arm9_dtcm_hit = cpu_is_arm9 && !dma_tcm_bypass &&
                           arm9_dtcm_enable &&
                           address >= {arm9_dtcm_region[31:12], 12'h000} &&
                           address < ({arm9_dtcm_region[31:12], 12'h000} +
                                      32'h00004000);
    // DTCM takes precedence over the AHB/main-RAM aperture when firmware
    // relocates it into 0x02xxxxxx, as Nintendo DS software routinely does.
    assign main_ram_hit = address[31:24] == 8'h02 && !arm9_dtcm_hit;
    // WRAMCNT dynamically partitions the 32 KiB shared WRAM. ARM7's
    // 0x03800000 aperture always selects its private 64 KiB WRAM.
    assign arm7_wram_hit = !cpu_is_arm9 && address[31:24] == 8'h03 &&
                           (address[23] || wramcnt == 2'd0);
    assign shared_wram_hit = address[31:24] == 8'h03 &&
        !arm7_wram_hit &&
        !arm9_dtcm_hit &&
        ((cpu_is_arm9 && wramcnt != 2'd3) ||
         (!cpu_is_arm9 && wramcnt != 2'd0));
    assign local_ram_hit = main_ram_hit || shared_wram_hit || arm7_wram_hit ||
                           arm9_itcm_hit || arm9_dtcm_hit;
    // melonDS returns zero for this unmapped upper cartridge/GBA aperture.
    // Direct-boot software probes it in long sequential loops, so completing
    // locally avoids a side-effect-free HPS mailbox round trip per access.
    assign zero_fill_hit = address[31:24] >= 8'h0b &&
                           address[31:24] <= 8'h0f ||
                           (cpu_is_arm9 && address[31:24] == 8'h03 &&
                            wramcnt == 2'd3);
    assign main_ram_address = {10'h0, address[21:0]};
    always_comb begin
        shared_wram_address = 32'h0;
        if (cpu_is_arm9) begin
            case (wramcnt)
                2'd0: shared_wram_address = {17'h0, address[14:0]};
                2'd1: shared_wram_address = 32'h00004000 |
                                               {18'h0, address[13:0]};
                default: shared_wram_address = {18'h0, address[13:0]};
            endcase
        end else begin
            case (wramcnt)
                2'd1: shared_wram_address = {18'h0, address[13:0]};
                2'd2: shared_wram_address = 32'h00004000 |
                                               {18'h0, address[13:0]};
                default: shared_wram_address = {17'h0, address[14:0]};
            endcase
        end
        arm7_wram_address = {16'h0, address[15:0]};
    end

    assign oracle_request = request && !local_ram_hit && !zero_fill_hit &&
                            !arm7_bios_hit;
    assign oracle_address = address;
    assign oracle_read_not_write = read_not_write;
    assign oracle_access = access;
    assign oracle_write_data = write_data;

    assign read_data = main_ram_hit ? main_ram_read_data :
                       shared_wram_hit ? shared_wram_read_data :
                       arm7_wram_hit ? arm7_wram_read_data :
                       arm9_itcm_hit ? arm9_itcm_read_data :
                       arm9_dtcm_hit ? arm9_dtcm_read_data :
                       arm7_bios_hit ? arm7_bios_read_data :
                       (zero_fill_hit ? 32'h00000000 : oracle_read_data);
    assign done = main_ram_hit ? main_ram_done :
                  shared_wram_hit ? shared_wram_done :
                  arm7_wram_hit ? arm7_wram_done :
                  arm9_itcm_hit ? arm9_itcm_done :
                  arm9_dtcm_hit ? arm9_dtcm_done :
                  arm7_bios_hit ? arm7_bios_done :
                  (zero_fill_hit ? request : oracle_done);
    assign ddram_read = main_ram_hit ? main_rd :
                        shared_wram_hit ? shared_rd : arm7_rd;
    assign ddram_write = main_ram_hit ? main_we :
                         shared_wram_hit ? shared_we : arm7_we;
    assign ddram_burst_count = main_ram_hit ? main_burst :
                               shared_wram_hit ? shared_burst : arm7_burst;
    assign ddram_address = main_ram_hit ? main_addr :
                           shared_wram_hit ? shared_addr : arm7_addr;
    assign ddram_write_data = main_ram_hit ? main_din :
                              shared_wram_hit ? shared_din : arm7_din;
    assign ddram_byte_enable = main_ram_hit ? main_be :
                               shared_wram_hit ? shared_be : arm7_be;

    nds_cpu_ddram #(.BASE_WORD(MAIN_RAM_BASE_WORD)) main_ram (
        .clk(clk), .reset(reset), .request(request && main_ram_hit),
        .address(main_ram_address), .read_not_write(read_not_write),
        .access(access), .write_data(write_data),
        .read_data(main_ram_read_data), .done(main_ram_done),
        .ddram_read(main_rd), .ddram_write(main_we),
        .ddram_burst_count(main_burst), .ddram_address(main_addr),
        .ddram_write_data(main_din), .ddram_byte_enable(main_be),
        .ddram_busy(ddram_busy || !main_ram_hit),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready && main_ram_hit)
    );
    nds_cpu_ddram #(.BASE_WORD(SHARED_WRAM_BASE_WORD)) shared_wram (
        .clk(clk), .reset(reset), .request(request && shared_wram_hit),
        .address(shared_wram_address), .read_not_write(read_not_write),
        .access(access), .write_data(write_data),
        .read_data(shared_wram_read_data), .done(shared_wram_done),
        .ddram_read(shared_rd), .ddram_write(shared_we),
        .ddram_burst_count(shared_burst), .ddram_address(shared_addr),
        .ddram_write_data(shared_din), .ddram_byte_enable(shared_be),
        .ddram_busy(ddram_busy || !shared_wram_hit),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready && shared_wram_hit)
    );
    nds_cpu_ddram #(.BASE_WORD(ARM7_WRAM_BASE_WORD)) arm7_wram (
        .clk(clk), .reset(reset), .request(request && arm7_wram_hit),
        .address(arm7_wram_address), .read_not_write(read_not_write),
        .access(access), .write_data(write_data),
        .read_data(arm7_wram_read_data), .done(arm7_wram_done),
        .ddram_read(arm7_rd), .ddram_write(arm7_we),
        .ddram_burst_count(arm7_burst), .ddram_address(arm7_addr),
        .ddram_write_data(arm7_din), .ddram_byte_enable(arm7_be),
        .ddram_busy(ddram_busy || !arm7_wram_hit),
        .ddram_read_data(ddram_read_data),
        .ddram_read_data_ready(ddram_read_data_ready && arm7_wram_hit)
    );
    nds_arm7_bios_rom arm7_bios (
        .request(request && arm7_bios_hit),
        .address(address), .access(access),
        .read_data(arm7_bios_read_data), .done(arm7_bios_done)
    );
    nds_cpu_tcm #(.ADDRESS_BITS(15)) arm9_itcm (
        .clk(clk), .reset(reset), .seed_valid(1'b0), .seed_data(32'd0),
        .request(request && arm9_itcm_hit),
        .address(address), .read_not_write(read_not_write), .access(access),
        .write_data(write_data), .read_data(arm9_itcm_read_data),
        .done(arm9_itcm_done)
    );
    nds_cpu_tcm #(.ADDRESS_BITS(14)) arm9_dtcm (
        .clk(clk), .reset(reset), .seed_valid(arm9_dtcm_seed_valid),
        .seed_data(arm9_dtcm_irq_vector),
        .request(request && arm9_dtcm_hit),
        .address(address), .read_not_write(read_not_write), .access(access),
        .write_data(write_data), .read_data(arm9_dtcm_read_data),
        .done(arm9_dtcm_done)
    );
endmodule
