// Candidate-only configuration-lifetime supervisor for the private FPGA sound
// integration.
//
// This block deliberately has no reset input in its sequential state.  Its
// configuration-lifetime state is initialized by the FPGA bitstream and can
// therefore be consumed exactly once.  core_reset and cpu_runtime_reset are
// observations, not state resets.
//
// The composition receives one short reset at the first stable PLL lock.  Once
// that reset has been released it can never be asserted again, even if the PLL
// or the rest of the core is reset later.  A fresh external epoch may then be
// offered exactly once.  CPUs remain held until the exact epoch is operating
// or until a bounded fail-closed HPS-only decision has been made.
//
// Once FPGA sound has armed, any relevant configuration/session change removes
// ownership combinationally and permanently invalidates the configuration on
// the next clock.  A new RBF load is required to try FPGA ownership again.
//
// This module is intentionally absent from the production MiSTer top and QSF.
`timescale 1ns/1ps
`default_nettype none

module nds_sound_one_shot_supervisor #(
    parameter integer COMPOSITION_RESET_LOCK_CYCLES = 4,
    parameter integer STARTUP_TIMEOUT_CYCLES = 1024
) (
    input  logic        clk,

    input  logic        pll_locked,
    input  logic        request_sound,
    input  logic        core_reset,
    input  logic        cpu_runtime_reset,
    input  logic        standalone_enabled,
    input  logic        boot_valid,
    input  logic        boot_error,
    input  logic [31:0] boot_generation,
    input  logic        transport_quiescent,
    input  logic        external_epoch_fresh,

    output logic        composition_feature_enable,
    output logic        composition_reset,
    output logic        epoch_request_valid,
    input  logic        composition_epoch_request_ready,
    output logic [31:0] epoch_request_generation,
    output logic        epoch_request_fresh,

    input  logic        composition_session_active,
    input  logic        composition_operating,
    input  logic [31:0] composition_active_epoch,
    input  logic        composition_terminal_fault,
    input  logic        ownership_valid,

    output logic        cpu_start_hold,
    output logic        takeover_permitted,
    output logic        sound_data_plane_enable,
    output logic        armed_once,
    output logic        invalidated,
    output logic        hps_fallback,
    output logic [7:0]  status
);
    typedef enum logic [2:0] {
        STATE_FIRST_PLL_LOCK,
        STATE_WAIT_START,
        STATE_OFFER_EPOCH,
        STATE_WAIT_OPERATING,
        STATE_ARMED,
        STATE_HPS_ONLY,
        STATE_INVALIDATED
    } state_t;

    localparam logic [7:0] STATUS_FIRST_PLL_LOCK      = 8'h00;
    localparam logic [7:0] STATUS_WAIT_START          = 8'h01;
    localparam logic [7:0] STATUS_OFFER_EPOCH         = 8'h02;
    localparam logic [7:0] STATUS_WAIT_OPERATING      = 8'h03;
    localparam logic [7:0] STATUS_ARMED               = 8'h10;

    localparam logic [7:0] STATUS_HPS_REQUEST_OFF     = 8'h80;
    localparam logic [7:0] STATUS_HPS_STANDALONE_OFF  = 8'h81;
    localparam logic [7:0] STATUS_HPS_BOOT_ERROR      = 8'h82;
    localparam logic [7:0] STATUS_HPS_BAD_GENERATION  = 8'h83;
    localparam logic [7:0] STATUS_HPS_STARTUP_TIMEOUT = 8'h84;
    localparam logic [7:0] STATUS_HPS_STARTUP_FAULT   = 8'h85;
    localparam logic [7:0] STATUS_HPS_CONTEXT_LOST    = 8'h86;

    localparam logic [7:0] STATUS_INVALID_CORE_RESET  = 8'he0;
    localparam logic [7:0] STATUS_INVALID_CPU_RESET   = 8'he1;
    localparam logic [7:0] STATUS_INVALID_PLL         = 8'he2;
    localparam logic [7:0] STATUS_INVALID_STANDALONE  = 8'he3;
    localparam logic [7:0] STATUS_INVALID_REQUEST     = 8'he4;
    localparam logic [7:0] STATUS_INVALID_BOOT_VALID  = 8'he5;
    localparam logic [7:0] STATUS_INVALID_BOOT_ERROR  = 8'he6;
    localparam logic [7:0] STATUS_INVALID_GENERATION  = 8'he7;
    localparam logic [7:0] STATUS_INVALID_QUIESCENCE  = 8'he8;
    localparam logic [7:0] STATUS_INVALID_COMPOSITION = 8'he9;
    localparam logic [7:0] STATUS_INVALID_EPOCH       = 8'hea;
    localparam logic [7:0] STATUS_INVALID_OWNERSHIP   = 8'heb;

    state_t state;
    logic [31:0] pll_lock_count;
    logic [31:0] startup_count;
    logic        composition_reset_released;
    logic        decision_complete;
    logic        epoch_offer_valid;
    logic        epoch_offer_spent;
    logic [31:0] retained_epoch;
    logic [7:0]  retained_status;

    wire boot_generation_known =
        (^boot_generation !== 1'bx);
    wire boot_generation_usable =
        boot_generation_known &&
        boot_generation != 32'd0;

    wire startup_context_exact =
        (pll_locked          === 1'b1) &&
        (request_sound       === 1'b1) &&
        (core_reset          === 1'b0) &&
        (cpu_runtime_reset   === 1'b0) &&
        (standalone_enabled  === 1'b1) &&
        (boot_valid          === 1'b1) &&
        (boot_error          === 1'b0) &&
        (transport_quiescent === 1'b1) &&
        boot_generation_usable;

    wire startup_offer_exact =
        startup_context_exact &&
        (external_epoch_fresh === 1'b1);

    wire retained_start_context_exact =
        startup_context_exact &&
        (boot_generation === retained_epoch);

    wire composition_operating_exact =
        (composition_session_active === 1'b1) &&
        (composition_operating      === 1'b1) &&
        (composition_active_epoch   === retained_epoch) &&
        (composition_terminal_fault === 1'b0) &&
        (ownership_valid            === 1'b1);

    wire armed_health_exact =
        retained_start_context_exact &&
        composition_operating_exact;

    wire startup_timeout_hit =
        startup_count >= STARTUP_TIMEOUT_CYCLES - 1;

    wire state_attempting =
        state == STATE_WAIT_START ||
        state == STATE_OFFER_EPOCH ||
        state == STATE_WAIT_OPERATING;

    // Every ownership output is a definite zero unless every relevant
    // predicate is exactly one.  Unknown input state can never select FPGA
    // sound.
    assign takeover_permitted =
        (state === STATE_ARMED) &&
        (armed_health_exact === 1'b1) &&
        (invalidated === 1'b0);
    assign sound_data_plane_enable =
        takeover_permitted === 1'b1;
    assign hps_fallback =
        takeover_permitted !== 1'b1;

    // Keep the composition enabled from the startup attempt through ARMED
    // without consulting ownership_valid/takeover_permitted.  In the real
    // top-level ownership_valid is derived from the composition's health, so
    // feeding takeover back into feature_enable would form a combinational
    // loop exactly when STATE_ARMED is entered.  The final audio mux remains
    // fail closed through takeover_permitted, and any lost context is observed
    // combinationally there and permanently invalidated on the next clock.
    assign composition_feature_enable =
        ((((state_attempting || state === STATE_ARMED) &&
           retained_start_context_exact &&
           composition_terminal_fault === 1'b0) &&
          invalidated === 1'b0)) === 1'b1;

    assign composition_reset =
        composition_reset_released !== 1'b1;

    assign epoch_request_valid =
        epoch_offer_valid === 1'b1;
    assign epoch_request_generation =
        epoch_request_valid ? retained_epoch : 32'd0;
    assign epoch_request_fresh =
        epoch_request_valid &&
        (epoch_offer_spent === 1'b1);

    assign cpu_start_hold =
        decision_complete !== 1'b1;
    assign status = retained_status;

    initial begin
        if (COMPOSITION_RESET_LOCK_CYCLES < 1)
            $fatal(1,
                "COMPOSITION_RESET_LOCK_CYCLES must be at least one");
        if (STARTUP_TIMEOUT_CYCLES < 1)
            $fatal(1, "STARTUP_TIMEOUT_CYCLES must be at least one");

        state = STATE_FIRST_PLL_LOCK;
        pll_lock_count = 32'd0;
        startup_count = 32'd0;
        composition_reset_released = 1'b0;
        decision_complete = 1'b0;
        epoch_offer_valid = 1'b0;
        epoch_offer_spent = 1'b0;
        retained_epoch = 32'd0;
        retained_status = STATUS_FIRST_PLL_LOCK;
        armed_once = 1'b0;
        invalidated = 1'b0;
    end

    always_ff @(posedge clk) begin
        // This is the only assignment that can release composition_reset.
        // No branch, including PLL loss and either observed reset, clears it.
        if (!composition_reset_released) begin
            if (pll_locked === 1'b1) begin
                if (pll_lock_count >=
                    COMPOSITION_RESET_LOCK_CYCLES - 1) begin
                    composition_reset_released <= 1'b1;
                end else begin
                    pll_lock_count <= pll_lock_count + 1'b1;
                end
            end else begin
                pll_lock_count <= 32'd0;
            end
        end

        case (state)
            STATE_FIRST_PLL_LOCK: begin
                if (composition_reset_released) begin
                    state <= STATE_WAIT_START;
                    startup_count <= 32'd0;
                    retained_status <= STATUS_WAIT_START;
                end
            end

            STATE_WAIT_START: begin
                startup_count <= startup_count + 1'b1;

                if (startup_timeout_hit) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    // The boot reader deliberately reports REJECTED while
                    // the HPS is still publishing a replacement descriptor,
                    // then retries.  Treat that transient as retryable and
                    // classify it as a boot error only if it persists for the
                    // entire bounded startup window.
                    if (boot_error === 1'b1)
                        retained_status <= STATUS_HPS_BOOT_ERROR;
                    else
                        retained_status <= STATUS_HPS_STARTUP_TIMEOUT;
                end else if (request_sound === 1'b0 &&
                             core_reset === 1'b0 &&
                             cpu_runtime_reset === 1'b0) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_REQUEST_OFF;
                end else if (standalone_enabled === 1'b0 &&
                             core_reset === 1'b0 &&
                             cpu_runtime_reset === 1'b0) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_STANDALONE_OFF;
                end else if (boot_valid === 1'b1 &&
                             !boot_generation_usable) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_BAD_GENERATION;
                end else if (startup_offer_exact) begin
                    retained_epoch <= boot_generation;
                    epoch_offer_valid <= 1'b1;
                    epoch_offer_spent <= 1'b1;
                    state <= STATE_OFFER_EPOCH;
                    retained_status <= STATUS_OFFER_EPOCH;
                end
            end

            STATE_OFFER_EPOCH: begin
                startup_count <= startup_count + 1'b1;

                if (startup_timeout_hit) begin
                    epoch_offer_valid <= 1'b0;
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_STARTUP_TIMEOUT;
                end else if (composition_terminal_fault !== 1'b0) begin
                    epoch_offer_valid <= 1'b0;
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_STARTUP_FAULT;
                end else if (!retained_start_context_exact) begin
                    epoch_offer_valid <= 1'b0;
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_CONTEXT_LOST;
                end else if ((epoch_offer_valid === 1'b1) &&
                             (composition_epoch_request_ready === 1'b1)) begin
                    epoch_offer_valid <= 1'b0;
                    state <= STATE_WAIT_OPERATING;
                    retained_status <= STATUS_WAIT_OPERATING;
                end
            end

            STATE_WAIT_OPERATING: begin
                startup_count <= startup_count + 1'b1;

                if (startup_timeout_hit) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_STARTUP_TIMEOUT;
                end else if (composition_terminal_fault !== 1'b0) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_STARTUP_FAULT;
                end else if (!retained_start_context_exact) begin
                    state <= STATE_HPS_ONLY;
                    decision_complete <= 1'b1;
                    retained_status <= STATUS_HPS_CONTEXT_LOST;
                end else if (composition_operating_exact) begin
                    state <= STATE_ARMED;
                    decision_complete <= 1'b1;
                    armed_once <= 1'b1;
                    retained_status <= STATUS_ARMED;
                end
            end

            STATE_ARMED: begin
                // takeover_permitted has already fallen combinationally when
                // any one of these exact predicates is lost.
                if (core_reset !== 1'b0) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_CORE_RESET;
                end else if (cpu_runtime_reset !== 1'b0) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_CPU_RESET;
                end else if (pll_locked !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_PLL;
                end else if (standalone_enabled !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_STANDALONE;
                end else if (request_sound !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_REQUEST;
                end else if (boot_valid !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_BOOT_VALID;
                end else if (boot_error !== 1'b0) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_BOOT_ERROR;
                end else if (boot_generation !== retained_epoch) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_GENERATION;
                end else if (transport_quiescent !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_QUIESCENCE;
                end else if (composition_terminal_fault !== 1'b0 ||
                             composition_session_active !== 1'b1 ||
                             composition_operating !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_COMPOSITION;
                end else if (composition_active_epoch !== retained_epoch) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_EPOCH;
                end else if (ownership_valid !== 1'b1) begin
                    state <= STATE_INVALIDATED;
                    invalidated <= 1'b1;
                    retained_status <= STATUS_INVALID_OWNERSHIP;
                end
            end

            STATE_HPS_ONLY: begin
                epoch_offer_valid <= 1'b0;
            end

            STATE_INVALIDATED: begin
                epoch_offer_valid <= 1'b0;
                invalidated <= 1'b1;
            end

            default: begin
                epoch_offer_valid <= 1'b0;
                state <= STATE_HPS_ONLY;
                decision_complete <= 1'b1;
                retained_status <= STATUS_HPS_STARTUP_FAULT;
            end
        endcase
    end
endmodule

`default_nettype wire
