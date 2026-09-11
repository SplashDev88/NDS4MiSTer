#include "replay/Hybrid3DFramePacket.h"
#include "replay/ArmVideoEvent.h"

#include <atomic>
#include <array>
#include <cstring>
#include <limits>

namespace nds4mister::h3d::frame_packet {
namespace {

inline void device_barrier()
{
#if defined(__arm__) || defined(__aarch64__)
    __asm__ __volatile__("dmb sy" ::: "memory");
#else
    std::atomic_thread_fence(std::memory_order_seq_cst);
#endif
}

inline std::uint32_t load_word(const std::byte* address)
{
    const auto* word = reinterpret_cast<volatile const std::uint32_t*>(address);
    return *word;
}

inline std::uint64_t load_payload_beat(const std::byte* address)
{
    const auto* beat = reinterpret_cast<volatile const std::uint64_t*>(address);
    return *beat;
}

inline void load_payload_records(
    const std::byte* source, Record* target, std::size_t count)
{
#if defined(__arm__) && (defined(__ARM_NEON) || defined(__ARM_NEON__))
    // H3B1 slot payload is 16-byte aligned. Transfer two records per loop so
    // the Cortex-A9 requests four sequential 64-bit beats while paying one
    // pointer/branch update instead of the compiler's update per record.
    auto remaining = static_cast<std::uint32_t>(count);
    __asm__ __volatile__(
        "cmp %[remaining], #2\n\t"
        "blo 2f\n"
        "1:\n\t"
        "vld1.64 {d16-d19}, [%[source]]!\n\t"
        "vst1.64 {d16-d19}, [%[target]]!\n\t"
        "subs %[remaining], %[remaining], #2\n\t"
        "cmp %[remaining], #2\n\t"
        "bhs 1b\n"
        "2:\n\t"
        "cmp %[remaining], #0\n\t"
        "beq 3f\n\t"
        "vld1.64 {d16-d17}, [%[source]]\n\t"
        "vst1.64 {d16-d17}, [%[target]]\n"
        "3:"
        : [source] "+r"(source), [target] "+r"(target),
          [remaining] "+r"(remaining)
        :
        : "cc", "d16", "d17", "d18", "d19", "memory");
#else
    for (std::size_t index = 0; index < count; ++index) {
        const auto address = source + index * RecordBytes;
        const auto descriptor = load_payload_beat(address);
        target[index] = Record {
            static_cast<std::uint32_t>(descriptor),
            static_cast<std::uint32_t>(descriptor >> 32),
            load_payload_beat(address + 8),
        };
    }
#endif
}

inline void store_word(std::byte* address, std::uint32_t value)
{
    auto* word = reinterpret_cast<volatile std::uint32_t*>(address);
    *word = value;
}

constexpr std::array<std::uint32_t, 256> make_crc32c_table()
{
    std::array<std::uint32_t, 256> table{};
    for (std::uint32_t value = 0; value < table.size(); ++value) {
        std::uint32_t crc = value;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^
                ((crc & 1u) ? 0x82f63b78u : 0u);
        table[value] = crc;
    }
    return table;
}

constexpr auto Crc32cTable = make_crc32c_table();

} // namespace

static_assert(sizeof(std::uint64_t) == 8);
static_assert(alignof(std::uint64_t) == 8);
static_assert(SlotsMappingOffset % alignof(std::uint64_t) == 0);
static_assert(SlotBytes % alignof(std::uint64_t) == 0);
static_assert(HeaderBytes % alignof(std::uint64_t) == 0);
static_assert(RecordBytes % alignof(std::uint64_t) == 0);

#if defined(NDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION)
HeaderSnapshotTestHook header_snapshot_test_hook = nullptr;
AcknowledgeTestHook acknowledge_test_hook = nullptr;
DiagnosticSnapshotTestHook diagnostic_snapshot_test_hook = nullptr;
#endif

std::uint32_t diagnostic_crc32c_update(
    std::uint32_t state, const Record& record)
{
    const auto update_byte = [](std::uint32_t crc, std::uint8_t byte) {
        return (crc >> 8) ^ Crc32cTable[(crc ^ byte) & 0xffu];
    };
    const auto update_word = [&update_byte](
                                 std::uint32_t crc, std::uint32_t word) {
        for (unsigned byte = 0; byte < 4; ++byte)
            crc = update_byte(
                crc, static_cast<std::uint8_t>(word >> (byte * 8)));
        return crc;
    };

    const auto update_record = [&update_word, &update_byte](
                                   std::uint32_t crc,
                                   const Record& selected) {
        crc = update_word(crc, selected.metadata);
        crc = update_word(crc, selected.address_or_aux);
        for (unsigned byte = 0; byte < 8; ++byte)
            crc = update_byte(
                crc, static_cast<std::uint8_t>(
                         selected.data >> (byte * 8)));
        return crc;
    };
    if (record_kind(record) == RecordKind::GxPacked) {
        for (std::size_t index = 0; index < 3; ++index) {
            const auto command = unpack_gx_command(record, index);
            if (diagnostic_record_selected(command))
                state = update_record(state, command);
        }
        return state;
    }
    state = update_record(state, record);
    return state;
}

Consumer::Consumer(
    void* mapping, std::size_t mapping_size, bool require_diagnostic)
    : bytes_(static_cast<std::byte*>(mapping)), size_(mapping_size),
      require_diagnostic_(require_diagnostic)
{
}

bool Consumer::initialize(std::uint32_t expected_session)
{
    if (!bytes_ || size_ < MappingBytes ||
        reinterpret_cast<std::uintptr_t>(bytes_) %
            alignof(std::uint64_t) != 0)
        return fail(FaultBadMapping);
    if (expected_session == 0) return fail(FaultBadSession);

    session_ = expected_session;
    if (!control_session_current()) return fail(FaultBadSession);

    std::uint32_t producer = 0;
    std::uint32_t acknowledged = 0;
    if (!load_counter(ControlProducerOffset, producer) ||
        !load_counter(ControlAcknowledgeOffset, acknowledged))
        return fail(FaultBadControl);
    if (producer < acknowledged || producer - acknowledged > SlotCount ||
        acknowledged == std::numeric_limits<std::uint32_t>::max())
        return fail(FaultBadControl);

    acknowledged_ = acknowledged;
    expected_sequence_ = acknowledged + 1;
    initialized_ = true;
    return true;
}

bool Consumer::begin(PacketHeader& output)
{
    return begin_into(output, records_, false);
}

bool Consumer::begin(
    PacketHeader& output, std::vector<Record>& output_records)
{
    if (&output_records == &records_) return false;
    return begin_into(output, output_records, true);
}

bool Consumer::begin_into(
    PacketHeader& output, std::vector<Record>& output_records,
    bool external_records)
{
    output_records.clear();
    const auto reject = [this, &output_records](std::uint32_t fault) {
        output_records.clear();
        return fail(fault);
    };
    if (!initialized_ || local_faults_ != 0 || pending_ || exhausted_)
        return false;
    terminal_diagnostic_verified_ = false;
    verified_selected_count_ = 0;
    verified_crc32c_ = 0;
    if (!control_session_current()) return reject(FaultBadSession);

    std::uint32_t producer = 0;
    std::uint32_t shared_acknowledged = 0;
    if (!load_counter(ControlProducerOffset, producer) ||
        !load_counter(ControlAcknowledgeOffset, shared_acknowledged))
        return reject(FaultBadControl);
    if (shared_acknowledged != acknowledged_ || producer < acknowledged_ ||
        producer - acknowledged_ > SlotCount)
        return reject(FaultSequence);
    if (producer < expected_sequence_) return false;

    auto* slot_bytes = slot(expected_sequence_);
    PacketHeader first{};
    if (!snapshot_header(first)) return reject(FaultTornHeader);
    if (first.commit_reserved != 0 ||
        first.commit_sequence != expected_sequence_)
        return reject(FaultTornHeader);
    if (first.session != session_) return reject(FaultBadSession);
    if (!validate_header(first)) return reject(FaultBadHeader);

    output_records.resize(first.record_count);
    const auto* payload = slot_bytes + HeaderBytes;
    load_payload_records(
        payload, output_records.data(), output_records.size());
    device_barrier();

#if defined(NDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION)
    if (header_snapshot_test_hook)
        header_snapshot_test_hook(reinterpret_cast<PacketHeader*>(slot_bytes));
#endif

    PacketHeader second{};
    if (!snapshot_header(second) ||
        std::memcmp(&first, &second, sizeof(first)) != 0)
        return reject(FaultTornHeader);
    if (!control_session_current()) return reject(FaultBadSession);

    auto diagnostic_state = chain_active_ ? chain_diagnostic_state_ :
                                            DiagnosticCrcInitial;
    auto selected_count = chain_active_ ? chain_selected_count_ : 0u;
    for (const auto& record : output_records) {
        if (!validate_record(record)) return reject(FaultBadRecord);
        if (require_diagnostic_ && diagnostic_record_selected(record)) {
            const auto added = diagnostic_selected_count(record);
            if (added > std::numeric_limits<std::uint32_t>::max() -
                            selected_count)
                return reject(FaultBadDiagnostic);
            diagnostic_state =
                diagnostic_crc32c_update(diagnostic_state, record);
            selected_count += added;
        }
    }

    DiagnosticEntry verified{};
    const bool terminal = first.flags == FlagFrameEnd;
    const auto crc32c = diagnostic_crc32c_finalize(diagnostic_state);
    if (require_diagnostic_ && terminal && !verify_terminal_diagnostic(
                        first, selected_count, crc32c, verified))
        return reject(FaultBadDiagnostic);
    if (!control_session_current()) return reject(FaultBadSession);

    pending_header_ = first;
    pending_diagnostic_state_ = diagnostic_state;
    pending_selected_count_ = selected_count;
    pending_diagnostic_ = verified;
    terminal_diagnostic_verified_ = require_diagnostic_ && terminal;
    verified_selected_count_ =
        require_diagnostic_ && terminal ? selected_count : 0;
    verified_crc32c_ = require_diagnostic_ && terminal ? crc32c : 0;
    output = first;
    pending_record_count_ = output_records.size();
    applied_records_ = 0;
    record_exposed_ = false;
    external_records_ = external_records;
    external_records_accepted_ = false;
    pending_ = true;
    return true;
}

bool Consumer::next_record(Record& output)
{
    if (!pending_ || external_records_ ||
        applied_records_ >= pending_record_count_)
        return false;
    output = records_[applied_records_];
    record_exposed_ = true;
    return true;
}

bool Consumer::record_applied()
{
    if (!pending_ || external_records_ || !record_exposed_ ||
        applied_records_ >= pending_record_count_)
        return false;
    ++applied_records_;
    record_exposed_ = false;
    return true;
}

bool Consumer::accept_all_records()
{
    if (!pending_ || !external_records_ || record_exposed_ ||
        external_records_accepted_ || applied_records_ != 0)
        return false;
    applied_records_ = pending_record_count_;
    external_records_accepted_ = true;
    return true;
}

bool Consumer::acknowledge()
{
    if (!pending_ || record_exposed_ ||
        applied_records_ != pending_record_count_)
        return false;
    if (!control_session_current()) return fail(FaultBadSession);

    std::uint32_t producer = 0;
    std::uint32_t shared_acknowledged = 0;
    if (!load_counter(ControlProducerOffset, producer) ||
        !load_counter(ControlAcknowledgeOffset, shared_acknowledged))
        return fail(FaultBadControl);
    if (shared_acknowledged != acknowledged_ ||
        producer < pending_header_.packet_sequence ||
        producer - acknowledged_ > SlotCount)
        return fail(FaultSequence);

    PacketHeader final_snapshot{};
    if (!snapshot_header(final_snapshot) ||
        std::memcmp(
            &pending_header_, &final_snapshot, sizeof(pending_header_)) != 0)
        return fail(FaultTornHeader);
    if (require_diagnostic_ &&
        pending_header_.flags == FlagFrameEnd) {
        DiagnosticEntry verified{};
        if (!verify_terminal_diagnostic(
                pending_header_, pending_selected_count_,
                diagnostic_crc32c_finalize(pending_diagnostic_state_),
                verified) ||
            std::memcmp(
                &pending_diagnostic_, &verified,
                sizeof(pending_diagnostic_)) != 0)
            return fail(FaultBadDiagnostic);
    }
#if defined(NDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION)
    if (acknowledge_test_hook) acknowledge_test_hook(bytes_);
#endif
    // The producer/header reads above are not an ownership fence. Re-snapshot
    // the control session immediately before the sole shared acknowledgement.
    if (!control_session_current()) return fail(FaultBadSession);

    // Publish {reserved=0, last fully applied packet sequence}. The low word
    // is the ownership transfer and is therefore written last.
    store_word(bytes_ + ControlAcknowledgeOffset + 4, 0);
    device_barrier();
    store_word(
        bytes_ + ControlAcknowledgeOffset,
        pending_header_.packet_sequence);
    device_barrier();

    acknowledged_ = pending_header_.packet_sequence;
    const bool terminal =
        acknowledged_ == std::numeric_limits<std::uint32_t>::max();
    if (pending_header_.flags == FlagContinuation) {
        if (require_diagnostic_) {
            chain_diagnostic_state_ = pending_diagnostic_state_;
            chain_selected_count_ = pending_selected_count_;
        }
        if (!chain_active_) {
            chain_active_ = true;
            chain_frame_ = pending_header_.frame;
        }
    } else {
        chain_active_ = false;
        chain_frame_ = 0;
        if (require_diagnostic_) {
            chain_diagnostic_state_ = DiagnosticCrcInitial;
            chain_selected_count_ = 0;
        }
    }

    pending_ = false;
    records_.clear();
    pending_record_count_ = 0;
    applied_records_ = 0;
    record_exposed_ = false;
    external_records_ = false;
    external_records_accepted_ = false;
    if (terminal) {
        exhausted_ = true;
    } else {
        expected_sequence_ = acknowledged_ + 1;
    }
    return true;
}

bool Consumer::snapshot_header(PacketHeader& output) const
{
    if (!bytes_) return false;
    const auto* source = slot(expected_sequence_);
    std::uint32_t words[HeaderBytes / 4]{};
    for (std::size_t index = 0; index < HeaderBytes / 4; ++index)
        words[index] = load_word(source + index * 4);
    device_barrier();
    std::memcpy(&output, words, sizeof(output));
    return true;
}

bool Consumer::snapshot_diagnostic(
    std::uint32_t sequence, DiagnosticEntry& output) const
{
    if (!bytes_ || sequence == 0) return false;
    const auto index = (sequence - 1) & (DiagnosticEntryCount - 1);
    const auto offset = DiagnosticMappingOffset +
        std::size_t(index) * DiagnosticEntryBytes;
    if (offset + sizeof(output) > size_) return false;
    std::uint32_t words[DiagnosticEntryBytes / 4]{};
    for (std::size_t word = 0; word < DiagnosticEntryBytes / 4; ++word)
        words[word] = load_word(bytes_ + offset + word * 4);
    device_barrier();
    std::memcpy(&output, words, sizeof(output));
    return true;
}

bool Consumer::verify_terminal_diagnostic(
    const PacketHeader& header, std::uint32_t selected_count,
    std::uint32_t crc32c, DiagnosticEntry& verified) const
{
    DiagnosticEntry first{};
    if (!snapshot_diagnostic(header.packet_sequence, first)) return false;
    if (first.magic != DiagnosticMagic ||
        first.version != DiagnosticVersion ||
        first.entry_size != DiagnosticSize || first.session != session_ ||
        first.terminal_sequence != header.packet_sequence ||
        first.frame != header.frame || first.selected_count != selected_count ||
        first.crc32c != crc32c ||
        first.commit_sequence != header.packet_sequence)
        return false;
#if defined(NDS4MISTER_H3D_FRAME_PACKET_TEST_INSTRUMENTATION)
    if (diagnostic_snapshot_test_hook) {
        const auto index =
            (header.packet_sequence - 1) & (DiagnosticEntryCount - 1);
        diagnostic_snapshot_test_hook(reinterpret_cast<DiagnosticEntry*>(
            bytes_ + DiagnosticMappingOffset +
            std::size_t(index) * DiagnosticEntryBytes));
    }
#endif
    DiagnosticEntry second{};
    if (!snapshot_diagnostic(header.packet_sequence, second) ||
        std::memcmp(&first, &second, sizeof(first)) != 0)
        return false;
    verified = first;
    return true;
}

bool Consumer::load_counter(std::size_t offset, std::uint32_t& value) const
{
    if (!bytes_ || offset + 8 > size_) return false;
    const auto high_before = load_word(bytes_ + offset + 4);
    const auto low = load_word(bytes_ + offset);
    const auto high_after = load_word(bytes_ + offset + 4);
    device_barrier();
    if (high_before != 0 || high_after != 0) return false;
    value = low;
    return true;
}

bool Consumer::control_session_current() const
{
    if (!bytes_ || ControlSessionOffset + 8 > size_) return false;
    const auto before = load_word(bytes_ + ControlSessionOffset);
    const auto reserved_before = load_word(bytes_ + ControlSessionOffset + 4);
    device_barrier();
    const auto after = load_word(bytes_ + ControlSessionOffset);
    const auto reserved_after = load_word(bytes_ + ControlSessionOffset + 4);
    device_barrier();
    return before == session_ && after == session_ &&
        reserved_before == 0 && reserved_after == 0;
}

bool Consumer::validate_header(const PacketHeader& header) const
{
    const auto expected_slot = (expected_sequence_ - 1) & (SlotCount - 1);
    const bool valid_flag = header.flags == FlagContinuation ||
        header.flags == FlagFrameEnd;
    if (header.magic != Magic || header.version != Version ||
        header.header_size != HeaderSize || header.session != session_ ||
        header.session_reserved != 0 ||
        header.packet_sequence != expected_sequence_ ||
        header.packet_sequence_reserved != 0 || !valid_flag ||
        header.payload_bytes > MaxPayloadBytes ||
        (header.payload_bytes % RecordBytes) != 0 ||
        header.record_count > MaxRecordCount ||
        header.payload_bytes != header.record_count * RecordBytes ||
        header.slot_index != expected_slot || header.slot_reserved != 0 ||
        header.reserved6_low != 0 || header.reserved6_high != 0 ||
        header.commit_sequence != expected_sequence_ ||
        header.commit_reserved != 0)
        return false;
    if (chain_active_ && header.frame != chain_frame_) return false;
    return true;
}

bool Consumer::validate_record(const Record& record) const
{
    const auto kind = record_kind(record);
    if (kind == RecordKind::GxPacked) return true;
    if ((record.metadata & 0xc0000000u) != 0 ||
        (!record_has_scanline(record) &&
         (record.metadata & RecordScanlineMask) != 0) ||
        (record_has_scanline(record) && record_scanline(record) >= 263))
        return false;
    if (kind != RecordKind::GxCommand &&
        kind != RecordKind::GxRegister &&
        kind != RecordKind::VramWrite &&
        kind != RecordKind::VramMap &&
        kind != RecordKind::Gpu2DRegister &&
        kind != RecordKind::PaletteWrite &&
        kind != RecordKind::OamWrite &&
        kind != RecordKind::HBlank)
        return false;
    if ((kind == RecordKind::Gpu2DRegister ||
         kind == RecordKind::PaletteWrite ||
         kind == RecordKind::OamWrite ||
         kind == RecordKind::HBlank) &&
        !nds4mister::arm_video::validate_record(record))
        return false;
    if (kind == RecordKind::VramWrite && record_byte_enable(record) == 0)
        return false;
    return true;
}

bool Consumer::fail(std::uint32_t fault)
{
    local_faults_ |= fault;
    return false;
}

std::byte* Consumer::slot(std::uint32_t sequence) const
{
    const auto index = (sequence - 1) & (SlotCount - 1);
    return bytes_ + SlotsMappingOffset + std::size_t(index) * SlotBytes;
}

} // namespace nds4mister::h3d::frame_packet
