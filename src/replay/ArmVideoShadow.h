#pragma once

#include "NDS4MiSTer_2DTrace.h"
#include "replay/ArmVideoEvent.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace nds4mister {

// Strict HGS2 receiver state for the ARM-side full-video renderer. This class
// deliberately has no display side effects: it first proves that the ordered
// stream contains a complete, coherent melonDS 2D input state.
class ArmVideoShadow {
public:
    static constexpr std::size_t kRegionCount = 13;
    static constexpr std::size_t kMemoryGranularity = 512;

    struct Stats {
        std::uint64_t records = 0;
        std::uint64_t memory_deltas = 0;
        std::uint64_t memory_bytes = 0;
        std::uint64_t scanlines = 0;
        std::uint64_t completed_frames = 0;
        std::uint64_t geometry_commands = 0;
        std::uint64_t geometry_registers = 0;
        std::uint64_t geometry_frames = 0;
        std::uint64_t compact_records = 0;
        std::uint64_t compact_hblanks = 0;
    };

    ArmVideoShadow();

    bool apply(std::uint16_t type, const void* payload,
               std::size_t payload_size);
    bool apply_compact_record(
        const h3d::frame_packet::Record& record, std::uint32_t frame);

    bool failed() const noexcept { return failed_; }
    const std::string& error() const noexcept { return error_; }
    bool ready_for_render() const noexcept;
    const Stats& stats() const noexcept { return stats_; }

    bool have_scanline() const noexcept { return have_scanline_; }
    const melonDS::NDS4MiSTer::Trace2DScanlinePacket& scanline() const
        noexcept { return scanline_; }
    const melonDS::NDS4MiSTer::Trace2DInternal2DLatchPacket& latch() const
        noexcept { return latch_; }
    const melonDS::NDS4MiSTer::Trace2DExtendedPaletteMapPacket&
        extended_palette_map() const noexcept { return extended_palette_map_; }
    const std::array<std::uint8_t, 9>& vramcnt() const noexcept {
        return vramcnt_;
    }
    const std::array<std::uint8_t, 0x70>& gpu2d_registers(
        std::size_t engine) const;
    bool have_compact_hblank() const noexcept {
        return compact_position_valid_;
    }
    std::uint32_t compact_frame() const noexcept {
        return compact_position_.frame;
    }
    std::uint16_t compact_line() const noexcept {
        return compact_position_.line;
    }

    const std::vector<std::uint8_t>& memory(
        melonDS::NDS4MiSTer::Trace2DMemoryRegion region) const;

private:
    struct Position {
        std::uint32_t frame = 0;
        std::uint16_t line = 0;
    };

    bool fail(const char* message);
    bool accept_position(std::uint32_t frame, std::uint16_t line);
    bool apply_memory(std::uint16_t type, const void* payload,
                      std::size_t payload_size);
    bool write_compact_bytes(std::vector<std::uint8_t>& destination,
                             std::uint32_t offset,
                             const h3d::frame_packet::Record& record);
    bool write_compact_register(
        const h3d::frame_packet::Record& record);
    bool memory_initialized() const noexcept;

    std::array<std::vector<std::uint8_t>, kRegionCount> memory_{};
    std::array<std::vector<std::uint8_t>, kRegionCount> initialized_{};
    std::array<std::array<std::uint8_t, 0x70>, 2> gpu2d_registers_{};
    std::array<std::uint8_t, 9> vramcnt_{};
    melonDS::NDS4MiSTer::Trace2DScanlinePacket scanline_{};
    melonDS::NDS4MiSTer::Trace2DInternal2DLatchPacket latch_{};
    melonDS::NDS4MiSTer::Trace2DExtendedPaletteMapPacket
        extended_palette_map_{};
    Position pending_position_{};
    Position expected_position_{};
    Position compact_position_{};
    bool pending_position_valid_ = false;
    bool expected_position_valid_ = false;
    bool compact_position_valid_ = false;
    bool have_vram_map_ = false;
    bool have_scanline_ = false;
    bool have_latch_ = false;
    bool have_extended_palette_map_ = false;
    bool failed_ = false;
    std::string error_;
    Stats stats_{};
};

} // namespace nds4mister
