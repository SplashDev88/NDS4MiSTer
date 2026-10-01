#pragma once

#include "replay/CausalTimeline.h"

#include <atomic>
#include <array>
#include <cstdint>
#include <memory>

namespace nds4mister::h3d {
struct Header;
}

namespace nds4mister::crash {

// Private opt-in pacing diagnostic. Cumulative values, sampled at 10 Hz;
// spans are wall microseconds, not CPU time or measured controller latency.
enum class PacingMetric : std::size_t {
    Enabled, Admitted, AgeOnly, PacketsOnly, AgeAndPackets,
    Draws, DrawUs, DrawMaxUs, ReplayPackets, ReplayUs, ReplayMaxUs,
    QueuedPictures, QueueUs, QueueMaxUs, Uploads, UploadUs, UploadMaxUs,
    GxQueries, GxFastReplies, GxFastUs, GxFastMaxUs,
    GxOrderedReplies, GxOrderedUs, GxOrderedMaxUs, GxOrderedBusy,
    GxPrefixBusyFallback, GxPrefixUnavailableFallback, GxSwapsInput, GxSwapsReplay,
    IntakeBurstRetries, IntakeBurstHits, IntakeSleeps, IntakeSleepUs, IntakeSleepMaxUs,
    RecoverySkips,
    Count
};
constexpr std::size_t PacingMetricCount = static_cast<std::size_t>(PacingMetric::Count);
inline constexpr std::array<const char*, PacingMetricCount> PacingMetricNames {{
    "enabled", "admitted", "age_only", "packets_only", "age_and_packets",
    "draws", "draw_us", "draw_max_us", "replay_packets", "replay_us", "replay_max_us",
    "queued_pictures", "queue_us", "queue_max_us", "uploads", "upload_us", "upload_max_us",
    "gx_queries", "gx_fast_replies", "gx_fast_us", "gx_fast_max_us",
    "gx_ordered_replies", "gx_ordered_us", "gx_ordered_max_us", "gx_ordered_busy",
    "gx_prefix_busy_fallback", "gx_prefix_unavailable_fallback", "gx_swaps_input", "gx_swaps_replay",
    "intake_burst_retries", "intake_burst_hits", "intake_sleeps", "intake_sleep_us", "intake_sleep_max_us",
    "recovery_skips"
}};

// Process-local counters sampled by the crash recorder. Base counters are
// published on the throttled heartbeat. The private opt-in pacing counters
// below update at packet/frame boundaries, never at individual guest records.
struct FpgaRuntimeTelemetry {
    void reset(std::uint32_t new_session) noexcept;
    std::unique_ptr<CausalTimeline> timeline; // Construct before recorder/workers; never reset live.

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
    std::array<std::atomic<std::uint64_t>, PacingMetricCount> pacing {};
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
