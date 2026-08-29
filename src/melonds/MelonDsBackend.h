#pragma once

#include "core/EmulatorBackend.h"
#include "melonds/HeadlessSaveManager.h"

#include <memory>
#include <array>
#include <fstream>
#include <functional>
#include <string>
#include <cstddef>
#include <cstdint>
#include <vector>
#include "NDS4MiSTer_2DTrace.h"

namespace melonDS {
class NDS;
struct ExternalIRQTransition;
}

namespace nds4mister {

struct DirectBootImage {
    std::vector<std::uint8_t> main_ram;
    std::vector<std::uint8_t> shared_wram;
    std::vector<std::uint8_t> arm7_wram;
    std::uint8_t wramcnt = 3;
    std::uint32_t arm9_entry = 0;
    std::uint32_t arm7_entry = 0;
    std::uint32_t arm9_dtcm_irq_vector = 0;
};

struct FPGAAudioOffloadTelemetry {
    std::uint64_t mix_callbacks = 0;
    std::uint64_t hps_render_callbacks = 0;
    std::uint64_t channel_advance_callbacks = 0;
    std::uint64_t capture_advance_callbacks = 0;
};

struct ExternalTimeWindowProfile {
    std::uint64_t closure_count = 0;
    std::uint64_t finite_bound_limited_count = 0;
    std::uint64_t no_event_count = 0;
    std::array<std::uint64_t, 32> limiting_event_count{};
    std::array<std::uint64_t, 32> granted_cycles{};
    std::size_t event_count = 0;
};

struct IRQSetCapture {
    std::uint32_t arm9_mask = 0;
    std::uint32_t arm7_mask = 0;
};

struct ExternalTimeWindow {
    std::uint64_t processedThrough = 0;
    std::uint64_t runSafeThrough = 0;
    std::uint32_t lastEventSequence = 0;
    std::uint32_t epoch = 0;
    std::uint32_t grantSequence = 0;
    std::uint32_t replacesGrantSequence = 0;
    std::uint64_t verifiedProducerFence = 0;
    bool replacesBlockingMMIO = false;
    std::uint32_t barrierSourceSequence = 0;
    std::uint32_t barrierSequence = 0;
    std::uint64_t barrierTimestamp = 0;
};

struct ExternalTimeWindowReplacement {
    std::uint32_t epoch = 0;
    std::uint32_t grantSequence = 0;
    std::uint32_t replacesGrantSequence = 0;
    std::uint64_t verifiedProducerFence = 0;
};

struct ExternalBlockingMMIORequest {
    std::uint32_t epoch = 0;
    std::uint32_t activeGrantSequence = 0;
    std::uint64_t activeProcessedThrough = 0;
    std::uint64_t activeRunSafeThrough = 0;
    std::uint32_t activeEventSequence = 0;
    std::uint32_t sourceSequence = 0;
    std::uint32_t barrierSequence = 0;
    std::uint64_t verifiedProducerFence = 0;
    std::uint64_t arm9NormalizedTimestamp = 0;
    std::uint64_t arm7NormalizedTimestamp = 0;
    bool arm9 = false;
    bool write = false;
    std::uint32_t access = 0;
    std::uint32_t address = 0;
    std::uint32_t writeData = 0;
    std::uint32_t executionPC = 0;
};

enum class ExternalLCDPhaseKind : std::uint8_t {
    ScanlineStart = 0,
    HBlank = 1,
    FrameWrap = 2,
};

struct ExternalLCDPhase {
    std::uint32_t sequence = 0;
    std::uint64_t timestamp = 0;
    ExternalLCDPhaseKind kind = ExternalLCDPhaseKind::ScanlineStart;
    std::uint16_t line = 0;
    std::uint16_t vcount = 0;
    std::uint16_t dispstat9 = 0;
    std::uint16_t dispstat7 = 0;
    std::uint32_t frameSequence = 0;
};

using ExternalBlockingMMIOPreAccess = std::function<bool(
    std::uint64_t barrierTimestamp,
    const ExternalBlockingMMIORequest& request,
    std::string& error)>;

struct ExternalBlockingMMIOOverrideResult {
    bool handled = false;
    std::uint32_t readData = 0;
};

using ExternalBlockingMMIOExactAccess = std::function<bool(
    std::uint64_t barrierTimestamp,
    const ExternalBlockingMMIORequest& request,
    ExternalBlockingMMIOOverrideResult& result,
    std::string& error)>;

struct ExternalIRQTransition {
    std::uint32_t sequence = 0;
    std::uint64_t timestamp = 0;
    bool arm9 = false;
    bool set = false;
    std::uint32_t mask = 0;
};

// Atomic result of one blocking-MMIO replacement transaction.  The read value
// (zero for writes), replacement grant, and complete IRQ suffix are returned
// together only after Begin, the exact claimed access, Finish, and verified
// replacement Close have all succeeded.
struct ExternalBlockingMMIOCompletion {
    std::uint32_t readData = 0;
    ExternalTimeWindow window{};
    std::vector<ExternalIRQTransition> transitions;
};

struct ExternalARM9IFW1CResult {
    std::uint32_t finalIF = 0;
    bool gxFIFOAsserted = false;
};

class MelonDsBackend final : public IEmulatorBackend {
public:
    MelonDsBackend();
    explicit MelonDsBackend(std::string save_root);
    ~MelonDsBackend() override;

    const char* name() const override;
    bool set_2d_trace_path(const std::string& path, std::string& error) override;
    bool load_rom(const std::string& path, std::string& error) override;
    bool run_frame(FrameTimings& timings, std::string& error) override;
    void set_2d_trace_sink(melonDS::NDS4MiSTer::Trace2DSink sink,void* userdata);
    void set_composite_line_sink(melonDS::NDS4MiSTer::CompositeLineSink sink,void* userdata);
    void set_output_line_sink(melonDS::NDS4MiSTer::OutputLineSink sink,void* userdata);
    void set_key_mask(melonDS::u32 mask);
    std::uint64_t advance_external_cycles(bool arm9, std::uint32_t cycles);
    // Let a halted peer CPU stop throttling min(ARM9, ARM7).
    void set_halted_peer_advance(bool enabled);
    // True while melonDS has stalled the system on a full geometry FIFO. Real
    // hardware stalls the ARM9 here; the FPGA CPU has no such signal, so the
    // responder reproduces the backpressure by withholding the mailbox
    // response until this clears.
    bool gx_fifo_stalled() const;
    // Geometry commands silently discarded on a full stall queue.
    std::uint64_t gx_command_drops() const;
    std::uint64_t clip_zero_den() const;
    std::uint64_t clip_interp() const;
    std::uint64_t gx_invalid_cmd() const;
    std::uint64_t gx_executed() const;
    std::string gx_invalid_top() const;
    // True while any ARM9 DMA channel is mid-transfer in GXFIFO mode.
    bool gxfifo_dma_active() const;
    // Coherent whole-system step to the next scheduled event; returns the
    // SysTimestamp reached. Only valid when the external CPU is genuinely
    // waiting on time to pass.
    std::uint64_t advance_system_to_next_event(std::uint64_t bound);
    // 0: no DMA pending, 1: pending DMA drained, -1: bounded drain failed.
    int complete_external_dma(bool arm9);
    bool attach_external_main_ram(std::uint8_t* ram, std::size_t bytes,
                                  std::string& error);
    bool attach_external_wram(std::uint8_t* shared, std::size_t shared_bytes,
                              std::uint8_t* arm7, std::size_t arm7_bytes,
                              std::string& error);
    bool irq_pending(bool arm9) const;
    bool external_cpu_halted(bool arm9);
    int read_audio(std::int16_t* samples, int stereo_frames);
    bool set_fpga_audio_offload(bool enable, std::string& error);
    FPGAAudioOffloadTelemetry fpga_audio_offload_telemetry() const;
    ExternalTimeWindowProfile external_time_window_profile() const;
    // Take and clear every explicit melonDS SetIRQ cause observed since the
    // preceding take. The responder is single-threaded. Repeated causes are
    // intentionally coalesced; IF sets are idempotent until an intervening
    // locally ordered W1C.
    void set_irq_set_capture(bool enable) noexcept;
    IRQSetCapture take_irq_set_capture() noexcept;
    static bool self_test_irq_set_capture();
    // Host/simulator-only proof API.  The build capability and this runtime
    // opt-in are both off by default; no responder or RTL consumes it yet.
    bool external_time_window_capable() const noexcept;
    bool set_external_time_window_enabled(bool enable, std::string& error);
    bool set_external_offline_fast_beta(bool enable, std::string& error);
    bool set_external_lcd_renderer_enabled(bool enable, std::string& error);
    bool apply_external_lcd_phase(
        const ExternalLCDPhase& phase, bool render, bool resync,
        std::string& error);
    bool report_external_time_window_cpu_reached(
        bool arm9, std::uint64_t normalizedTimestamp,
        std::string& error);
    bool advance_and_close_external_time_window(
        std::uint64_t closeThrough,
        std::uint64_t finiteBound,
        std::uint64_t fpgaAuthoritativeEventMask,
        const ExternalTimeWindowReplacement& replacement,
        ExternalTimeWindow& out,
        std::string& error);
    bool close_and_query_external_time_window(
        std::uint64_t finiteBound,
        std::uint64_t fpgaAuthoritativeEventMask,
        const ExternalTimeWindowReplacement& replacement,
        ExternalTimeWindow& out,
        std::string& error);
    // The responder is single-threaded.  Keep the irreversible blocking-MMIO
    // sequence in one non-yielding call so input, posted-ring, scheduler, and
    // publication work cannot interleave between its phases.
    bool execute_external_blocking_mmio_transaction(
        const ExternalBlockingMMIORequest& request,
        std::uint64_t finiteBound,
        std::uint64_t fpgaAuthoritativeEventMask,
        const ExternalTimeWindowReplacement& replacement,
        ExternalBlockingMMIOCompletion& out,
        std::string& error,
        const ExternalBlockingMMIOPreAccess& preAccess = {},
        const ExternalBlockingMMIOExactAccess& exactAccess = {});
    bool apply_external_arm9_if_w1c(
        std::uint32_t sourceSequence,
        std::uint64_t normalizedTimestamp,
        std::uint32_t address,
        std::uint32_t access,
        std::uint32_t writeData,
        std::uint32_t expectedFinalIF,
        bool expectedGXFIFOAsserted,
        ExternalARM9IFW1CResult& out,
        std::string& error);
    std::vector<ExternalIRQTransition>
        take_external_irq_transitions() noexcept;
    std::size_t pending_external_irq_transitions() const noexcept {
        return external_blocking_mmio_barrier_active_
            ? external_blocking_mmio_transition_checkpoint_
            : external_irq_transitions_.size();
    }
    static bool self_test_external_time_window();
    static bool self_test_offline_fast_beta();
    bool bus_read(bool arm9, unsigned access, std::uint32_t address,
                  std::uint32_t& value,
                  std::uint32_t execution_pc = UINT32_MAX);
    bool bus_write(bool arm9, unsigned access, std::uint32_t address,
                   std::uint32_t value,
                   std::uint32_t execution_pc = UINT32_MAX);
    bool export_direct_boot_image(DirectBootImage& image, std::string& error) const;
    bool flush_save(std::string& error);
    bool save_persistence_enabled() const noexcept {
        return !save_root_.empty();
    }
    SavePersistenceStats save_persistence_stats() const;

private:
    void close_trace_2d() noexcept;
    static void irq_set_sink(
        std::uint32_t cpu, std::uint32_t mask, void* userdata) noexcept;
    static bool irq_transition_sink(
        const melonDS::ExternalIRQTransition& transition,
        void* userdata) noexcept;
    bool begin_external_blocking_mmio_barrier(
        const ExternalBlockingMMIORequest& request,
        std::uint64_t& barrierTimestamp,
        std::string& error);
    void rollback_external_blocking_mmio_barrier() noexcept;

    std::string save_root_;
    // Declared before nds_ so reverse member destruction removes the cart and
    // its callback pointer before the per-cart save context is released.
    std::unique_ptr<HeadlessSaveManager> save_session_;
    std::unique_ptr<melonDS::NDS> nds_;
    std::uint8_t* internal_main_ram_ = nullptr;
    std::uint8_t* internal_shared_wram_ = nullptr;
    std::uint8_t* internal_arm7_wram_ = nullptr;
    std::ofstream trace_2d_;
    std::array<std::uint32_t, 2> irq_set_capture_{};
    std::vector<ExternalIRQTransition> external_irq_transitions_;
    bool external_irq_transition_delivery_failed_ = false;
    bool external_blocking_mmio_barrier_active_ = false;
    std::size_t external_blocking_mmio_transition_checkpoint_ = 0;
};

} // namespace nds4mister
