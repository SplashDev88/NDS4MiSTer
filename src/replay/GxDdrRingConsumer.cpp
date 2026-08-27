#include "replay/GxDdrRingConsumer.h"

#include <limits>

namespace nds4mister {
namespace {

constexpr std::size_t kWordsPerEntry = 4;

bool isPowerOfTwo(std::size_t value) {
    return value >= 2 && (value & (value - 1)) == 0;
}

} // namespace

GxDdrRingConsumer::GxDdrRingConsumer(GxDdrWordMemory& memory,
                                     GxDdrRingLayout layout)
    : memory_(memory), layout_(layout) {
    layoutValid_ = validateLayout();
    if (!layoutValid_) fault_ = GxDdrConsumerFault::InvalidLayout;
}

bool GxDdrRingConsumer::validateLayout() {
    if (!isPowerOfTwo(layout_.entryCount) ||
        layout_.headerWords64 == 0 ||
        layout_.consumerWordOffset >= layout_.headerWords64)
        return false;
    if (layout_.entryCount >
        (std::numeric_limits<std::size_t>::max() -
         layout_.headerWords64) / kWordsPerEntry)
        return false;
    requiredWords_ =
        layout_.headerWords64 + layout_.entryCount * kWordsPerEntry;
    return requiredWords_ <= memory_.wordCount();
}

std::size_t GxDdrRingConsumer::commitWord(std::size_t slot) const {
    return layout_.headerWords64 + slot * kWordsPerEntry + 3;
}

GxDdrPollResult GxDdrRingConsumer::latch(GxDdrConsumerFault fault) {
    fault_ = fault;
    active_ = false;
    return GxDdrPollResult::Fault;
}

bool GxDdrRingConsumer::beginSession(std::uint32_t expectedEpoch) {
    active_ = false;
    consumerFence_ = 0;
    expectedEpoch_ = expectedEpoch;
    fault_ = GxDdrConsumerFault::None;
    if (!layoutValid_) {
        fault_ = GxDdrConsumerFault::InvalidLayout;
        return false;
    }

    memory_.invalidateDeviceWrites(layout_.consumerWordOffset, 1);
    if (memory_.loadAcquire(layout_.consumerWordOffset) != 0) {
        fault_ = GxDdrConsumerFault::DirtySessionControl;
        return false;
    }

    for (std::size_t slot = 0; slot < layout_.entryCount; ++slot) {
        const auto word = commitWord(slot);
        memory_.invalidateDeviceWrites(word, 1);
        if (memory_.loadAcquire(word) != 0) {
            fault_ = GxDdrConsumerFault::DirtySessionCommit;
            return false;
        }
    }

    active_ = true;
    return true;
}

void GxDdrRingConsumer::stopSession() {
    active_ = false;
    if (fault_ == GxDdrConsumerFault::None)
        fault_ = GxDdrConsumerFault::NotStarted;
}

bool GxDdrRingConsumer::nextFence(std::uint64_t current,
                                  std::uint64_t& next) noexcept {
    if (current == std::numeric_limits<std::uint64_t>::max()) return false;
    next = current + 1;
    return true;
}

bool GxDdrRingConsumer::validateControl() {
    memory_.invalidateDeviceWrites(layout_.consumerWordOffset, 1);
    const auto shared = memory_.loadAcquire(layout_.consumerWordOffset);
    if (shared == consumerFence_) return true;
    if (shared < consumerFence_) {
        latch(GxDdrConsumerFault::SessionReset);
    } else {
        latch(GxDdrConsumerFault::ConsumerControlAdvanced);
    }
    return false;
}

GxDdrPollResult GxDdrRingConsumer::poll(GxDdrCommandSink& sink) {
    if (!active_) {
        if (fault_ == GxDdrConsumerFault::None)
            fault_ = GxDdrConsumerFault::NotStarted;
        return GxDdrPollResult::Fault;
    }
    if (!validateControl()) return GxDdrPollResult::Fault;
    std::uint64_t expected = 0;
    if (!nextFence(consumerFence_, expected))
        return latch(GxDdrConsumerFault::FenceExhausted);

    const std::size_t slot =
        static_cast<std::size_t>((expected - 1) &
                                 (layout_.entryCount - 1));
    const std::size_t base =
        layout_.headerWords64 + slot * kWordsPerEntry;
    const std::size_t commit = base + 3;

    memory_.invalidateDeviceWrites(commit, 1);
    const auto firstCommit = memory_.loadAcquire(commit);
    if (firstCommit < expected) return GxDdrPollResult::Empty;
    if (firstCommit > expected)
        return latch(GxDdrConsumerFault::FutureCommit);

    memory_.invalidateDeviceWrites(base, kWordsPerEntry);
    const auto beat0 = memory_.loadRelaxed(base);
    const auto timestamp = memory_.loadRelaxed(base + 1);
    const auto beat2 = memory_.loadRelaxed(base + 2);
    memory_.invalidateDeviceWrites(commit, 1);
    const auto secondCommit = memory_.loadAcquire(commit);
    if (secondCommit != expected)
        return latch(GxDdrConsumerFault::CommitChanged);
    if ((beat0 >> 40) != 0)
        return latch(GxDdrConsumerFault::ReservedPayloadBits);

    GxDdrCommand command;
    command.command = static_cast<std::uint8_t>(beat0 >> 32);
    command.parameter = static_cast<std::uint32_t>(beat0);
    command.timestamp = timestamp;
    command.frame = static_cast<std::uint32_t>(beat2);
    command.epoch = static_cast<std::uint32_t>(beat2 >> 32);
    command.fence = expected;
    if (command.epoch != expectedEpoch_)
        return latch(GxDdrConsumerFault::EpochMismatch);

    if (!sink.ready(command)) return GxDdrPollResult::Retry;

    // Revalidate both shared ownership words before invoking a potentially
    // stateful renderer.  Reset remains externally serialized as documented.
    if (!validateControl()) return GxDdrPollResult::Fault;
    memory_.invalidateDeviceWrites(commit, 1);
    if (memory_.loadAcquire(commit) != expected)
        return latch(GxDdrConsumerFault::CommitChanged);

    const auto dispatchResult = sink.dispatch(command);
    if (dispatchResult == GxDdrDispatchResult::Fatal)
        return latch(GxDdrConsumerFault::DispatcherRejected);

    // A long-running dispatch must not acknowledge a slot from a session that
    // visibly changed while it was executing.
    if (!validateControl()) return GxDdrPollResult::Fault;
    memory_.invalidateDeviceWrites(commit, 1);
    if (memory_.loadAcquire(commit) != expected)
        return latch(GxDdrConsumerFault::CommitChanged);

    memory_.storeRelease(layout_.consumerWordOffset, expected);
    memory_.cleanCpuWrites(layout_.consumerWordOffset, 1);
    consumerFence_ = expected;
    return GxDdrPollResult::Dispatched;
}

} // namespace nds4mister
