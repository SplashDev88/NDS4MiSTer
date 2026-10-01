#pragma once

#include <cstdint>

namespace nds4mister::replay {

// Admit derived full-picture work only near the input head. Both frame IDs
// are H3B logical frame IDs, never the separate LCD descriptor counter. The
// packet bound also covers a large frame split across continuation packets.
// This is a selection rule, not a wall-clock latency or throughput guarantee:
// once admitted, a picture finishes atomically before the next decision.
constexpr bool matched_display_can_draw(
    std::uint32_t active_packet_frame, std::uint32_t latest_input_frame,
    std::uint32_t queued_packets, std::uint32_t packet_limit = 4u) noexcept
{
    return std::uint32_t(latest_input_frame - active_packet_frame) <= 1u &&
        queued_packets <= packet_limit;
}

// Private recovery experiment: after measured replay pressure, temporarily
// alternate complete pictures for twelve healthy LCD frames. All architecture
// still replays. Healthy operation stays full-rate, without a permanent cap.
// This class is owned by replay and reset with each new game session.
class MatchedDisplayRecovery {
public:
    static constexpr unsigned RecoveryFrames = 12;
    bool can_draw(bool near_head) noexcept
    {
        if (!near_head) {
            healthy_left_ = RecoveryFrames;
            skip_next_ = false; // The first recovered picture should be fresh.
            return false;
        }
        if (!healthy_left_) return true;
        --healthy_left_;
        const bool draw = !skip_next_;
        skip_next_ = !skip_next_;
        return draw;
    }
    void reset() noexcept { healthy_left_ = 0; skip_next_ = false; }
private:
    unsigned healthy_left_ = 0;
    bool skip_next_ = false;
};

} // namespace nds4mister::replay
