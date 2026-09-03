#pragma once

#include "replay/Hybrid3DFramePacket.h"

#include <cstdint>

namespace nds4mister::arm_video {

// These values extend the existing 16-byte H3B record vocabulary. Production
// applies them to the ARM renderer and publishes only complete frames through
// the frame-safe framebuffer handoff.
enum class RecordKind : std::uint8_t {
    Gpu2DRegister = 5,
    PaletteWrite = 6,
    OamWrite = 7,
    HBlank = 8,
};

constexpr bool valid_byte_enable(std::uint8_t access,
                                 std::uint8_t byte_enable) noexcept {
    if (access == 0)
        return byte_enable == 0x1 || byte_enable == 0x2 ||
               byte_enable == 0x4 || byte_enable == 0x8;
    if (access == 1)
        return byte_enable == 0x3 || byte_enable == 0xc;
    return access == 2 && byte_enable == 0xf;
}

constexpr bool gpu_2d_address(std::uint32_t address) noexcept {
    return (address >= 0x04000000u && address <= 0x0400005fu) ||
           (address >= 0x04000064u && address <= 0x0400006fu) ||
           (address >= 0x04001000u && address <= 0x0400106fu);
}

constexpr bool address_matches_byte_enable(
        std::uint32_t address, std::uint8_t byte_enable) noexcept {
    const auto lane = static_cast<std::uint8_t>(address & 3u);
    if (byte_enable == 0xf) return lane == 0;
    if (byte_enable == 0x3) return lane == 0;
    if (byte_enable == 0xc) return lane == 2;
    return byte_enable == static_cast<std::uint8_t>(1u << lane);
}

constexpr bool validate_record(
        const h3d::frame_packet::Record& record) noexcept {
    const auto kind = static_cast<RecordKind>(record.metadata & 0xffu);
    const auto access = static_cast<std::uint8_t>(
        (record.metadata >> 8) & 0x03u);
    const auto byte_enable = h3d::frame_packet::record_byte_enable(record);
    if ((record.metadata & 0xc000fc00u) != 0 ||
        (!h3d::frame_packet::record_has_scanline(record) &&
         (record.metadata & h3d::frame_packet::RecordScanlineMask) != 0) ||
        (h3d::frame_packet::record_has_scanline(record) &&
         h3d::frame_packet::record_scanline(record) >= 263) ||
        (record.data >> 32) != 0)
        return false;

    switch (kind) {
    case RecordKind::Gpu2DRegister:
        return gpu_2d_address(record.address_or_aux) &&
               valid_byte_enable(access, byte_enable) &&
               address_matches_byte_enable(
                   record.address_or_aux, byte_enable);
    case RecordKind::PaletteWrite:
        return record.address_or_aux >= 0x05000000u &&
               record.address_or_aux <= 0x050007ffu &&
               valid_byte_enable(access, byte_enable) &&
               address_matches_byte_enable(
                   record.address_or_aux, byte_enable);
    case RecordKind::OamWrite:
        return record.address_or_aux >= 0x07000000u &&
               record.address_or_aux <= 0x070007ffu &&
               valid_byte_enable(access, byte_enable) &&
               address_matches_byte_enable(
                   record.address_or_aux, byte_enable);
    case RecordKind::HBlank:
        return access == 0 && byte_enable == 0 &&
               record.address_or_aux < 263 && (record.data >> 32) == 0;
    }
    return false;
}

constexpr h3d::frame_packet::Record make_record(
    RecordKind kind, std::uint8_t access, std::uint8_t byte_enable,
    std::uint32_t address_or_line, std::uint32_t data) noexcept {
    return {
        static_cast<std::uint32_t>(kind) |
            ((static_cast<std::uint32_t>(access) & 0x03u) << 8) |
            ((static_cast<std::uint32_t>(byte_enable) & 0x0fu) << 16),
        address_or_line,
        data,
    };
}

} // namespace nds4mister::arm_video
