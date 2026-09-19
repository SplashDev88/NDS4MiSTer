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
    std::uint32_t queued_packets) noexcept
{
    return std::uint32_t(latest_input_frame - active_packet_frame) <= 1u &&
        queued_packets <= 4u;
}

} // namespace nds4mister::replay
