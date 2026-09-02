#pragma once

#include <atomic>
#include <cstdint>
#include <memory>

namespace nds4mister::h3d {
struct Header;
}

namespace nds4mister::crash {

// Process-local counters sampled by the crash recorder. The service publishes
// these only with relaxed atomics on its existing throttled heartbeat (and at
// a low rate while its private replay queue is full), so diagnostics do not
// add work to the renderer or FPGA transport hot paths.
struct FpgaRuntimeTelemetry {
    void reset(std::uint32_t new_session) noexcept;

    std::atomic<std::uint32_t> session {0};
    std::atomic<std::uint32_t> replay_backlog {0};
    std::atomic<std::uint32_t> replay_queue_high_water {0};
    std::atomic<std::uint32_t> latest_input_frame {0};
    std::atomic<std::uint32_t> latest_replay_frame {0};
    std::atomic<std::uint64_t> input_packets {0};
    std::atomic<std::uint64_t> replay_packets {0};
    std::atomic<std::uint64_t> replay_queue_full_polls {0};
    std::atomic<std::uint64_t> frames_rendered {0};
    std::atomic<std::uint64_t> frames_published {0};
    std::atomic<std::uint64_t> replay_budget_drops {0};
    std::atomic<std::uint64_t> publication_replacements {0};
    std::atomic<std::uint32_t> publication_queue_high_water {0};
};

// Current one-shot token carried in the high half of the HPS heartbeat. Normal
// service heartbeat writes preserve it while a manual capture is in flight.
std::uint32_t fpga_diagnostic_request_token() noexcept;

// Low-overhead public crash recorder. Normal operation samples the existing
// shared header at 10 Hz; it creates no additional FPGA DDR transactions.
class FpgaCrashMonitor {
public:
    FpgaCrashMonitor(
        volatile h3d::Header* header, bool enabled,
        const FpgaRuntimeTelemetry* runtime_telemetry = nullptr);
    ~FpgaCrashMonitor();

    FpgaCrashMonitor(const FpgaCrashMonitor&) = delete;
    FpgaCrashMonitor& operator=(const FpgaCrashMonitor&) = delete;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace nds4mister::crash
