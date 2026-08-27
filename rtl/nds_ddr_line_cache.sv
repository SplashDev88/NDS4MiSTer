module nds_ddr_line_cache #(
    parameter integer LINE_PIXELS=512,
    parameter integer FRAME_LINES=192,
    parameter integer RECORDS_PER_BURST=16
) (
    input logic clk,input logic reset_n,input logic start,
    input logic [28:0] base_addr,input logic [31:0] sequence_base,
    output logic busy,output logic frame_fetched,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,
    input logic acquire,input logic acquire_bank,input logic [31:0] acquire_sequence,
    output logic acquire_ready,
    input logic read_enable,input logic read_bank,input logic [8:0] read_addr,
    output logic read_valid,output logic [319:0] read_data,
    input logic release_valid,input logic release_bank,
    output logic [1:0] bank_free
);
    typedef enum logic [2:0] {IDLE,WAIT_BANK,START_READ,READ_LINE,PUBLISH_LINE} state_t;
    state_t state;
    logic reader_start,reader_busy,reader_done,record_valid,record_ready;
    logic [319:0] record_data;
    logic [8:0] fill_addr;
    logic [8:0] line_index;
    logic [28:0] line_address;
    logic publish;
    localparam logic [19:0] LINE_RECORD_COUNT=LINE_PIXELS;

    assign busy=state!=IDLE;
    assign reader_start=state==START_READ;
    assign publish=state==PUBLISH_LINE;

    nds_ddr_layer_reader #(.RECORDS_PER_BURST(RECORDS_PER_BURST)) reader(
        .clk(clk),.reset_n(reset_n),.start(reader_start),.base_addr(line_address),
        .record_count(LINE_RECORD_COUNT),.busy(reader_busy),.done(reader_done),
        .ddram_burstcnt(ddram_burstcnt),.ddram_addr(ddram_addr),
        .ddram_busy(ddram_busy),.ddram_dout(ddram_dout),
        .ddram_dout_ready(ddram_dout_ready),.ddram_rd(ddram_rd),
        .record_valid(record_valid),.record_ready(record_ready),.record_data(record_data)
    );

    nds_dual_line_store store(
        .clk(clk),.reset_n(reset_n),.bank_free(bank_free),
        .write_valid(record_valid),.write_ready(record_ready),.write_bank(line_index[0]),
        .write_addr(fill_addr),.write_data(record_data),
        .publish(publish),.publish_bank(line_index[0]),
        .publish_sequence(sequence_base+line_index),
        .acquire(acquire),.acquire_bank(acquire_bank),.acquire_sequence(acquire_sequence),
        .acquire_ready(acquire_ready),.read_enable(read_enable),.read_bank(read_bank),
        .read_addr(read_addr),.read_valid(read_valid),.read_data(read_data),
        .release_valid(release_valid),.release_bank(release_bank)
    );

    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            state<=IDLE;frame_fetched<=0;fill_addr<=0;line_index<=0;line_address<=0;
        end else begin
            frame_fetched<=0;
            if(record_valid&&record_ready)fill_addr<=fill_addr+1'b1;
            case(state)
                IDLE: if(start)begin
                    line_index<=0;line_address<=base_addr;fill_addr<=0;state<=WAIT_BANK;
                end
                WAIT_BANK: if(bank_free[line_index[0]])begin fill_addr<=0;state<=START_READ;end
                START_READ: state<=READ_LINE;
                READ_LINE: if(reader_done)state<=PUBLISH_LINE;
                PUBLISH_LINE: begin
                    if(line_index==FRAME_LINES-1)begin frame_fetched<=1;state<=IDLE;end
                    else begin
                        line_index<=line_index+1'b1;
                        line_address<=line_address+LINE_PIXELS*5;
                        state<=WAIT_BANK;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
