#include "replay/Hybrid3DFramePacket.h"

#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

using namespace nds4mister::h3d::frame_packet;

namespace {

[[noreturn]] void die(const std::string& message)
{
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
}

struct Fixture {
    int file = -1;
    std::byte* bytes = nullptr;
    std::string path;
    std::uint32_t session = 7;
    std::uint32_t diagnostic_state = DiagnosticCrcInitial;
    std::uint32_t diagnostic_count = 0;

    Fixture()
    {
        std::array<char, 64> pattern{};
        std::strcpy(pattern.data(), "/tmp/h3d-frame-packet.XXXXXX");
        file = mkstemp(pattern.data());
        if (file < 0) die("mkstemp failed");
        path = pattern.data();
        if (ftruncate(file, static_cast<off_t>(MappingBytes)) != 0)
            die("ftruncate failed");
        auto* mapping = mmap(
            nullptr, MappingBytes, PROT_READ | PROT_WRITE, MAP_SHARED,
            file, 0);
        if (mapping == MAP_FAILED) die("mmap failed");
        bytes = static_cast<std::byte*>(mapping);
        std::memset(bytes, 0, MappingBytes);
        word(ControlSessionOffset) = session;
    }

    ~Fixture()
    {
        if (bytes) munmap(bytes, MappingBytes);
        if (file >= 0) close(file);
        if (!path.empty()) unlink(path.c_str());
    }

    Fixture(const Fixture&) = delete;
    Fixture& operator=(const Fixture&) = delete;

    std::uint32_t& word(std::size_t offset)
    {
        return *reinterpret_cast<std::uint32_t*>(bytes + offset);
    }

    PacketHeader* header(std::uint32_t sequence)
    {
        const auto index = (sequence - 1) & (SlotCount - 1);
        return reinterpret_cast<PacketHeader*>(
            bytes + SlotsMappingOffset + std::size_t(index) * SlotBytes);
    }

    DiagnosticEntry* diagnostic(std::uint32_t sequence)
    {
        const auto index = (sequence - 1) & (DiagnosticEntryCount - 1);
        return reinterpret_cast<DiagnosticEntry*>(
            bytes + DiagnosticMappingOffset +
            std::size_t(index) * DiagnosticEntryBytes);
    }

    void publish(
        std::uint32_t sequence, std::uint32_t frame, std::uint32_t flags,
        const std::vector<Record>& records)
    {
        if (records.size() > MaxRecordCount) die("fixture packet too large");
        auto* packet = header(sequence);
        *packet = {};
        packet->magic = Magic;
        packet->version = Version;
        packet->header_size = HeaderSize;
        packet->session = session;
        packet->packet_sequence = sequence;
        packet->frame = frame;
        packet->flags = flags;
        packet->payload_bytes =
            static_cast<std::uint32_t>(records.size() * RecordBytes);
        packet->record_count = static_cast<std::uint32_t>(records.size());
        packet->slot_index = (sequence - 1) & (SlotCount - 1);
        if (!records.empty())
            std::memcpy(packet + 1, records.data(), packet->payload_bytes);
        for (const auto& record : records) {
            if (!diagnostic_record_selected(record)) continue;
            diagnostic_state =
                diagnostic_crc32c_update(diagnostic_state, record);
            diagnostic_count += diagnostic_selected_count(record);
        }
        if (flags == FlagFrameEnd) {
            auto* verifier = diagnostic(sequence);
            *verifier = {};
            verifier->magic = DiagnosticMagic;
            verifier->version = DiagnosticVersion;
            verifier->entry_size = DiagnosticSize;
            verifier->session = session;
            verifier->terminal_sequence = sequence;
            verifier->frame = frame;
            verifier->selected_count = diagnostic_count;
            verifier->crc32c =
                diagnostic_crc32c_finalize(diagnostic_state);
            verifier->commit_sequence = sequence;
            diagnostic_state = DiagnosticCrcInitial;
            diagnostic_count = 0;
        }
        packet->commit_sequence = sequence;
        word(ControlProducerOffset) = sequence;
    }
};

Record make_record(RecordKind kind, std::uint32_t ordinal)
{
    Record record{};
    record.metadata = make_record_metadata(
        kind, static_cast<std::uint8_t>(ordinal),
        kind == RecordKind::VramWrite ? 0x0f : 0);
    record.address_or_aux = 0x06000000u + ordinal * 4;
    record.data = 0x1234000000000000ull | ordinal;
    return record;
}

void test_known_rtl_crc()
{
    const auto rtl_record = [](std::uint32_t ordinal, RecordKind kind,
                                std::uint8_t tag, std::uint32_t address) {
        Record record{};
        record.metadata = make_record_metadata(kind, tag, 0x0f);
        record.address_or_aux = address;
        record.data =
            (std::uint64_t {0xd0000000u | ordinal} << 32) |
            (0xc0000000u | ordinal);
        return record;
    };
    const std::array<Record, 6> records{
        rtl_record(1, RecordKind::VramWrite, 1, 0x06000000),
        rtl_record(2, RecordKind::VramMap, 0, 0x04000240),
        rtl_record(3, RecordKind::GxCommand, 0x2a, 0),
        rtl_record(4, RecordKind::GxCommand, 0x2b, 0),
        rtl_record(5, RecordKind::GxRegister, 1, 0x04000060),
        rtl_record(6, RecordKind::GxCommand, 0x50, 0),
    };
    auto state = DiagnosticCrcInitial;
    for (const auto& record : records) {
        if (!diagnostic_record_selected(record))
            die("RTL known-vector record was not selected");
        state = diagnostic_crc32c_update(state, record);
    }
    if (diagnostic_crc32c_finalize(state) != 0x441cbd61u)
        die("RTL known-vector CRC32C changed");
}

void apply_all(Consumer& consumer, const std::vector<Record>& expected);

void test_packed_gx_record()
{
    const Record first{
        make_record_metadata(RecordKind::GxCommand, 0x2a, 0),
        0, 0x11111111u};
    const Record second{
        make_record_metadata(RecordKind::GxCommand, 0x23, 0),
        0, 0x22222222u};
    const Record third{
        make_record_metadata(RecordKind::GxCommand, 0x50, 0),
        0, 0x33333333u};
    const auto packed = pack_gx_commands(first, second, third);
    if (record_kind(packed) != RecordKind::GxPacked ||
        diagnostic_selected_count(packed) != 2)
        die("packed GX metadata changed");
    const std::array<Record, 3> expected{first, second, third};
    for (std::size_t index = 0; index < expected.size(); ++index) {
        const auto unpacked = unpack_gx_command(packed, index);
        if (std::memcmp(&unpacked, &expected[index], sizeof(unpacked)) != 0)
            die("packed GX command order/data changed");
    }
    auto expected_crc = DiagnosticCrcInitial;
    expected_crc = diagnostic_crc32c_update(expected_crc, first);
    expected_crc = diagnostic_crc32c_update(expected_crc, third);
    if (diagnostic_crc32c_update(DiagnosticCrcInitial, packed) !=
        expected_crc)
        die("packed GX diagnostic expansion changed");

    Fixture fixture;
    fixture.publish(1, 26, FlagFrameEnd, {packed});
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session))
        die("packed GX consumer init failed");
    PacketHeader header{};
    if (!consumer.begin(header) ||
        consumer.verified_selected_count() != 2)
        die("packed GX packet rejected");
    apply_all(consumer, {packed});
}

void apply_all(Consumer& consumer, const std::vector<Record>& expected)
{
    if (consumer.acknowledge()) die("packet acknowledged before apply");
    for (const auto& wanted : expected) {
        Record actual{};
        if (!consumer.next_record(actual)) die("ordered record missing");
        if (std::memcmp(&actual, &wanted, sizeof(actual)) != 0)
            die("ordered record changed");
        if (consumer.acknowledge())
            die("packet acknowledged with exposed record unapplied");
        if (!consumer.record_applied()) die("record apply rejected");
    }
    Record extra{};
    if (consumer.next_record(extra)) die("extra ordered record exposed");
    if (!consumer.acknowledge()) die("fully applied packet not acknowledged");
}

void test_one_frame()
{
    Fixture fixture;
    const std::vector<Record> records{
        make_record(RecordKind::GxCommand, 1),
        make_record(RecordKind::GxRegister, 2),
        make_record(RecordKind::VramWrite, 3),
        make_record(RecordKind::VramMap, 4),
    };
    fixture.publish(1, 23, FlagFrameEnd, records);
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("one-frame init failed");
    PacketHeader header{};
    if (!consumer.begin(header) || header.frame != 23 ||
        header.record_count != records.size())
        die("one-frame packet rejected");
    if (!consumer.terminal_diagnostic_verified() ||
        consumer.verified_selected_count() != 2 ||
        consumer.verified_crc32c() != fixture.diagnostic(1)->crc32c)
        die("one-frame diagnostic rejected");
    apply_all(consumer, records);
    if (fixture.word(ControlAcknowledgeOffset) != 1 ||
        fixture.word(ControlAcknowledgeOffset + 4) != 0)
        die("one-frame global acknowledgement incorrect");
}

void test_direct_packet_copy()
{
    Fixture fixture;
    const std::vector<Record> records{
        make_record(RecordKind::GxCommand, 1),
        make_record(RecordKind::VramWrite, 2),
        make_record(RecordKind::GxCommand, 3),
    };
    fixture.publish(1, 24, FlagFrameEnd, records);
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("direct-copy init failed");
    PacketHeader header{};
    std::vector<Record> copied{{0xffffffffu, 0xffffffffu, ~0ull}};
    if (!consumer.begin(header, copied) || header.frame != 24 ||
        copied.size() != records.size() ||
        std::memcmp(copied.data(), records.data(),
                    records.size() * sizeof(Record)) != 0)
        die("direct-copy packet changed");
    if (consumer.acknowledge())
        die("direct-copy packet acknowledged before batch apply");
    Record record{};
    if (consumer.next_record(record) || consumer.record_applied())
        die("direct-copy packet exposed through ordered API");
    if (!consumer.accept_all_records() || consumer.accept_all_records())
        die("direct-copy batch apply state changed");
    if (!consumer.acknowledge() ||
        fixture.word(ControlAcknowledgeOffset) != 1)
        die("direct-copy acknowledgement failed");

    Fixture torn_fixture;
    torn_fixture.publish(1, 25, FlagFrameEnd, records);
    Consumer torn(torn_fixture.bytes, MappingBytes);
    if (!torn.initialize(torn_fixture.session))
        die("direct-copy torn init failed");
    copied = records;
    header_snapshot_test_hook = [](PacketHeader* packet) {
        ++packet->frame;
    };
    const bool accepted = torn.begin(header, copied);
    header_snapshot_test_hook = nullptr;
    if (accepted || !copied.empty() ||
        (torn.local_faults() & FaultTornHeader) == 0 ||
        torn_fixture.word(ControlAcknowledgeOffset) != 0)
        die("direct-copy torn packet exposed or acknowledged");
}

void test_misaligned_mapping()
{
    std::vector<std::byte> storage(MappingBytes + 16);
    const auto aligned =
        (reinterpret_cast<std::uintptr_t>(storage.data()) + 7u) &
        ~std::uintptr_t(7u);
    auto* misaligned = reinterpret_cast<void*>(aligned + 4u);
    Consumer consumer(misaligned, MappingBytes);
    if (consumer.initialize(1) ||
        (consumer.local_faults() & FaultBadMapping) == 0)
        die("misaligned payload mapping accepted");
}

void test_continuation_chain()
{
    Fixture fixture;
    const std::vector<Record> first{
        make_record(RecordKind::VramWrite, 1),
        make_record(RecordKind::GxCommand, 2),
    };
    const std::vector<Record> last{make_record(RecordKind::GxCommand, 3)};
    fixture.publish(1, 44, FlagContinuation, first);
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("CONT init failed");
    PacketHeader header{};
    if (!consumer.begin(header)) die("CONT packet rejected");
    apply_all(consumer, first);

    fixture.publish(2, 44, FlagFrameEnd, last);
    if (!consumer.begin(header)) die("CONT terminal packet rejected");
    std::uint32_t expected_state = DiagnosticCrcInitial;
    std::uint32_t expected_count = 0;
    for (const auto& packet : {first, last}) {
        for (const auto& record : packet) {
            if (!diagnostic_record_selected(record)) continue;
            expected_state = diagnostic_crc32c_update(expected_state, record);
            ++expected_count;
        }
    }
    if (!consumer.terminal_diagnostic_verified() ||
        consumer.verified_selected_count() != expected_count ||
        consumer.verified_crc32c() !=
            diagnostic_crc32c_finalize(expected_state))
        die("CONT diagnostic accumulation changed");
    apply_all(consumer, last);
    if (fixture.word(ControlAcknowledgeOffset) != 2)
        die("CONT chain acknowledgement incorrect");
}

void test_bad_diagnostic()
{
    Fixture fixture;
    fixture.publish(
        1, 8, FlagFrameEnd,
        {make_record(RecordKind::VramWrite, 1)});
    fixture.diagnostic(1)->crc32c ^= 1u;
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session))
        die("diagnostic mismatch init failed");
    PacketHeader header{};
    if (consumer.begin(header) ||
        (consumer.local_faults() & FaultBadDiagnostic) == 0 ||
        fixture.word(ControlAcknowledgeOffset) != 0)
        die("diagnostic mismatch was exposed or acknowledged");

    Fixture torn_fixture;
    torn_fixture.publish(
        1, 9, FlagFrameEnd,
        {make_record(RecordKind::VramMap, 2)});
    Consumer torn(torn_fixture.bytes, MappingBytes);
    if (!torn.initialize(torn_fixture.session))
        die("torn diagnostic init failed");
    diagnostic_snapshot_test_hook = [](DiagnosticEntry* entry) {
        entry->selected_count ^= 1u;
    };
    const bool accepted = torn.begin(header);
    diagnostic_snapshot_test_hook = nullptr;
    if (accepted || (torn.local_faults() & FaultBadDiagnostic) == 0 ||
        torn_fixture.word(ControlAcknowledgeOffset) != 0)
        die("torn diagnostic was exposed or acknowledged");

    Fixture changed_fixture;
    const std::vector<Record> changed_records{
        make_record(RecordKind::VramWrite, 3)};
    changed_fixture.publish(1, 10, FlagFrameEnd, changed_records);
    Consumer changed(changed_fixture.bytes, MappingBytes);
    if (!changed.initialize(changed_fixture.session) ||
        !changed.begin(header))
        die("changed diagnostic packet rejected before apply");
    Record record{};
    if (!changed.next_record(record) || !changed.record_applied())
        die("changed diagnostic record apply failed");
    changed_fixture.diagnostic(1)->crc32c ^= 1u;
    if (changed.acknowledge() ||
        (changed.local_faults() & FaultBadDiagnostic) == 0 ||
        changed_fixture.word(ControlAcknowledgeOffset) != 0)
        die("diagnostic change before ACK was accepted");
}

void test_torn_header()
{
    Fixture fixture;
    fixture.publish(
        1, 8, FlagFrameEnd,
        {make_record(RecordKind::GxCommand, 1)});
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("torn init failed");
    header_snapshot_test_hook = [](PacketHeader* header) {
        ++header->frame;
    };
    PacketHeader header{};
    const bool accepted = consumer.begin(header);
    header_snapshot_test_hook = nullptr;
    if (accepted || (consumer.local_faults() & FaultTornHeader) == 0)
        die("torn header accepted");
    if (fixture.word(ControlAcknowledgeOffset) != 0)
        die("torn header was acknowledged");
}

void test_stale_session()
{
    Fixture fixture;
    fixture.publish(
        1, 8, FlagFrameEnd,
        {make_record(RecordKind::GxCommand, 1)});
    fixture.header(1)->session = fixture.session + 1;
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("stale init failed");
    PacketHeader header{};
    if (consumer.begin(header) ||
        (consumer.local_faults() & FaultBadSession) == 0 ||
        fixture.word(ControlAcknowledgeOffset) != 0)
        die("stale packet session accepted");
}

void test_session_change_before_ack()
{
    Fixture fixture;
    const std::vector<Record> records{
        make_record(RecordKind::GxCommand, 1)};
    fixture.publish(1, 8, FlagFrameEnd, records);
    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session))
        die("ack-session init failed");
    PacketHeader header{};
    if (!consumer.begin(header)) die("ack-session packet rejected");
    Record record{};
    if (!consumer.next_record(record) || !consumer.record_applied())
        die("ack-session record apply failed");
    acknowledge_test_hook = [](std::byte* bytes) {
        auto* session = reinterpret_cast<std::uint32_t*>(
            bytes + ControlSessionOffset);
        session[0] = session[0] + 1;
        session[1] = 1;
    };
    const bool acknowledged = consumer.acknowledge();
    acknowledge_test_hook = nullptr;
    if (acknowledged || (consumer.local_faults() & FaultBadSession) == 0 ||
        fixture.word(ControlAcknowledgeOffset) != 0 ||
        fixture.word(ControlAcknowledgeOffset + 4) != 0)
        die("changed control session was acknowledged");
}

void test_malformed_packets()
{
    {
        Fixture fixture;
        fixture.publish(
            1, 8, FlagFrameEnd,
            {make_record(RecordKind::GxCommand, 1)});
        fixture.header(1)->payload_bytes = RecordBytes - 1;
        Consumer consumer(fixture.bytes, MappingBytes);
        if (!consumer.initialize(fixture.session)) die("length init failed");
        PacketHeader header{};
        if (consumer.begin(header) ||
            (consumer.local_faults() & FaultBadHeader) == 0)
            die("malformed packet length accepted");
    }
    {
        Fixture fixture;
        auto malformed = make_record(RecordKind::GxCommand, 1);
        malformed.metadata = 0xff;
        fixture.publish(1, 8, FlagFrameEnd, {malformed});
        Consumer consumer(fixture.bytes, MappingBytes);
        if (!consumer.initialize(fixture.session)) die("kind init failed");
        PacketHeader header{};
        if (consumer.begin(header) ||
            (consumer.local_faults() & FaultBadRecord) == 0)
            die("unknown record kind accepted");
    }
    {
        Fixture fixture;
        fixture.publish(
            1, 8, FlagFrameEnd,
            {make_record(RecordKind::GxCommand, 1)});
        fixture.header(1)->reserved6_high = 1;
        Consumer consumer(fixture.bytes, MappingBytes);
        if (!consumer.initialize(fixture.session))
            die("reserved-word init failed");
        PacketHeader header{};
        if (consumer.begin(header) ||
            (consumer.local_faults() & FaultBadHeader) == 0)
            die("reserved header word accepted");
    }
}

void test_full_four_slot_order()
{
    Fixture fixture;
    std::array<std::vector<Record>, SlotCount> packets{};
    for (std::uint32_t sequence = 1; sequence <= SlotCount; ++sequence) {
        packets[sequence - 1] = {
            make_record(RecordKind::GxCommand, sequence)};
        fixture.publish(
            sequence, 100 + sequence, FlagFrameEnd,
            packets[sequence - 1]);
    }

    Consumer consumer(fixture.bytes, MappingBytes);
    if (!consumer.initialize(fixture.session)) die("four-slot init failed");
    for (std::uint32_t sequence = 1; sequence <= SlotCount; ++sequence) {
        PacketHeader header{};
        if (!consumer.begin(header) ||
            header.packet_sequence != sequence ||
            header.slot_index != sequence - 1)
            die("four-slot packet order changed");
        apply_all(consumer, packets[sequence - 1]);
        if (fixture.word(ControlAcknowledgeOffset) != sequence)
            die("four-slot acknowledgement order changed");
    }
}

} // namespace

int main()
{
    test_known_rtl_crc();
    test_packed_gx_record();
    test_one_frame();
    test_direct_packet_copy();
    test_misaligned_mapping();
    test_continuation_chain();
    test_bad_diagnostic();
    test_torn_header();
    test_stale_session();
    test_session_change_before_ack();
    test_malformed_packets();
    test_full_four_slot_order();
    std::cout <<
        "H3D frame-packet consumer test\n"
        "known_rtl_crc32c: passed\n"
        "packed_gx_record: passed\n"
        "one_frame: passed\n"
        "direct_packet_copy: passed\n"
        "misaligned_mapping: passed\n"
        "continuation_chain: passed\n"
        "diagnostic_match_torn_continuation: passed\n"
        "torn_header: passed\n"
        "stale_session: passed\n"
        "session_change_before_ack: passed\n"
        "malformed_length_kind_reserved: passed\n"
        "full_four_slot_order: passed\n";
}
