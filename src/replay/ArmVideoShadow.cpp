#include "replay/ArmVideoShadow.h"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace nds4mister {
namespace {

using namespace melonDS::NDS4MiSTer;

constexpr std::array<std::size_t, ArmVideoShadow::kRegionCount>
    kRegionSizes{{
        2 * 1024,   // Palette
        2 * 1024,   // OAM
        128 * 1024, // VRAM A
        128 * 1024, // VRAM B
        128 * 1024, // VRAM C
        128 * 1024, // VRAM D
        64 * 1024,  // VRAM E
        16 * 1024,  // VRAM F
        16 * 1024,  // VRAM G
        32 * 1024,  // VRAM H
        16 * 1024,  // VRAM I
        256 * 1024, // Flattened engine-A OBJ
        128 * 1024, // Flattened engine-B OBJ
    }};

template <typename T>
bool copy_exact(T& destination, const void* payload,
                std::size_t payload_size) {
    if (payload_size != sizeof(T)) return false;
    std::memcpy(&destination, payload, sizeof(T));
    return true;
}

} // namespace

ArmVideoShadow::ArmVideoShadow() {
    for (std::size_t region = 0; region < kRegionCount; ++region) {
        memory_[region].resize(kRegionSizes[region]);
        initialized_[region].resize(
            kRegionSizes[region] / kMemoryGranularity);
    }
}

bool ArmVideoShadow::fail(const char* message) {
    if (!failed_) error_ = message;
    failed_ = true;
    return false;
}

bool ArmVideoShadow::accept_position(std::uint32_t frame,
                                     std::uint16_t line) {
    if (line >= 192) return fail("2D record line is outside visible range");
    const Position position{frame, line};
    if (expected_position_valid_ &&
        (position.frame != expected_position_.frame ||
         position.line != expected_position_.line))
        return fail("2D record skipped or reordered a scanline");
    if (pending_position_valid_ &&
        (position.frame != pending_position_.frame ||
         position.line != pending_position_.line))
        return fail("2D records for different scanlines were interleaved");
    pending_position_ = position;
    pending_position_valid_ = true;
    return true;
}

bool ArmVideoShadow::apply_memory(std::uint16_t type, const void* payload,
                                  std::size_t payload_size) {
    constexpr std::size_t header_payload_size =
        sizeof(Trace2DMemoryDeltaHeader) - sizeof(Trace2DRecordHeader);
    if (payload_size <= header_payload_size)
        return fail("HGS2 memory delta has no payload bytes");

    Trace2DMemoryDeltaHeader header{};
    std::memcpy(reinterpret_cast<std::uint8_t*>(&header) +
                    sizeof(Trace2DRecordHeader),
                payload, header_payload_size);
    const auto region = static_cast<std::size_t>(header.Region);
    if (region >= kRegionCount)
        return fail("HGS2 memory delta has an unknown region");
    if ((type == 1 && region < 2) || (type == 6 && region >= 2))
        return fail("HGS2 memory delta used the wrong record class");
    if (header.Reserved != 0)
        return fail("HGS2 memory delta reserved byte is nonzero");

    const auto bytes = payload_size - header_payload_size;
    if ((header.Offset % kMemoryGranularity) != 0 ||
        (bytes % kMemoryGranularity) != 0)
        return fail("HGS2 memory delta is not 512-byte aligned");
    if (header.Offset > memory_[region].size() ||
        bytes > memory_[region].size() - header.Offset)
        return fail("HGS2 memory delta is out of bounds");
    if (!accept_position(header.Frame, header.Line)) return false;

    const auto* source = static_cast<const std::uint8_t*>(payload) +
                         header_payload_size;
    std::memcpy(memory_[region].data() + header.Offset, source, bytes);
    const auto first_page = header.Offset / kMemoryGranularity;
    const auto page_count = bytes / kMemoryGranularity;
    std::fill_n(initialized_[region].begin() +
                    static_cast<std::ptrdiff_t>(first_page),
                page_count, std::uint8_t{1});
    ++stats_.memory_deltas;
    stats_.memory_bytes += bytes;
    return true;
}

bool ArmVideoShadow::apply(std::uint16_t type, const void* payload,
                           std::size_t payload_size) {
    if (failed_) return false;
    if (payload == nullptr && payload_size != 0)
        return fail("HGS2 record has a null payload");

    using namespace melonDS::NDS4MiSTer;
    bool accepted = false;
    if (type == 1 || type == 6) {
        accepted = apply_memory(type, payload, payload_size);
    } else if (type == 2) {
        std::array<std::uint8_t, 16> mapping{};
        if (!copy_exact(mapping, payload, payload_size))
            return fail("HGS2 VRAM mapping has the wrong size");
        if (!std::all_of(mapping.begin() + 13, mapping.end(),
                         [](std::uint8_t value) { return value == 0; }))
            return fail("HGS2 VRAM mapping reserved bytes are nonzero");
        std::uint32_t frame = 0;
        std::memcpy(&frame, mapping.data(), sizeof(frame));
        if ((expected_position_valid_ &&
             frame != expected_position_.frame) ||
            (pending_position_valid_ &&
             frame != pending_position_.frame))
            return fail("HGS2 VRAM mapping belongs to the wrong frame");
        std::copy_n(mapping.begin() + 4, vramcnt_.size(), vramcnt_.begin());
        have_vram_map_ = true;
        accepted = true;
    } else if (type == 3) {
        Trace2DGeometryCommandPacket packet{};
        constexpr auto size = sizeof(packet) - sizeof(packet.Record);
        if (payload_size != size)
            return fail("HGS2 geometry command has the wrong size");
        std::memcpy(reinterpret_cast<std::uint8_t*>(&packet) +
                        sizeof(packet.Record),
                    payload, size);
        if (!std::all_of(std::begin(packet.Reserved),
                         std::end(packet.Reserved),
                         [](std::uint8_t value) { return value == 0; }))
            return fail("HGS2 geometry command reserved bytes are nonzero");
        ++stats_.geometry_commands;
        accepted = true;
    } else if (type == 4) {
        Trace2DGeometryRegisterPacket packet{};
        constexpr auto size = sizeof(packet) - sizeof(packet.Record);
        if (payload_size != size)
            return fail("HGS2 geometry register has the wrong size");
        std::memcpy(reinterpret_cast<std::uint8_t*>(&packet) +
                        sizeof(packet.Record),
                    payload, size);
        if (packet.Width != 1 && packet.Width != 2 && packet.Width != 4)
            return fail("HGS2 geometry register has an invalid width");
        if (!std::all_of(std::begin(packet.Reserved),
                         std::end(packet.Reserved),
                         [](std::uint8_t value) { return value == 0; }))
            return fail("HGS2 geometry register reserved bytes are nonzero");
        ++stats_.geometry_registers;
        accepted = true;
    } else if (type == 5) {
        Trace2DGeometryFramePacket packet{};
        constexpr auto size = sizeof(packet) - sizeof(packet.Record);
        if (payload_size != size)
            return fail("HGS2 geometry frame has the wrong size");
        ++stats_.geometry_frames;
        accepted = true;
    } else if (type == 7) {
        Trace2DScanlinePacket packet{};
        if (!copy_exact(packet, payload, payload_size))
            return fail("HGS2 scanline state has the wrong size");
        if (packet.Line != packet.VCount)
            return fail("HGS2 scanline and VCount disagree");
        if (!accept_position(packet.Frame, packet.Line)) return false;
        scanline_ = packet;
        vramcnt_ = {};
        std::copy_n(packet.VRAMCNT, vramcnt_.size(), vramcnt_.begin());
        have_vram_map_ = true;
        have_scanline_ = true;
        ++stats_.scanlines;
        if (packet.Line == 191) ++stats_.completed_frames;
        expected_position_ = packet.Line == 191
            ? Position{packet.Frame + 1U, 0}
            : Position{packet.Frame,
                       static_cast<std::uint16_t>(packet.Line + 1U)};
        expected_position_valid_ = true;
        pending_position_valid_ = false;
        accepted = true;
    } else if (type == 8) {
        Trace2DInternal2DLatchPacket packet{};
        constexpr auto size = sizeof(packet) - sizeof(packet.Record);
        if (payload_size != size)
            return fail("HGS2 internal 2D latch has the wrong size");
        std::memcpy(reinterpret_cast<std::uint8_t*>(&packet) +
                        sizeof(packet.Record),
                    payload, size);
        if (!accept_position(packet.Frame, packet.Line)) return false;
        latch_ = packet;
        have_latch_ = true;
        accepted = true;
    } else if (type == 9) {
        Trace2DExtendedPaletteMapPacket packet{};
        constexpr auto size = sizeof(packet) - sizeof(packet.Record);
        if (payload_size != size)
            return fail("HGS2 extended palette map has the wrong size");
        std::memcpy(reinterpret_cast<std::uint8_t*>(&packet) +
                        sizeof(packet.Record),
                    payload, size);
        if (packet.Reserved != 0)
            return fail("HGS2 extended palette reserved field is nonzero");
        if (!accept_position(packet.Frame, packet.Line)) return false;
        extended_palette_map_ = packet;
        have_extended_palette_map_ = true;
        accepted = true;
    } else {
        return fail("HGS2 record type is unsupported");
    }

    if (accepted) ++stats_.records;
    return accepted;
}

bool ArmVideoShadow::write_compact_bytes(
    std::vector<std::uint8_t>& destination, std::uint32_t offset,
    const h3d::frame_packet::Record& record) {
    const auto byte_enable = h3d::frame_packet::record_byte_enable(record);
    const auto aligned_offset = offset & ~std::uint32_t{3};
    for (std::uint32_t lane = 0; lane < 4; ++lane) {
        if ((byte_enable & (1u << lane)) == 0) continue;
        const auto byte_offset = aligned_offset + lane;
        if (byte_offset >= destination.size())
            return fail("compact ARM video write is out of bounds");
        destination[byte_offset] = static_cast<std::uint8_t>(
            record.data >> (lane * 8));
    }
    return true;
}

bool ArmVideoShadow::write_compact_register(
    const h3d::frame_packet::Record& record) {
    std::size_t engine = 0;
    std::uint32_t base = 0x04000000u;
    if (record.address_or_aux >= 0x04001000u) {
        engine = 1;
        base = 0x04001000u;
    }
    const auto offset = record.address_or_aux - base;
    const auto byte_enable = h3d::frame_packet::record_byte_enable(record);
    const auto aligned_offset = offset & ~std::uint32_t{3};
    for (std::uint32_t lane = 0; lane < 4; ++lane) {
        if ((byte_enable & (1u << lane)) == 0) continue;
        const auto byte_offset = aligned_offset + lane;
        if (byte_offset >= gpu2d_registers_[engine].size())
            return fail("compact GPU2D register write is out of bounds");
        gpu2d_registers_[engine][byte_offset] =
            static_cast<std::uint8_t>(record.data >> (lane * 8));
    }
    return true;
}

bool ArmVideoShadow::apply_compact_record(
    const h3d::frame_packet::Record& record, std::uint32_t frame) {
    // Compact mutations are ordered by the packet stream. HBlank carries the
    // independent display-frame identity because 3D SWAP may advance the
    // packet's logical frame before the 2D VBlank.
    (void)frame;
    if (failed_) return false;
    if (!arm_video::validate_record(record))
        return fail("compact ARM video record is malformed");

    const auto kind = static_cast<arm_video::RecordKind>(
        record.metadata & 0xffu);
    switch (kind) {
    case arm_video::RecordKind::Gpu2DRegister:
        if (!write_compact_register(record)) return false;
        break;
    case arm_video::RecordKind::PaletteWrite:
        if (!write_compact_bytes(
                memory_[static_cast<std::size_t>(
                    Trace2DMemoryRegion::Palette)],
                record.address_or_aux - 0x05000000u, record))
            return false;
        break;
    case arm_video::RecordKind::OamWrite:
        if (!write_compact_bytes(
                memory_[static_cast<std::size_t>(Trace2DMemoryRegion::OAM)],
                record.address_or_aux - 0x07000000u, record))
            return false;
        break;
    case arm_video::RecordKind::HBlank: {
        const auto line = static_cast<std::uint16_t>(record.address_or_aux);
        const auto display_frame = static_cast<std::uint32_t>(record.data);
        if (compact_position_valid_) {
            const Position expected = compact_position_.line == 262
                ? Position{compact_position_.frame + 1U, 0}
                : Position{compact_position_.frame,
                           static_cast<std::uint16_t>(
                               compact_position_.line + 1U)};
            if (display_frame != expected.frame || line != expected.line)
                return fail("compact HBlank skipped or reordered a line");
        }
        compact_position_ = {display_frame, line};
        compact_position_valid_ = true;
        ++stats_.compact_hblanks;
        break;
    }
    }
    ++stats_.compact_records;
    return true;
}

bool ArmVideoShadow::memory_initialized() const noexcept {
    for (const auto& pages : initialized_)
        if (std::find(pages.begin(), pages.end(), std::uint8_t{0}) !=
            pages.end())
            return false;
    return true;
}

bool ArmVideoShadow::ready_for_render() const noexcept {
    return !failed_ && have_vram_map_ && have_scanline_ && have_latch_ &&
           have_extended_palette_map_ && memory_initialized();
}

const std::vector<std::uint8_t>& ArmVideoShadow::memory(
    Trace2DMemoryRegion region) const {
    const auto index = static_cast<std::size_t>(region);
    if (index >= kRegionCount)
        throw std::out_of_range("unknown ARM video shadow memory region");
    return memory_[index];
}

const std::array<std::uint8_t, 0x70>& ArmVideoShadow::gpu2d_registers(
    std::size_t engine) const {
    if (engine >= gpu2d_registers_.size())
        throw std::out_of_range("unknown GPU2D engine");
    return gpu2d_registers_[engine];
}

} // namespace nds4mister
