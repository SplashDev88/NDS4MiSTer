// Coarse, CPU-nonblocking transport ring for normalized Nintendo DS geometry
// commands. This is a simulator-first protocol block and is default-off.
//
// There is intentionally no ready signal toward command_valid. Every observed
// normalized command consumes a monotonically increasing fence. If the ring is
// full, the command is dropped and the fence gap plus overflow telemetry makes
// that loss explicit without feeding back into CPU or mailbox behavior.
//
// Packet layout is four little-endian-friendly 64-bit words:
//   word 0 [ 63:  0] = {24'd0, command[7:0], parameter[31:0]}
//   word 1 [127: 64] = timestamp
//   word 2 [191:128] = {epoch[31:0], frame[31:0]}
//   word 3 [255:192] = fence (publish/commit this word last in a DDR version)
//
// IMPORTANT: every hps_* port below is synchronous to clk.  The name describes
// the eventual consumer, not a clock-domain crossing.  A hardware integration
// must put an asynchronous FIFO or an atomic DDR publish/commit protocol
// between this ring and an HPS/fabric clock domain; raw cross-domain wiring is
// intentionally outside this simulator-first block.
module nds_gx_command_packet_ring #(
    parameter bit ENABLE = 0,
    parameter integer ENTRY_COUNT = 16
) (
    input  logic         clk,
    input  logic         reset,

    input  logic         epoch_advance,
    input  logic         frame_advance,
    input  logic         command_valid,
    input  logic [63:0]  command_timestamp,
    input  logic [7:0]   command_id,
    input  logic [31:0]  command_parameter,

    output logic         hps_valid,
    input  logic         hps_dequeue,
    output logic [255:0] hps_packet,
    output logic [63:0]  hps_fence,
    output logic [31:0]  hps_epoch,
    output logic [31:0]  hps_frame,
    output logic [63:0]  hps_timestamp,
    output logic [7:0]   hps_command,
    output logic [31:0]  hps_parameter,

    output logic         hps_ack_valid,
    output logic [63:0]  hps_ack_fence,
    output logic [63:0]  consumer_fence,

    output logic [$clog2(ENTRY_COUNT + 1)-1:0] level,
    output logic         empty,
    output logic         full,
    output logic         overflow,
    output logic         overflow_pulse,
    output logic [31:0]  overflow_count,
    output logic [63:0]  producer_fence,
    output logic [31:0]  current_epoch,
    output logic [31:0]  current_frame,
    output logic         counter_overflow
);
    localparam integer POINTER_WIDTH =
        ENTRY_COUNT <= 2 ? 1 : $clog2(ENTRY_COUNT);
    localparam integer COUNT_WIDTH = $clog2(ENTRY_COUNT + 1);
    localparam logic [COUNT_WIDTH-1:0] ENTRY_COUNT_VALUE =
        COUNT_WIDTH'(ENTRY_COUNT);
    localparam logic [POINTER_WIDTH-1:0] LAST_POINTER =
        POINTER_WIDTH'(ENTRY_COUNT - 1);

    logic [255:0] packet_memory [0:ENTRY_COUNT-1];
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [COUNT_WIDTH-1:0] count;

    wire [31:0] command_epoch =
        epoch_advance && current_epoch != 32'hffffffff
            ? current_epoch + 1'b1 : current_epoch;
    wire [31:0] command_frame =
        frame_advance && current_frame != 32'hffffffff
            ? current_frame + 1'b1 : current_frame;
    wire [63:0] command_fence =
        producer_fence != 64'hffffffffffffffff
            ? producer_fence + 1'b1 : producer_fence;
    wire [255:0] incoming_packet = {
        command_fence,
        command_epoch,
        command_frame,
        command_timestamp,
        24'd0,
        command_id,
        command_parameter
    };

    assign hps_valid = ENABLE && count != 0;
    assign hps_packet =
        hps_valid ? packet_memory[read_pointer] : 256'd0;
    assign hps_fence = hps_packet[255:192];
    assign hps_epoch = hps_packet[191:160];
    assign hps_frame = hps_packet[159:128];
    assign hps_timestamp = hps_packet[127:64];
    assign hps_command = hps_packet[39:32];
    assign hps_parameter = hps_packet[31:0];
    assign level = ENABLE ? count : '0;
    assign empty = !ENABLE || count == 0;
    assign full = ENABLE && count == ENTRY_COUNT_VALUE;

    wire dequeue = hps_valid && hps_dequeue;
    wire space_available = !full || dequeue;
    wire enqueue = ENABLE && command_valid && space_available;
    wire drop = ENABLE && command_valid && !space_available;

    initial begin
        if (ENTRY_COUNT < 2)
            $error("nds_gx_command_packet_ring ENTRY_COUNT must be >= 2");
    end

    always_ff @(posedge clk) begin
        if (reset || !ENABLE) begin
            write_pointer <= 0;
            read_pointer <= 0;
            count <= 0;
            hps_ack_valid <= 0;
            hps_ack_fence <= 0;
            consumer_fence <= 0;
            overflow <= 0;
            overflow_pulse <= 0;
            overflow_count <= 0;
            producer_fence <= 0;
            current_epoch <= 0;
            current_frame <= 0;
            counter_overflow <= 0;
        end else begin
            hps_ack_valid <= 0;
            overflow_pulse <= 0;

            if (epoch_advance) begin
                if (current_epoch == 32'hffffffff)
                    counter_overflow <= 1;
                else
                    current_epoch <= current_epoch + 1'b1;
            end
            if (frame_advance) begin
                if (current_frame == 32'hffffffff)
                    counter_overflow <= 1;
                else
                    current_frame <= current_frame + 1'b1;
            end

            if (command_valid) begin
                if (producer_fence == 64'hffffffffffffffff)
                    counter_overflow <= 1;
                else
                    producer_fence <= producer_fence + 1'b1;
            end

            if (enqueue) begin
                packet_memory[write_pointer] <= incoming_packet;
                if (write_pointer == LAST_POINTER)
                    write_pointer <= 0;
                else
                    write_pointer <= write_pointer + 1'b1;
            end

            if (dequeue) begin
                hps_ack_valid <= 1;
                hps_ack_fence <= hps_fence;
                consumer_fence <= hps_fence;
                if (read_pointer == LAST_POINTER)
                    read_pointer <= 0;
                else
                    read_pointer <= read_pointer + 1'b1;
            end

            case ({enqueue, dequeue})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (drop) begin
                overflow <= 1;
                overflow_pulse <= 1;
                if (overflow_count != 32'hffffffff)
                    overflow_count <= overflow_count + 1'b1;
                else
                    counter_overflow <= 1;
            end
        end
    end
endmodule
