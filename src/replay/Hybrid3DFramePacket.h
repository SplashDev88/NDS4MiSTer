#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <vector>

namespace nds4mister::h3d::frame_packet {

constexpr std::uint64_t ControlPhysicalAddress = 0x3fc00000ull;
constexpr std::uint64_t SlotsPhysicalAddress = 0x3fc10000ull;
constexpr std::size_t SlotsMappingOffset =
    static_cast<std::size_t>(SlotsPhysicalAddress - ControlPhysicalAddress);
constexpr std::size_t MappingBytes = 0x50000;
constexpr std::size_t SlotCount = 4;
constexpr std::size_t SlotBytes = 64 * 1024;
constexpr std::size_t HeaderBytes = 64;
constexpr std::size_t RecordBytes = 16;
constexpr std::size_t MaxPayloadBytes = 60 * 1024;
constexpr std::uint32_t MaxRecordCount =
    static_cast<std::uint32_t>(MaxPayloadBytes / RecordBytes);

constexpr std::size_t ControlSessionOffset = 0x08;
constexpr std::size_t ControlProducerOffset = 0x10;
constexpr std::size_t ControlAcknowledgeOffset = 0x18;
constexpr std::size_t DiagnosticMappingOffset = 0x100;
constexpr std::size_t DiagnosticEntryCount = 4;
constexpr std::size_t DiagnosticEntryBytes = 32;

constexpr std::uint32_t Magic = 0x31423348u; // H3B1
constexpr std::uint16_t Version = 1;
constexpr std::uint16_t HeaderSize = HeaderBytes;
constexpr std::uint32_t DiagnosticMagic = 0x31563348u; // H3V1
constexpr std::uint16_t DiagnosticVersion = 1;
constexpr std::uint16_t DiagnosticSize = DiagnosticEntryBytes;
constexpr std::uint32_t DiagnosticCrcInitial = 0xffffffffu;
constexpr std::uint32_t RecordScanlineValid = 1u << 29;
constexpr std::uint32_t RecordScanlineMask = 0x1ffu << 20;

enum PacketFlag : std::uint32_t {
    FlagContinuation = 1u << 0,
    FlagFrameEnd = 1u << 1,
};

enum class RecordKind : std::uint8_t {
    GxCommand = 1,
    GxRegister = 2,
    VramWrite = 3,
    VramMap = 4,
    Gpu2DRegister = 5,
    PaletteWrite = 6,
    OamWrite = 7,
    HBlank = 8,
    // Three normalized GX commands packed as
    // {data2, data1, data0, tag2, tag1, tag0, kind}.
    GxPacked = 9,
};

enum Fault : std::uint32_t {
    FaultNone = 0,
    FaultBadMapping = 1u << 0,
    FaultBadControl = 1u << 1,
    FaultBadSession = 1u << 2,
    FaultSequence = 1u << 3,
    FaultTornHeader = 1u << 4,
    FaultBadHeader = 1u << 5,
    FaultBadRecord = 1u << 6,
    FaultBadDiagnostic = 1u << 7,
};

// Eight little-endian 64-bit beats. Each pair of fields is the low word then
// the high word of one beat. commit_sequence is written last by the FPGA.
struct PacketHeader {
    std::uint32_t magic;
    std::uint16_t version;
    std::uint16_t header_size;
    std::uint32_t session;
    std::uint32_t session_reserved;
    std::uint32_t packet_sequence;
    std::uint32_t packet_sequence_reserved;
    std::uint32_t frame;
    std::uint32_t flags;
    std::uint32_t payload_bytes;
    std::uint32_t record_count;
    std::uint32_t slot_index;
    std::uint32_t slot_reserved;
    std::uint32_t reserved6_low;
    std::uint32_t reserved6_high;
    std::uint32_t commit_sequence;
    std::uint32_t commit_reserved;
};

// metadata[7:0] kind, [15:8] tag, [19:16] byte enable, [31:20] zero.
struct Record {
    std::uint32_t metadata;
    std::uint32_t address_or_aux;
    std::uint64_t data;
};

// Eight little-endian 32-bit words. commit_sequence is written last after
// the FPGA has accumulated the selected raw-record CRC across a full frame.
struct DiagnosticEntry {
    std::uint32_t magic;
    std::uint16_t version;
    std::uint16_t entry_size;
    std::uint32_t session;
    std::uint32_t terminal_sequence;
    std::uint32_t frame;
    std::uint32_t selected_count;
    std::uint32_t crc32c;
    std::uint32_t commit_sequence;
};

static_assert(sizeof(PacketHeader) == HeaderBytes);
static_assert(sizeof(Record) == RecordBytes);
static_assert(sizeof(DiagnosticEntry) == DiagnosticEntryBytes);
static_assert(std::is_standard_layout_v<PacketHeader>);
static_assert(std::is_standard_layout_v<Record>);
static_assert(std::is_standard_layout_v<DiagnosticEntry>);
static_assert(offsetof(PacketHeader, session) == 0x08);
static_assert(offsetof(PacketHeader, packet_sequence) == 0x10);
static_assert(offsetof(PacketHeader, frame) == 0x18);
static_assert(offsetof(PacketHeader, payload_bytes) == 0x20);
static_assert(offsetof(PacketHeader, slot_index) == 0x28);
static_assert(offsetof(PacketHeader, commit_sequence) == 0x38);
static_assert(offsetof(DiagnosticEntry, session) == 0x08);
static_assert(offsetof(DiagnosticEntry, terminal_sequence) == 0x0c);
static_assert(offsetof(DiagnosticEntry, frame) == 0x10);
static_assert(offsetof(DiagnosticEntry, selected_count) == 0x14);
static_assert(offsetof(DiagnosticEntry, crc32c) == 0x18);
static_assert(offsetof(DiagnosticEntry, commit_sequence) == 0x1c);

constexpr RecordKind record_kind(const Record& record)
{
    return static_cast<RecordKind>(record.metadata & 0xffu);
}

constexpr std::uint8_t record_tag(const Record& record)
{
    return static_cast<std::uint8_t>((record.metadata >> 8) & 0xffu);
}

constexpr std::uint8_t record_byte_enable(const Record& record)
{
    return static_cast<std::uint8_t>((record.metadata >> 16) & 0x0fu);
}

constexpr bool record_has_scanline(const Record& record)
{
    return (record.metadata & RecordScanlineValid) != 0;
}

constexpr std::uint16_t record_scanline(const Record& record)
{
    return static_cast<std::uint16_t>(
        (record.metadata & RecordScanlineMask) >> 20);
}

constexpr std::uint32_t make_record_metadata(
    RecordKind kind, std::uint8_t tag, std::uint8_t byte_enable)
{
    return static_cast<std::uint32_t>(kind) |
        (static_cast<std::uint32_t>(tag) << 8) |
        ((static_cast<std::uint32_t>(byte_enable) & 0x0fu) << 16);
}

constexpr std::uint8_t packed_gx_tag(
    const Record& record, std::size_t index)
{
    return static_cast<std::uint8_t>(
        record.metadata >> (8u + static_cast<unsigned>(index) * 8u));
}

constexpr std::uint32_t packed_gx_data(
    const Record& record, std::size_t index)
{
    return index == 0 ? record.address_or_aux :
        index == 1 ? static_cast<std::uint32_t>(record.data) :
                     static_cast<std::uint32_t>(record.data >> 32);
}

constexpr Record unpack_gx_command(
    const Record& record, std::size_t index)
{
    return Record {
        make_record_metadata(
            RecordKind::GxCommand, packed_gx_tag(record, index), 0),
        0,
        packed_gx_data(record, index),
    };
}

constexpr Record pack_gx_commands(
    const Record& first, const Record& second, const Record& third)
{
    return Record {
        static_cast<std::uint32_t>(RecordKind::GxPacked) |
            (static_cast<std::uint32_t>(record_tag(first)) << 8) |
            (static_cast<std::uint32_t>(record_tag(second)) << 16) |
            (static_cast<std::uint32_t>(record_tag(third)) << 24),
        static_cast<std::uint32_t>(first.data),
        static_cast<std::uint64_t>(static_cast<std::uint32_t>(second.data)) |
            (static_cast<std::uint64_t>(
                 static_cast<std::uint32_t>(third.data)) << 32),
    };
}

constexpr bool diagnostic_record_selected(const Record& record)
{
    const auto kind = record_kind(record);
    if (kind == RecordKind::VramWrite || kind == RecordKind::VramMap)
        return true;
    if (kind == RecordKind::GxRegister)
        return record.address_or_aux == 0x04000060u;
    if (kind == RecordKind::GxPacked)
        return packed_gx_tag(record, 0) == 0x2au ||
            packed_gx_tag(record, 0) == 0x2bu ||
            packed_gx_tag(record, 0) == 0x50u ||
            packed_gx_tag(record, 1) == 0x2au ||
            packed_gx_tag(record, 1) == 0x2bu ||
            packed_gx_tag(record, 1) == 0x50u ||
            packed_gx_tag(record, 2) == 0x2au ||
            packed_gx_tag(record, 2) == 0x2bu ||
            packed_gx_tag(record, 2) == 0x50u;
    if (kind != RecordKind::GxCommand) return false;
    const auto tag = record_tag(record);
    return tag == 0x2au || tag == 0x2bu || tag == 0x50u;
}

constexpr std::uint32_t diagnostic_selected_count(const Record& record)
{
    if (record_kind(record) != RecordKind::GxPacked)
        return diagnostic_record_selected(record) ? 1u : 0u;
    std::uint32_t count = 0;
    for (std::size_t index = 0; index < 3; ++index) {
        const auto tag = packed_gx_tag(record, index);
        if (tag == 0x2au || tag == 0x2bu || tag == 0x50u) ++count;
    }
    return count;
}

std::uint32_t diagnostic_crc32c_update(
    std::uint32_t state, const Record& record);

constexpr std::uint32_t diagnostic_crc32c_finalize(std::uint32_t state)
{
    return ~state;
}

#if defined(NDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION)
using HeaderSnapshotTestHook = void (*)(PacketHeader*);
extern HeaderSnapshotTestHook header_snapshot_test_hook;
using DiagnosticSnapshotTestHook = void (*)(DiagnosticEntry*);
extern DiagnosticSnapshotTestHook diagnostic_snapshot_test_hook;
using AcknowledgeTestHook = void (*)(std::byte*);
extern AcknowledgeTestHook acknowledge_test_hook;
#endif

// The caller maps [ControlPhysicalAddress, ControlPhysicalAddress +
// MappingBytes) and passes that mapping here. The consumer never acknowledges
// a packet until its verified records have been marked applied.
class Consumer {
public:
    Consumer(
        void* mapping, std::size_t mapping_size,
        bool require_diagnostic = true);

    bool initialize(std::uint32_t expected_session);
    bool begin(PacketHeader& header);
    bool begin(PacketHeader& header, std::vector<Record>& records);
    bool next_record(Record& record);
    bool record_applied();
    bool accept_all_records();
    bool acknowledge();

    std::uint32_t expected_sequence() const { return expected_sequence_; }
    std::uint32_t acknowledged_sequence() const { return acknowledged_; }
    std::uint32_t local_faults() const { return local_faults_; }
    bool pending() const { return pending_; }
    std::size_t applied_record_count() const { return applied_records_; }
    std::size_t pending_record_count() const { return pending_record_count_; }
    bool terminal_diagnostic_verified() const
    {
        return terminal_diagnostic_verified_;
    }
    std::uint32_t verified_selected_count() const
    {
        return verified_selected_count_;
    }
    std::uint32_t verified_crc32c() const { return verified_crc32c_; }

private:
    bool begin_into(
        PacketHeader& header, std::vector<Record>& records,
        bool external_records);
    bool snapshot_header(PacketHeader& header) const;
    bool snapshot_diagnostic(
        std::uint32_t sequence, DiagnosticEntry& entry) const;
    bool verify_terminal_diagnostic(
        const PacketHeader& header, std::uint32_t selected_count,
        std::uint32_t crc32c, DiagnosticEntry& verified) const;
    bool load_counter(std::size_t offset, std::uint32_t& value) const;
    bool control_session_current() const;
    bool validate_header(const PacketHeader& header) const;
    bool validate_record(const Record& record) const;
    bool fail(std::uint32_t fault);
    std::byte* slot(std::uint32_t sequence) const;

    std::byte* bytes_ = nullptr;
    std::size_t size_ = 0;
    std::uint32_t session_ = 0;
    std::uint32_t acknowledged_ = 0;
    std::uint32_t expected_sequence_ = 1;
    std::uint32_t local_faults_ = 0;
    PacketHeader pending_header_{};
    std::vector<Record> records_;
    std::size_t pending_record_count_ = 0;
    std::size_t applied_records_ = 0;
    bool record_exposed_ = false;
    bool external_records_ = false;
    bool external_records_accepted_ = false;
    bool initialized_ = false;
    bool pending_ = false;
    bool exhausted_ = false;
    bool require_diagnostic_ = true;
    bool chain_active_ = false;
    std::uint32_t chain_frame_ = 0;
    std::uint32_t chain_diagnostic_state_ = DiagnosticCrcInitial;
    std::uint32_t chain_selected_count_ = 0;
    std::uint32_t pending_diagnostic_state_ = DiagnosticCrcInitial;
    std::uint32_t pending_selected_count_ = 0;
    DiagnosticEntry pending_diagnostic_{};
    bool terminal_diagnostic_verified_ = false;
    std::uint32_t verified_selected_count_ = 0;
    std::uint32_t verified_crc32c_ = 0;
};

} // namespace nds4mister::h3d::frame_packet
