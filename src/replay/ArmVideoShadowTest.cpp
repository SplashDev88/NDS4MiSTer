#include "replay/ArmVideoShadow.h"
#include "replay/HpsGpuRing.h"
#include "replay/LiveHgsEncoder.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

using namespace melonDS::NDS4MiSTer;

namespace {

template <typename Packet>
std::vector<std::uint8_t> payload_without_header(const Packet& packet) {
    const auto* begin = reinterpret_cast<const std::uint8_t*>(&packet) +
                        sizeof(packet.Record);
    return {begin, begin + sizeof(packet) - sizeof(packet.Record)};
}

template <typename Packet>
void append_packet(std::vector<std::uint8_t>& destination,
                   const Packet& packet) {
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(&packet);
    destination.insert(destination.end(), bytes, bytes + sizeof(packet));
}

bool apply_delta(nds4mister::ArmVideoShadow& shadow,
                 Trace2DMemoryRegion region, std::uint32_t offset,
                 std::size_t bytes, std::uint32_t frame,
                 std::uint16_t line, std::uint8_t fill) {
    Trace2DMemoryDeltaHeader header{};
    header.Frame = frame;
    header.Line = line;
    header.Region = static_cast<std::uint8_t>(region);
    std::vector<std::uint8_t> payload(
        sizeof(header) - sizeof(header.Record) + bytes, fill);
    const auto type = static_cast<std::uint8_t>(region) < 2 ? 6 : 1;
    header.Offset = offset;
    std::memcpy(payload.data(),
                reinterpret_cast<const std::uint8_t*>(&header) +
                    sizeof(header.Record),
                sizeof(header) - sizeof(header.Record));
    return shadow.apply(type, payload.data(), payload.size());
}

} // namespace

int main() {
    nds4mister::ArmVideoShadow shadow;

    constexpr std::array<std::size_t, 13> region_sizes{{
        2 * 1024, 2 * 1024, 128 * 1024, 128 * 1024, 128 * 1024,
        128 * 1024, 64 * 1024, 16 * 1024, 16 * 1024, 32 * 1024,
        16 * 1024, 256 * 1024, 128 * 1024,
    }};
    for (std::size_t region = 0; region < region_sizes.size(); ++region) {
        const auto memory_region = static_cast<Trace2DMemoryRegion>(region);
        for (std::size_t offset = 0; offset < region_sizes[region];
             offset += nds4mister::ArmVideoShadow::kMemoryGranularity) {
            if (!apply_delta(shadow, memory_region,
                             static_cast<std::uint32_t>(offset),
                             nds4mister::ArmVideoShadow::kMemoryGranularity,
                             7, 0, static_cast<std::uint8_t>(region + 1)))
                return 1;
        }
    }

    std::array<std::uint8_t, 16> mapping{};
    const std::uint32_t mapping_frame = 7;
    std::memcpy(mapping.data(), &mapping_frame, sizeof(mapping_frame));
    mapping[4] = 0x82;
    mapping[5] = 0x83;
    mapping[6] = 0x8b;
    if (!shadow.apply(2, mapping.data(), mapping.size())) return 2;

    Trace2DInternal2DLatchPacket latch{};
    latch.Frame = 7;
    latch.Line = 0;
    latch.Engine[0].BGXRefInternal[0] = 0x12345;
    auto latch_payload = payload_without_header(latch);
    if (!shadow.apply(8, latch_payload.data(), latch_payload.size())) return 3;

    Trace2DExtendedPaletteMapPacket extpal{};
    extpal.Frame = 7;
    extpal.Line = 0;
    extpal.ABG[0] = 3;
    auto extpal_payload = payload_without_header(extpal);
    if (!shadow.apply(9, extpal_payload.data(), extpal_payload.size())) return 4;

    Trace2DScanlinePacket scanline{};
    scanline.Frame = 7;
    scanline.Line = 0;
    scanline.VCount = 0;
    scanline.VRAMCNT[0] = 0x82;
    scanline.VRAMCNT[1] = 0x83;
    scanline.VRAMCNT[2] = 0x8b;
    scanline.Engine[0].DispCnt = 0x00031f00;
    if (!shadow.apply(7, &scanline, sizeof(scanline))) return 5;
    if (!shadow.ready_for_render()) return 6;
    if (shadow.scanline().Engine[0].DispCnt != 0x00031f00 ||
        shadow.latch().Engine[0].BGXRefInternal[0] != 0x12345 ||
        shadow.extended_palette_map().ABG[0] != 3 ||
        shadow.vramcnt()[2] != 0x8b)
        return 7;
    if (shadow.memory(Trace2DMemoryRegion::VRAME).front() != 7)
        return 8;

    for (std::uint16_t line = 1; line < 192; ++line) {
        scanline.Line = line;
        scanline.VCount = line;
        if (!shadow.apply(7, &scanline, sizeof(scanline))) return 9;
    }
    if (shadow.stats().completed_frames != 1 ||
        shadow.stats().scanlines != 192)
        return 10;

    nds4mister::ArmVideoShadow reordered;
    Trace2DScanlinePacket first{};
    first.Frame = 11;
    first.Line = first.VCount = 0;
    if (!reordered.apply(7, &first, sizeof(first))) return 11;
    first.Line = first.VCount = 2;
    if (reordered.apply(7, &first, sizeof(first)) || !reordered.failed())
        return 12;

    nds4mister::ArmVideoShadow malformed;
    if (apply_delta(malformed, Trace2DMemoryRegion::Palette, 0,
                    nds4mister::ArmVideoShadow::kMemoryGranularity + 1,
                    1, 0, 0xaa))
        return 13;

    nds4mister::ArmVideoShadow incomplete;
    first = {};
    first.Frame = 1;
    first.Line = first.VCount = 0;
    if (!incomplete.apply(7, &first, sizeof(first)) ||
        incomplete.ready_for_render())
        return 14;

    // Exercise the actual trace-v9 -> HGS2 encoder -> ARM shadow boundary.
    nds4mister::HpsGpuRingControl control;
    control.capacity = 4096;
    std::vector<std::byte> ring_storage(control.capacity);
    nds4mister::HpsGpuRing ring(control, ring_storage.data());
    nds4mister::LiveHgsEncoder encoder(ring);
    std::vector<std::uint8_t> raw;
    latch = {};
    latch.Record = {
        static_cast<std::uint16_t>(Trace2DRecordType::Internal2DLatch),
        static_cast<std::uint16_t>(sizeof(latch))};
    latch.Frame = 12;
    latch.Line = 0;
    append_packet(raw, latch);
    scanline = {};
    scanline.Frame = 12;
    scanline.Line = scanline.VCount = 0;
    scanline.VRAMCNT[4] = 0x83;
    const Trace2DRecordHeader scanline_header{
        static_cast<std::uint16_t>(Trace2DRecordType::Scanline),
        static_cast<std::uint16_t>(sizeof(Trace2DRecordHeader) +
                                   sizeof(scanline))};
    append_packet(raw, scanline_header);
    append_packet(raw, scanline);
    for (std::size_t offset = 0; offset < raw.size();) {
        const auto bytes = std::min<std::size_t>(13, raw.size() - offset);
        encoder.feed(raw.data() + offset, bytes);
        offset += bytes;
    }
    if (!encoder.finish()) return 15;

    nds4mister::ArmVideoShadow encoded_shadow;
    std::array<std::uint8_t, 4092> encoded_payload{};
    std::array<std::uint16_t, 3> expected_types{{8, 2, 7}};
    for (const auto expected_type : expected_types) {
        std::uint16_t type = 0;
        std::uint16_t size = 0;
        if (!ring.pop(type, encoded_payload.data(), encoded_payload.size(),
                      size) ||
            type != expected_type ||
            !encoded_shadow.apply(type, encoded_payload.data(), size))
            return 16;
    }
    if (control.producer.load() != control.consumer.load() ||
        encoded_shadow.scanline().Frame != 12 ||
        encoded_shadow.vramcnt()[4] != 0x83)
        return 17;

    nds4mister::ArmVideoShadow compact_shadow;
    auto compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::Gpu2DRegister,
        1, 0x3, 0x04000018, 0x00000123);
    if (!compact_shadow.apply_compact_record(compact_record, 3)) return 18;
    compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::Gpu2DRegister,
        1, 0xc, 0x0400101a, 0xabcd0000);
    if (!compact_shadow.apply_compact_record(compact_record, 3)) return 19;
    compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::PaletteWrite,
        1, 0xc, 0x05000402, 0x66550000);
    if (!compact_shadow.apply_compact_record(compact_record, 3)) return 20;
    compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::OamWrite,
        2, 0xf, 0x07000040, 0x44332211);
    if (!compact_shadow.apply_compact_record(compact_record, 3)) return 21;
    compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::HBlank, 0, 0, 0, 3);
    if (!compact_shadow.apply_compact_record(compact_record, 99)) return 22;
    for (std::uint32_t line = 1; line <= 262; ++line) {
        compact_record = nds4mister::arm_video::make_record(
            nds4mister::arm_video::RecordKind::HBlank, 0, 0, line, 3);
        if (!compact_shadow.apply_compact_record(compact_record, 99))
            return 23;
    }
    compact_record = nds4mister::arm_video::make_record(
        nds4mister::arm_video::RecordKind::HBlank, 0, 0, 0, 4);
    if (!compact_shadow.apply_compact_record(compact_record, 99)) return 24;
    if (compact_shadow.gpu2d_registers(0)[0x18] != 0x23 ||
        compact_shadow.gpu2d_registers(0)[0x19] != 0x01 ||
        compact_shadow.gpu2d_registers(1)[0x1a] != 0xcd ||
        compact_shadow.gpu2d_registers(1)[0x1b] != 0xab ||
        compact_shadow.memory(Trace2DMemoryRegion::Palette)[0x402] != 0x55 ||
        compact_shadow.memory(Trace2DMemoryRegion::Palette)[0x403] != 0x66 ||
        compact_shadow.memory(Trace2DMemoryRegion::OAM)[0x40] != 0x11 ||
        compact_shadow.memory(Trace2DMemoryRegion::OAM)[0x43] != 0x44 ||
        compact_shadow.compact_frame() != 4 ||
        compact_shadow.compact_line() != 0)
        return 25;
    compact_record.address_or_aux = 263;
    if (compact_shadow.apply_compact_record(compact_record, 3)) return 26;

    std::cout
        << "ARM full-video shadow test\n"
        << "complete_memory_snapshot: passed\n"
        << "scanline_ordering: passed\n"
        << "vram_palette_oam_shadow: passed\n"
        << "mapping_and_internal_latches: passed\n"
        << "live_hgs2_encoder_boundary: passed\n"
        << "compact_event_state_reconstruction: passed\n"
        << "malformed_record_fail_closed: passed\n"
        << "render_readiness_gate: passed\n";
    return 0;
}
