#include "replay/Hybrid3DAbi.h"

#include <array>
#include <cstdlib>
#include <iostream>
#include <vector>

using namespace nds4mister::h3d;

namespace {
[[noreturn]] void die(const char* message)
{
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
}

struct Fixture {
    static constexpr std::uint32_t Entries = 128;
    std::vector<std::byte> bytes;
    Header* header;
    Event* events;

    explicit Fixture(std::uint32_t session = 7)
        : bytes(HeaderSize + Entries * EventSize),
          header(reinterpret_cast<Header*>(bytes.data())),
          events(reinterpret_cast<Event*>(bytes.data() + HeaderSize))
    {
        *header = {};
        header->magic = Magic;
        header->version = Version;
        header->header_size = HeaderSize;
        header->fpga_session = session;
        header->entry_count = Entries;
        header->quiesce_request = session;
        header->quiesce_ack = session;
    }

    void publish(Event event)
    {
        const auto index = (event.sequence - 1) & (Entries - 1);
        events[index] = {};
        std::memcpy(&events[index], &event, offsetof(Event, sequence));
        store_counter(
            &events[index].sequence, &events[index].sequence_reserved,
            event.sequence);
        store_counter(
            &header->producer_sequence,
            &header->producer_sequence_reserved, event.sequence);
    }
};

Event make_event(std::uint32_t sequence, EventType type)
{
    Event event{};
    event.address = type == EventType::Arm9GpuIoWrite
        ? 0x04000400u : 0x06000120u;
    event.data = 0x12340000u | static_cast<std::uint32_t>(sequence);
    event.frame = 23;
    event.metadata = make_metadata(
        type, type == EventType::Arm7VramWrite,
        AccessWidth::Word, 0x0f);
    const auto timestamp = std::uint64_t(1000) + sequence;
    event.timestamp_low = static_cast<std::uint32_t>(timestamp);
    event.timestamp_high = static_cast<std::uint32_t>(timestamp >> 32);
    event.sequence = sequence;
    return event;
}
}

int main()
{
    static_assert(pack_melonds_pixel(0x1f3f3f3fu) == 0x007fffffu);
    static_assert(pack_melonds_pixel(0) == 0);

    {
        alignas(16) std::array<std::uint32_t, 16> first{};
        alignas(16) std::array<std::uint32_t, 16> second{};
        for (std::size_t lane = 0; lane < first.size(); ++lane) {
            first[lane] = 0x10203040u ^
                static_cast<std::uint32_t>(lane * 0x01010101u);
            second[lane] = first[lane];
        }
        if (!equal_pixel_block_16(first.data(), second.data()))
            die("equal 16-pixel blocks compared different");
        for (std::size_t lane = 0; lane < first.size(); ++lane) {
            second[lane] ^= 1u;
            if (equal_pixel_block_16(first.data(), second.data()))
                die("changed 16-pixel block compared equal");
            second[lane] ^= 1u;
        }
    }

    {
        std::uint32_t low = 0x12345678u;
        std::uint32_t high = 0;
        std::uint32_t value = 0;
        reset_device_barrier_test_count();
        if (!load_counter(&low, &high, value) || value != low)
            die("grouped counter snapshot rejected a valid value");
        if (device_barrier_test_count != 1)
            die("grouped counter snapshot did not use exactly one barrier");

        high = 1;
        reset_device_barrier_test_count();
        if (load_counter(&low, &high, value))
            die("grouped counter snapshot accepted a nonzero high word");
        if (device_barrier_test_count != 1)
            die("invalid grouped counter snapshot changed its barrier count");
    }

    {
        Fixture fixture;
        fixture.header->accepted_session = 7;
        reset_device_barrier_test_count();
        if (!active_session_current(*fixture.header, 7, 7, true))
            die("grouped session snapshot rejected a valid generation");
        if (device_barrier_test_count != 1)
            die("grouped session snapshot did not use exactly one barrier");

        fixture.header->quiesce_request = 9;
        fixture.header->quiesce_ack = 9;
        if (!active_session_current(*fixture.header, 7, 0, true) ||
            active_session_current(*fixture.header, 7, 7, true))
            die("grouped session snapshot changed token-pin semantics");
        fixture.header->quiesce_request = 7;
        fixture.header->quiesce_ack = 7;

        session_snapshot_test_hook = [](Header* header) {
            header->magic = QuiesceMagic;
        };
        reset_device_barrier_test_count();
        const bool crossed_magic =
            active_session_current(*fixture.header, 7, 7, true);
        session_snapshot_test_hook = nullptr;
        if (crossed_magic)
            die("grouped session snapshot crossed an H3DQ transition");
        if (device_barrier_test_count != 1)
            die("transitioned session snapshot changed its barrier count");

        fixture.header->magic = Magic;
        fixture.header->quiesce_ack_reserved = 1;
        if (active_session_current(*fixture.header, 7, 7, true))
            die("grouped session snapshot accepted a reserved fence word");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("barrier fixture init failed");
        fixture.publish(make_event(1, EventType::Arm9GpuIoWrite));
        reset_device_barrier_test_count();
        Event event{};
        if (!consumer.peek(event) || event.sequence != 1)
            die("barrier fixture event was not visible");
        // One grouped session snapshot, four grouped counters (producer,
        // consumer, first commit, second commit), and one grouped six-word
        // payload snapshot are the complete valid-peek hot path.
        if (device_barrier_test_count != 6)
            die("valid event peek did not use the grouped barrier budget");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("valid header rejected");
        if (fixture.header->service_state !=
            static_cast<std::uint32_t>(ServiceState::Ready))
            die("ready state missing");

        for (std::uint32_t sequence = 1;
             sequence < EventConsumer::CreditBatchSize; ++sequence) {
            fixture.publish(make_event(
                sequence,
                sequence & 1 ? EventType::Arm9GpuIoWrite
                             : EventType::Arm9VramWrite));
            Event event{};
            if (!consumer.peek(event)) die("published event not visible");
            if (event.sequence != sequence ||
                event.data != (0x12340000u | sequence))
                die("event payload changed");
            if (!consumer.acknowledge()) die("event acknowledgement failed");
            if (fixture.header->consumer_sequence != 0)
                die("partial batch advanced the consumer fence");
        }

        fixture.publish(make_event(
            EventConsumer::CreditBatchSize, EventType::Arm9GpuIoWrite));
        Event batch_event{};
        if (!consumer.peek(batch_event) || !consumer.acknowledge() ||
            fixture.header->consumer_sequence !=
                EventConsumer::CreditBatchSize)
            die("full batch did not publish its consumer fence");

        const auto idle_sequence = EventConsumer::CreditBatchSize + 1;
        fixture.publish(make_event(idle_sequence, EventType::Arm9VramWrite));
        Event idle_event{};
        if (!consumer.peek(idle_event) || !consumer.acknowledge() ||
            fixture.header->consumer_sequence !=
                EventConsumer::CreditBatchSize)
            die("partial tail was not retained locally");
        Event empty{};
        if (consumer.peek(empty) ||
            fixture.header->consumer_sequence != idle_sequence)
            die("idle tail did not flush its consumer fence");

        const auto forced_sequence = EventConsumer::CreditBatchSize + 2;
        fixture.publish(make_event(forced_sequence, EventType::Arm9GpuIoWrite));
        Event forced_event{};
        if (!consumer.peek(forced_event) || !consumer.acknowledge(true) ||
            fixture.header->consumer_sequence != forced_sequence)
            die("forced consumer fence publication failed");
    }

    {
        Fixture fixture;
        fixture.header->entry_count = 2;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("small-ring fixture init failed");
        for (std::uint32_t sequence = 1; sequence <= 2; ++sequence) {
            fixture.publish(make_event(sequence, EventType::Arm9GpuIoWrite));
            Event event{};
            if (!consumer.peek(event) || !consumer.acknowledge())
                die("small-ring event acknowledgement failed");
            const auto expected_fence = sequence == 2 ? 2u : 0u;
            if (fixture.header->consumer_sequence != expected_fence)
                die("credit batch was not capped to the ring capacity");
        }
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("stale-session fixture init failed");
        fixture.publish(make_event(1, EventType::Arm9GpuIoWrite));
        Event event{};
        if (!consumer.peek(event)) die("stale-session event was not visible");
        fixture.header->quiesce_request = 8;
        if (consumer.acknowledge(true))
            die("old session published a forced consumer fence");
        if (fixture.header->consumer_sequence != 0 ||
            (consumer.local_faults() & FaultBadSession) == 0)
            die("stale-session publication did not fail read-only");
    }

    {
        Fixture fixture;
        fixture.header->consumer_sequence =
            std::numeric_limits<std::uint32_t>::max() - 1;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("terminal fixture init failed");
        fixture.publish(make_event(
            std::numeric_limits<std::uint32_t>::max(),
            EventType::Arm9GpuIoWrite));
        Event event{};
        if (!consumer.peek(event) || !consumer.acknowledge() ||
            fixture.header->consumer_sequence !=
                std::numeric_limits<std::uint32_t>::max())
            die("terminal event did not force-publish its fence");
        if (consumer.peek(event) || consumer.local_faults() != 0)
            die("terminal event did not enter clean exhaustion");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("gap fixture init failed");
        auto event = make_event(2, EventType::Arm9GpuIoWrite);
        fixture.events[0] = event;
        fixture.events[0].sequence = 2;
        fixture.header->producer_sequence = 2;
        Event output{};
        if (consumer.peek(output)) die("future sequence accepted");
        if ((consumer.local_faults() & FaultSequenceGap) == 0)
            die("future sequence did not fault");
    }

    {
        Fixture fixture;
        fixture.header->producer_sequence_reserved = 1;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7))
            die("reserved-fence fixture init failed");
        Event output{};
        if (consumer.peek(output)) die("reserved producer word accepted");
        if ((consumer.local_faults() & FaultBadHeader) == 0)
            die("reserved producer word did not fault");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("reserved-commit fixture init failed");
        fixture.publish(make_event(1, EventType::Arm9GpuIoWrite));
        fixture.events[0].sequence_reserved = 1;
        Event output{};
        if (consumer.peek(output)) die("reserved event commit accepted");
        if ((consumer.local_faults() & FaultTornEvent) == 0)
            die("reserved event commit did not fault as torn");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("torn-event fixture init failed");
        fixture.publish(make_event(1, EventType::Arm9GpuIoWrite));
        event_payload_snapshot_test_hook = [](Event* slot) {
            slot->sequence = 2;
        };
        Event output{};
        const bool accepted = consumer.peek(output);
        event_payload_snapshot_test_hook = nullptr;
        if (accepted) die("event with a changed second commit accepted");
        if ((consumer.local_faults() & FaultTornEvent) == 0)
            die("changed second commit did not fault as torn");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("peek-session fixture init failed");
        fixture.publish(make_event(1, EventType::Arm9GpuIoWrite));
        fixture.header->fpga_session = 8;
        Event output{};
        if (consumer.peek(output)) die("old session event accepted by peek");
        if ((consumer.local_faults() & FaultBadSession) == 0)
            die("peek did not retain its session fence");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("invalid-event fixture init failed");
        auto event = make_event(1, EventType::Arm9GpuIoWrite);
        event.metadata = make_metadata(
            EventType::Arm9GpuIoWrite, false, AccessWidth::Word, 0);
        fixture.publish(event);
        Event output{};
        if (consumer.peek(output)) die("zero-byte-enable event accepted");
        if ((consumer.local_faults() & FaultBadEvent) == 0)
            die("invalid event did not fault");
    }

    {
        Fixture fixture;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (consumer.initialize(8)) die("wrong session accepted");
        if ((consumer.local_faults() & FaultBadSession) == 0)
            die("wrong session did not fault");
    }

    {
        Fixture fixture;
        fixture.header->producer_sequence = Fixture::Entries + 1;
        fixture.header->consumer_sequence = 0;
        EventConsumer consumer(fixture.bytes.data(), fixture.bytes.size());
        if (!consumer.initialize(7)) die("overrun fixture init failed");
        Event output{};
        if (consumer.peek(output)) die("overrun accepted");
        if ((consumer.local_faults() & FaultRingOverrun) == 0)
            die("overrun did not fault");
    }

    {
        Fixture fixture(19);
        fixture.header->accepted_session = 19;
        std::vector<std::uint32_t> source(PlanePixels);
        std::vector<std::uint32_t> bank0(PlanePixels, 0xdeadbeefu);
        std::vector<std::uint32_t> bank1(PlanePixels, 0xdeadbeefu);
        for (std::size_t index = 0; index < source.size(); ++index)
            source[index] = static_cast<std::uint32_t>(index) ^ 0x1f123456u;

        PlanePublisher publisher(
            *fixture.header, bank0.data(), bank1.data());
        if (!publisher.publish(19, 41, source.data()))
            die("first plane publication failed");
        if (publisher.last_store_count() != PlanePixels)
            die("first plane bank was not fully initialized");
        if (fixture.header->frame_publish_sequence != 2 ||
            fixture.header->frame.sequence != 2 ||
            fixture.header->frame.session != 19 ||
            fixture.header->frame.frame != 41 ||
            fixture.header->frame.bank != 0 ||
            fixture.header->frame.format != PixelFormatRgb666A5 ||
            fixture.header->frame.width_height !=
                (PlaneWidth | (PlaneHeight << 16)) ||
            fixture.header->frame.stride != PlaneStride)
            die("first plane descriptor is wrong");
        for (std::size_t index = 0; index < source.size(); ++index)
            if (bank0[index] != pack_melonds_pixel(source[index]))
                die("plane pixel conversion is wrong");
        if (publisher.publish(19, 42, source.data()))
            die("unacknowledged plane was overwritten");

        fixture.header->frame_ack_sequence = 2;
        if (!publisher.publish(19, 42, source.data()))
            die("second plane publication failed");
        if (publisher.last_store_count() != PlanePixels)
            die("second plane bank was not fully initialized");
        if (fixture.header->frame_publish_sequence != 4 ||
            fixture.header->frame.bank != 1)
            die("plane bank did not alternate");

        fixture.header->frame_ack_sequence = 4;
        if (!publisher.publish(19, 43, source.data()))
            die("unchanged plane publication failed");
        if (publisher.last_store_count() != 0)
            die("unchanged plane rewrote shared memory");
        if (fixture.header->frame_publish_sequence != 6 ||
            fixture.header->frame.frame != 43 ||
            fixture.header->frame.bank != 0)
            die("unchanged plane descriptor was not published");

        constexpr std::size_t ChangedPixel = 1234;
        source[ChangedPixel] ^= 1u;
        fixture.header->frame_ack_sequence = 6;
        if (!publisher.publish(19, 44, source.data()))
            die("dirty plane publication failed");
        if (publisher.last_store_count() != 1)
            die("dirty plane did not write exactly one changed word");
        if (bank1[ChangedPixel] != pack_melonds_pixel(source[ChangedPixel]))
            die("dirty plane word was not updated");

        fixture.header->frame_ack_sequence = 8;
        if (!publisher.publish(19, 45, source.data()) ||
            publisher.last_store_count() != 1)
            die("dirty pixel was not propagated to both banks");

        // Bit six is outside the RGB666A5 payload.  The raw-source cache must
        // notice it so later blocks can be skipped, while the packed cache
        // must still suppress an unnecessary Device-memory store.
        source[ChangedPixel] ^= 0x40u;
        fixture.header->frame_ack_sequence = 10;
        if (!publisher.publish(19, 46, source.data()) ||
            publisher.last_store_count() != 0)
            die("pack-equivalent source change rewrote shared memory");
        fixture.header->frame_ack_sequence = 12;
        if (!publisher.publish(19, 47, source.data()) ||
            publisher.last_store_count() != 0)
            die("pack-equivalent source change was not cached per bank");

        fixture.header->fpga_session = 20;
        fixture.header->frame_ack_sequence = 14;
        if (publisher.publish(19, 48, source.data()))
            die("old-session plane was published");
    }

    {
        Fixture fixture(23);
        fixture.header->accepted_session = 23;
        std::vector<std::uint32_t> source(PlanePixels, 0x1f3f3f3fu);
        std::vector<std::uint32_t> bank0(PlanePixels);
        std::vector<std::uint32_t> bank1(PlanePixels);
        PlanePublisher publisher(
            *fixture.header, bank0.data(), bank1.data());
        fixture.header->magic = QuiesceMagic;
        if (publisher.publish(23, 1, source.data()))
            die("plane published while quiescing");
        fixture.header->magic = Magic;
        fixture.header->quiesce_request = 24;
        if (publisher.publish(23, 2, source.data()))
            die("plane published with stale quiesce ack");
    }

    {
        Fixture fixture(27);
        fixture.header->accepted_session = 27;
        std::vector<std::uint32_t> source(PlanePixels, 0x1f010203u);
        std::vector<std::uint32_t> bank0(PlanePixels);
        std::vector<std::uint32_t> bank1(PlanePixels);
        PlanePublisher publisher(
            *fixture.header, bank0.data(), bank1.data(), true);
        if (!publisher.publish(27, 1, source.data()) ||
            publisher.last_store_count() != PlanePixels)
            die("WC publisher did not initialize its first bank");
        fixture.header->frame_ack_sequence = 2;
        if (!publisher.publish(27, 2, source.data()) ||
            publisher.last_store_count() != PlanePixels)
            die("WC publisher did not initialize its second bank");

        constexpr std::size_t ChangedPixel = 1234;
        source[ChangedPixel] ^= 1u;
        fixture.header->frame_ack_sequence = 4;
        if (!publisher.publish(27, 3, source.data()) ||
            publisher.last_store_count() != 16 ||
            bank0[ChangedPixel] != pack_melonds_pixel(source[ChangedPixel]))
            die("WC publisher did not burst one changed cache line");
    }

    {
        Fixture fixture(29);
        fixture.header->accepted_session = 29;
        std::vector<std::uint32_t> source(PlanePixels, 0x1f010203u);
        std::vector<std::uint32_t> bank0(PlanePixels);
        std::vector<std::uint32_t> bank1(PlanePixels);
        PlanePublisher publisher(
            *fixture.header, bank0.data(), bank1.data());
        if (publisher.republish_last(29, 1))
            die("plane publisher reused a nonexistent cached bank");
        if (!publisher.publish(29, 1, source.data()))
            die("cached-plane seed publication failed");
        fixture.header->frame_ack_sequence = 2;
        if (!publisher.republish_last(29, 2) ||
            publisher.last_store_count() != 0 ||
            fixture.header->frame_publish_sequence != 4 ||
            fixture.header->frame.frame != 2 ||
            fixture.header->frame.bank != 0)
            die("cached plane was not republished from its immutable bank");

        // A later changed frame must still target the other bank rather than
        // overwrite the cached bank named by the most recent descriptor.
        source[17] ^= 1u;
        fixture.header->frame_ack_sequence = 4;
        if (!publisher.publish(29, 3, source.data()) ||
            fixture.header->frame.bank != 1 ||
            bank1[17] != pack_melonds_pixel(source[17]))
            die("changed plane overwrote the cached live bank");
    }

    std::cout << "H3D_ABI_TEST_PASS\n";
    return 0;
}
