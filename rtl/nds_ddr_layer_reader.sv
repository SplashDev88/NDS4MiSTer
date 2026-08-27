module nds_ddr_layer_reader #(
    // Layer records are five adjacent DDR64 words.  Reading one record per
    // Avalon command spends enough command/grant cycles that a 512-pixel
    // line cannot be refilled inside the production raster's scanline
    // budget once CPU and sound share the port.  Keep a complete burst in a
    // small FIFO so responses remain unbackpressured while the record sink
    // is allowed to stall.
    // Five DDR64 beats make one record.  MiSTer's established f2sdram users
    // bound requests at 128 beats; 16 records keeps this reader at 80 beats.
    parameter integer RECORDS_PER_BURST = 16
) (
    input logic clk,input logic reset_n,
    input logic start,input logic [28:0] base_addr,input logic [19:0] record_count,
    output logic busy,output logic done,
    output logic [7:0] ddram_burstcnt,output logic [28:0] ddram_addr,
    input logic ddram_busy,input logic [63:0] ddram_dout,input logic ddram_dout_ready,
    output logic ddram_rd,
    output logic record_valid,input logic record_ready,output logic [319:0] record_data
);
    typedef enum logic [1:0] {IDLE,ISSUE,RECEIVE,DRAIN} state_t;
    state_t state;
    logic [2:0] beat_index;
    logic [19:0] remaining;
    localparam integer FIFO_ADDR_WIDTH = RECORDS_PER_BURST <= 1
        ? 1 : $clog2(RECORDS_PER_BURST);
    localparam integer FIFO_COUNT_WIDTH = $clog2(RECORDS_PER_BURST + 1);
    logic [319:0] assembly;
    logic [319:0] record_fifo [0:RECORDS_PER_BURST-1];
    logic [FIFO_ADDR_WIDTH-1:0] fifo_read_pointer;
    logic [FIFO_ADDR_WIDTH-1:0] fifo_write_pointer;
    logic [FIFO_COUNT_WIDTH-1:0] fifo_count;
    logic [7:0] current_burst_records;
    logic [7:0] current_burst_beats;
    wire push_record = state == RECEIVE && ddram_dout_ready &&
        beat_index == 3'd4;
    wire pop_record = record_valid && record_ready;
    wire load_record = (!record_valid || pop_record) && fifo_count != 0;

    function automatic logic [7:0] burst_records_for(
        input logic [19:0] records_remaining
    );
        begin
            if (records_remaining > RECORDS_PER_BURST)
                burst_records_for = 8'(RECORDS_PER_BURST);
            else
                burst_records_for = records_remaining[7:0];
        end
    endfunction

    initial begin
        if (RECORDS_PER_BURST < 1 || RECORDS_PER_BURST > 16 ||
            (RECORDS_PER_BURST & (RECORDS_PER_BURST - 1)) != 0)
            $fatal(1,
                "RECORDS_PER_BURST must be a power of two in 1..16");
    end

    assign ddram_burstcnt=current_burst_beats;
    assign busy=state!=IDLE;
    assign ddram_rd=state==ISSUE;
    always_ff @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            state<=IDLE;done<=0;ddram_addr<=0;beat_index<=0;
            remaining<=0;assembly<=0;fifo_read_pointer<=0;
            fifo_write_pointer<=0;fifo_count<=0;
            current_burst_records<=0;current_burst_beats<=0;
            record_valid<=0;record_data<=0;
        end else begin
            done<=0;

            if(push_record)begin
                record_fifo[fifo_write_pointer]<=
                    {ddram_dout,assembly[255:0]};
                fifo_write_pointer<=fifo_write_pointer+1'b1;
            end
            if(load_record)begin
                // A clocked FIFO read keeps the 320-bit-wide queue in M10K
                // storage instead of expanding it into combinational ALMs.
                record_data<=record_fifo[fifo_read_pointer];
                fifo_read_pointer<=fifo_read_pointer+1'b1;
                record_valid<=1'b1;
            end else if(pop_record)
                record_valid<=1'b0;
            case({push_record,load_record})
                2'b10:fifo_count<=fifo_count+1'b1;
                2'b01:fifo_count<=fifo_count-1'b1;
                default:fifo_count<=fifo_count;
            endcase

`ifndef SYNTHESIS
            if(push_record && fifo_count==RECORDS_PER_BURST &&
               !load_record)
                $fatal(1,"layer-reader record FIFO overflow");
`endif

            case(state)
                IDLE: if(start)begin
                    ddram_addr<=base_addr;remaining<=record_count;
                    fifo_read_pointer<=0;fifo_write_pointer<=0;fifo_count<=0;
                    record_valid<=0;
                    if(record_count==0)done<=1;
                    else begin
                        current_burst_records<=
                            burst_records_for(record_count);
                        current_burst_beats<=
                            burst_records_for(record_count)*5;
                        state<=ISSUE;
                    end
                end
                ISSUE: if(!ddram_busy)begin
                    beat_index<=0;assembly<=0;state<=RECEIVE;
                end
                RECEIVE: if(ddram_dout_ready)begin
                    assembly[beat_index*64 +: 64]<=ddram_dout;
                    if(beat_index==4)begin
                        beat_index<=0;
                        if(current_burst_beats==5)begin
                            remaining<=remaining-current_burst_records;
                            ddram_addr<=ddram_addr+
                                current_burst_records*5;
                            state<=DRAIN;
                        end
                        current_burst_beats<=current_burst_beats-5;
                    end else beat_index<=beat_index+1'b1;
                end
                DRAIN: if(fifo_count==0&&!record_valid)begin
                    if(remaining==0)begin done<=1;state<=IDLE;end
                    else begin
                        current_burst_records<=
                            burst_records_for(remaining);
                        current_burst_beats<=
                            burst_records_for(remaining)*5;
                        state<=ISSUE;
                    end
                end
            endcase
        end
    end
endmodule
