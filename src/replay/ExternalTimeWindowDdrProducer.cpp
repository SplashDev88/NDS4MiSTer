#include "replay/ExternalTimeWindowDdrProducer.h"

#include <limits>
#include <stdexcept>

namespace nds4mister {
namespace {

bool isPowerOfTwo(std::size_t value) {
    return value >= 2 && (value & (value - 1)) == 0;
}

} // namespace

ExternalTimeWindowDdrProducer::ExternalTimeWindowDdrProducer(
    ConsumedCreditAckDdrMemory& memory,
    ExternalTimeWindowDdrLayout layout)
    : memory_(memory), layout_(layout) {
    layoutValid_ = validateLayout();
    if (!layoutValid_)
        fault_ = ExternalTimeWindowDdrProducerFault::InvalidLayout;
}

bool ExternalTimeWindowDdrProducer::validateLayout() {
    if (!isPowerOfTwo(layout_.groupCount) ||
        layout_.headerWords64 < 2 ||
        layout_.consumerWordOffset >= layout_.headerWords64 ||
        layout_.descriptorWordOffset >= layout_.headerWords64 ||
        layout_.consumerWordOffset == layout_.descriptorWordOffset)
        return false;
    if (layout_.groupCount >
        (std::numeric_limits<std::size_t>::max() -
         layout_.headerWords64) / kWordsPerGroup)
        return false;
    const auto ordinaryEnd =
        layout_.headerWords64 + layout_.groupCount * kWordsPerGroup;
    requiredWords_ = ordinaryEnd;
    if (layout_.barrierReplacementWordOffset != 0) {
        if (layout_.barrierReplacementWordOffset < ordinaryEnd ||
            layout_.groupCount >
                (std::numeric_limits<std::size_t>::max() -
                 layout_.barrierReplacementWordOffset) /
                    kWordsPerBarrierReplacement)
            return false;
        requiredWords_ = layout_.barrierReplacementWordOffset +
            layout_.groupCount * kWordsPerBarrierReplacement;
    }
    return requiredWords_ <= memory_.wordCount();
}

std::size_t ExternalTimeWindowDdrProducer::groupBase(
    std::uint32_t groupSequence) const {
    const auto slot = static_cast<std::size_t>(
        (groupSequence - 1u) & (layout_.groupCount - 1u));
    return layout_.headerWords64 + slot * kWordsPerGroup;
}

std::size_t ExternalTimeWindowDdrProducer::barrierReplacementBase(
    std::uint32_t groupSequence) const {
    const auto slot = static_cast<std::size_t>(
        (groupSequence - 1u) & (layout_.groupCount - 1u));
    return layout_.barrierReplacementWordOffset +
        slot * kWordsPerBarrierReplacement;
}

ExternalTimeWindowDdrPublishResult ExternalTimeWindowDdrProducer::latch(
    ExternalTimeWindowDdrProducerFault fault) {
    fault_ = fault;
    active_ = false;
    ready_ = false;
    return ExternalTimeWindowDdrPublishResult::Fault;
}

void ExternalTimeWindowDdrProducer::poisonCallbackFailure() {
    fault_ = ExternalTimeWindowDdrProducerFault::CallbackFailed;
    active_ = false;
    ready_ = false;
}

void ExternalTimeWindowDdrProducer::
poisonTransportFailureAfterClosure() {
    fault_ = ExternalTimeWindowDdrProducerFault::
        TransportFailureAfterClosure;
    active_ = false;
    ready_ = false;
}

bool ExternalTimeWindowDdrProducer::beginSession(
    std::uint32_t epoch,
    bool transportQuiescent) {
    if (!transportQuiescent) return false;
    if (fault_ != ExternalTimeWindowDdrProducerFault::None) return false;
    if (!layoutValid_) {
        fault_ = ExternalTimeWindowDdrProducerFault::InvalidLayout;
        return false;
    }
    if (active_) {
        fault_ = ExternalTimeWindowDdrProducerFault::ActiveSession;
        return false;
    }
    if (epoch == 0) {
        fault_ = ExternalTimeWindowDdrProducerFault::InvalidEpoch;
        return false;
    }
    if (epoch == lastEpoch_) {
        fault_ = ExternalTimeWindowDdrProducerFault::EpochReuse;
        return false;
    }

    // Session setup is externally serialized with both endpoints quiescent.
    // Clear the complete mapped ABI so no stale physical-slot commit survives.
    for (std::size_t word = 0; word < requiredWords_; ++word)
        memory_.storeRelaxed64(word, 0);
    memory_.cleanCpuWrites(0, requiredWords_);

    // A 64-bit device store is not assumed atomic on Cortex-A9. Publish magic
    // first and make the nonzero descriptor epoch the final release commit.
    // Explicitly clear the 32-bit descriptor commit before installing magic;
    // do not rely on the preceding 64-bit clearing stores being atomic.
    memory_.storeRelaxed32(
        layout_.descriptorWordOffset, false, 0);
    memory_.cleanCpuWrites(layout_.descriptorWordOffset, 1);
    memory_.storeRelaxed32(
        layout_.descriptorWordOffset, true, kDescriptorMagic);
    memory_.cleanCpuWrites(layout_.descriptorWordOffset, 1);
    memory_.storeRelease32(
        layout_.descriptorWordOffset, false, epoch);
    memory_.cleanCpuWrites(layout_.descriptorWordOffset, 1);

    epoch_ = epoch;
    lastEpoch_ = epoch;
    producerGroupSequence_ = 0;
    consumerGroupSequence_ = 0;
    lastEventSequence_ = 0;
    processedThroughInclusive_ = 0;
    runSafeThroughInclusive_ = 0;
    lastBarrierSequence_ = 0;
    lastBarrierSourceSequence_ = 0;
    lastBarrierVerifiedProducerFence_ = 0;
    fault_ = ExternalTimeWindowDdrProducerFault::None;
    active_ = true;
    ready_ = false;
    haveWindow_ = false;
    groupSequenceExhausted_ = false;
    eventSequenceExhausted_ = false;
    return true;
}

void ExternalTimeWindowDdrProducer::stopSession() {
    active_ = false;
    ready_ = false;
}

bool ExternalTimeWindowDdrProducer::resetAfterModelReset(
    bool modelReset,
    bool transportQuiescent) {
    if (!modelReset || !transportQuiescent) return false;
    epoch_ = 0;
    producerGroupSequence_ = 0;
    consumerGroupSequence_ = 0;
    lastEventSequence_ = 0;
    processedThroughInclusive_ = 0;
    runSafeThroughInclusive_ = 0;
    lastBarrierSequence_ = 0;
    lastBarrierSourceSequence_ = 0;
    lastBarrierVerifiedProducerFence_ = 0;
    fault_ = layoutValid_
        ? ExternalTimeWindowDdrProducerFault::None
        : ExternalTimeWindowDdrProducerFault::InvalidLayout;
    active_ = false;
    ready_ = false;
    haveWindow_ = false;
    groupSequenceExhausted_ = false;
    eventSequenceExhausted_ = false;
    return layoutValid_;
}

bool ExternalTimeWindowDdrProducer::validateDescriptor() {
    memory_.invalidateFpgaWrites(layout_.descriptorWordOffset, 1);
    const auto epoch1 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    const auto magic = memory_.loadAcquire32(
        layout_.descriptorWordOffset, true);
    const auto epoch2 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    if (epoch1 != epoch2 || epoch1 != epoch_ ||
        magic != kDescriptorMagic) {
        latch(ExternalTimeWindowDdrProducerFault::EpochMismatch);
        return false;
    }
    return true;
}

bool ExternalTimeWindowDdrProducer::refreshConsumer() {
    if (!active_) return false;
    if (!validateDescriptor()) return false;

    memory_.invalidateFpgaWrites(layout_.consumerWordOffset, 1);
    const auto epoch1 = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    const auto sequence = memory_.loadAcquire32(
        layout_.consumerWordOffset, false);
    const auto epoch2 = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    if (epoch1 == 0 && epoch2 == 0 && sequence == 0) {
        if (!ready_) return false;
        latch(ExternalTimeWindowDdrProducerFault::SessionReset);
        return false;
    }
    if (epoch1 != epoch2 || epoch1 != epoch_) {
        latch(ExternalTimeWindowDdrProducerFault::EpochMismatch);
        return false;
    }
    if (sequence < consumerGroupSequence_) {
        latch(ExternalTimeWindowDdrProducerFault::ConsumerMovedBackward);
        return false;
    }
    if (sequence > producerGroupSequence_) {
        latch(ExternalTimeWindowDdrProducerFault::ConsumerMovedAhead);
        return false;
    }
    if (!validateDescriptor()) return false;

    consumerGroupSequence_ = sequence;
    ready_ = true;
    return true;
}

bool ExternalTimeWindowDdrProducer::sessionReady() {
    return refreshConsumer();
}

bool ExternalTimeWindowDdrProducer::validateGroup(
    const ExternalTimeWindowDdrGroup& group,
    ExternalTimeWindowDdrPublishResult& result) const {
    if (group.runSafeThroughInclusive <
        group.processedThroughInclusive) {
        result = ExternalTimeWindowDdrPublishResult::Fault;
        return false;
    }
    if (haveWindow_ && group.processedThroughInclusive <
                           processedThroughInclusive_) {
        result = ExternalTimeWindowDdrPublishResult::Fault;
        return false;
    }
    if (haveWindow_ && group.runSafeThroughInclusive <
                           runSafeThroughInclusive_) {
        result = ExternalTimeWindowDdrPublishResult::Fault;
        return false;
    }
    if (group.events.size() > kMaxEvents) {
        result = ExternalTimeWindowDdrPublishResult::Fault;
        return false;
    }

    const auto count = static_cast<std::uint32_t>(group.events.size());
    if (count == 0) {
        if (group.lastEventSequence != lastEventSequence_) {
            result = ExternalTimeWindowDdrPublishResult::Fault;
            return false;
        }
    } else {
        const auto max = std::numeric_limits<std::uint32_t>::max();
        if (lastEventSequence_ == max || count > max - lastEventSequence_) {
            result = ExternalTimeWindowDdrPublishResult::Fault;
            return false;
        }
        const auto expectedLast = lastEventSequence_ + count;
        if (group.lastEventSequence != expectedLast) {
            result = ExternalTimeWindowDdrPublishResult::Fault;
            return false;
        }
        if (haveWindow_ &&
            group.processedThroughInclusive <= runSafeThroughInclusive_) {
            result = ExternalTimeWindowDdrPublishResult::Fault;
            return false;
        }
        for (std::size_t index = 0; index < group.events.size(); ++index) {
            const auto& event = group.events[index];
            const auto expected = lastEventSequence_ +
                static_cast<std::uint32_t>(index) + 1u;
            if (event.sequence == 0 || event.sequence != expected) {
                result = ExternalTimeWindowDdrPublishResult::Fault;
                return false;
            }
            if (event.timestamp != group.processedThroughInclusive ||
                event.mask == 0) {
                result = ExternalTimeWindowDdrPublishResult::Fault;
                return false;
            }
        }
    }

    if (haveWindow_ && group.events.empty() &&
        group.processedThroughInclusive == processedThroughInclusive_ &&
        group.runSafeThroughInclusive == runSafeThroughInclusive_) {
        result = ExternalTimeWindowDdrPublishResult::NoAdvance;
        return false;
    }
    return true;
}

void ExternalTimeWindowDdrProducer::writeGroup(
    std::uint32_t groupSequence,
    const ExternalTimeWindowDdrGroup& group) {
    const auto base = groupBase(groupSequence);
    // Invalidate any stale low commit before reusing a physical slot. This is
    // deliberately a 32-bit store; Cortex-A9 device-memory 64-bit stores are
    // not assumed atomic.
    memory_.storeRelaxed32(base + 20, false, 0);
    memory_.cleanCpuWrites(base + 20, 1);

    memory_.storeRelaxed64(base, group.processedThroughInclusive);
    memory_.storeRelaxed64(base + 1, group.runSafeThroughInclusive);
    memory_.storeRelaxed64(
        base + 2,
        (static_cast<std::uint64_t>(group.lastEventSequence) << 32) |
            static_cast<std::uint8_t>(group.events.size()));

    std::uint32_t bitmap = 0;
    for (std::size_t index = 0; index < group.events.size(); ++index) {
        if (group.events[index].arm9)
            bitmap |= std::uint32_t{1} << (index * 2);
        if (group.events[index].set)
            bitmap |= std::uint32_t{1} << (index * 2 + 1);
    }
    memory_.storeRelaxed64(base + 3, bitmap);

    // Every physical event payload is explicitly overwritten. This prevents
    // a short group in a reused slot from inheriting stale event metadata.
    for (std::size_t index = 0; index < kMaxEvents; ++index) {
        std::uint64_t payload = 0;
        if (index < group.events.size()) {
            const auto& event = group.events[index];
            payload = (static_cast<std::uint64_t>(event.mask) << 32) |
                event.sequence;
        }
        memory_.storeRelaxed64(base + 4 + index, payload);
    }
    memory_.cleanCpuWrites(base, 20);

    // Commit the high epoch while the low half is still explicitly zero. The
    // low 32-bit release store below is the sole publication point.
    memory_.storeRelaxed32(base + 20, true, epoch_);
    memory_.cleanCpuWrites(base + 20, 1);
    memory_.storeRelease32(base + 20, false, groupSequence);
    memory_.cleanCpuWrites(base + 20, 1);
}

void ExternalTimeWindowDdrProducer::writeBarrierReplacementExtension(
    std::uint32_t groupSequence,
    const ExternalTimeWindowDdrBarrierReplacement& replacement) {
    const auto base = barrierReplacementBase(groupSequence);

    // As with the ordinary slot, never rely on a 64-bit device store being
    // atomic.  Invalidate the low commit before replacing a physical slot.
    memory_.storeRelaxed32(base + 8, false, 0);
    memory_.cleanCpuWrites(base + 8, 1);

    const auto count = static_cast<std::uint8_t>(
        replacement.group.events.size());
    memory_.storeRelaxed64(
        base,
        (static_cast<std::uint64_t>(kBarrierReplacementMagic) << 32) |
            (static_cast<std::uint64_t>(replacement.identity.eventCount)
             << 8) |
            count);
    memory_.storeRelaxed64(
        base + 1,
        (static_cast<std::uint64_t>(
             replacement.identity.barrierSequence) << 32) |
            replacement.identity.activeGrantGroupSequence);
    memory_.storeRelaxed64(
        base + 2,
        replacement.identity.sourceSequence);
    memory_.storeRelaxed64(
        base + 3, replacement.identity.verifiedProducerFence);
    memory_.storeRelaxed64(
        base + 4,
        replacement.identity.barrierTimestamp);
    memory_.storeRelaxed64(
        base + 5,
        (static_cast<std::uint64_t>(
             replacement.group.lastEventSequence) << 32) |
            replacement.identity.priorEventHighWater);
    memory_.storeRelaxed64(
        base + 6,
        (static_cast<std::uint64_t>(replacement.identity.epoch) << 32) |
            (replacement.identity.requesterArm9 ? 1u : 0u));
    memory_.storeRelaxed64(
        base + 7, replacement.identity.requiredRunSafeThrough);
    memory_.cleanCpuWrites(base, 8);

    // This commit proves that the sidecar is complete.  It is intentionally
    // not the complete-record publication point: writeGroup() publishes its
    // unchanged low commit only after this sidecar is durable.
    memory_.storeRelaxed32(base + 8, true, replacement.identity.epoch);
    memory_.cleanCpuWrites(base + 8, 1);
    memory_.storeRelease32(base + 8, false, groupSequence);
    memory_.cleanCpuWrites(base + 8, 1);
}

bool ExternalTimeWindowDdrProducer::validateBarrierIdentityBeforeClosure(
    const ExternalTimeWindowDdrBarrierIdentity& identity,
    ExternalTimeWindowDdrProducerFault& fault) const {
    if (layout_.barrierReplacementWordOffset == 0) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierReplacementUnavailable;
        return false;
    }
    if (identity.epoch != epoch_) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierEpochMismatch;
        return false;
    }
    if (!haveWindow_) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierNoActiveGrant;
        return false;
    }
    if (identity.activeGrantGroupSequence != producerGroupSequence_) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierActiveGroupMismatch;
        return false;
    }
    if (lastBarrierSequence_ ==
            std::numeric_limits<std::uint32_t>::max() ||
        identity.barrierSequence != lastBarrierSequence_ + 1u) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierSequenceMismatch;
        return false;
    }
    if (identity.sourceSequence == 0 ||
        identity.sourceSequence <= lastBarrierSourceSequence_) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierSourceMismatch;
        return false;
    }
    // Blocking-source IDs and posted-write fences are independent monotonic
    // domains.  The runtime validates the fence's session epoch; this layer
    // only prevents a verified fence from moving backward across barriers.
    if (identity.verifiedProducerFence <
        lastBarrierVerifiedProducerFence_) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierFenceMismatch;
        return false;
    }
    if (identity.barrierTimestamp < processedThroughInclusive_ ||
        identity.barrierTimestamp > runSafeThroughInclusive_) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierTimestampMismatch;
        return false;
    }
    if (identity.requiredRunSafeThrough < identity.barrierTimestamp) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierRequiredRunSafeMismatch;
        return false;
    }
    if (identity.priorEventHighWater != lastEventSequence_) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierPriorEventMismatch;
        return false;
    }
    if (identity.eventCount > kMaxEvents) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierEventCapacityMismatch;
        return false;
    }
    const auto max = std::numeric_limits<std::uint32_t>::max();
    if (static_cast<std::uint32_t>(identity.eventCount) >
        max - lastEventSequence_) {
        fault = ExternalTimeWindowDdrProducerFault::EventSequenceExhausted;
        return false;
    }
    return true;
}

bool ExternalTimeWindowDdrProducer::validateBarrierReplacement(
    const ExternalTimeWindowDdrBarrierIdentity& expected,
    const ExternalTimeWindowDdrBarrierReplacement& replacement,
    ExternalTimeWindowDdrProducerFault& fault) const {
    const auto& actual = replacement.identity;
    if (actual.epoch != expected.epoch) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierEpochMismatch;
        return false;
    }
    if (actual.activeGrantGroupSequence !=
        expected.activeGrantGroupSequence) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierActiveGroupMismatch;
        return false;
    }
    if (actual.barrierSequence != expected.barrierSequence) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierSequenceMismatch;
        return false;
    }
    if (actual.sourceSequence != expected.sourceSequence) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierSourceMismatch;
        return false;
    }
    if (actual.verifiedProducerFence !=
        expected.verifiedProducerFence) {
        fault = ExternalTimeWindowDdrProducerFault::BarrierFenceMismatch;
        return false;
    }
    if (actual.barrierTimestamp != expected.barrierTimestamp) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierTimestampMismatch;
        return false;
    }
    if (actual.requesterArm9 != expected.requesterArm9) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierRequesterMismatch;
        return false;
    }
    if (actual.requiredRunSafeThrough !=
        expected.requiredRunSafeThrough) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierRequiredRunSafeMismatch;
        return false;
    }
    if (actual.priorEventHighWater != expected.priorEventHighWater) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierPriorEventMismatch;
        return false;
    }
    if (actual.eventCount != expected.eventCount ||
        replacement.group.events.size() > expected.eventCount) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierEventCapacityMismatch;
        return false;
    }

    const auto& group = replacement.group;
    if (group.processedThroughInclusive != expected.barrierTimestamp ||
        group.runSafeThroughInclusive < expected.barrierTimestamp) {
        fault = ExternalTimeWindowDdrProducerFault::
            BarrierTimestampMismatch;
        return false;
    }
    const auto expectedLast = expected.priorEventHighWater +
        static_cast<std::uint32_t>(replacement.group.events.size());
    if (group.lastEventSequence != expectedLast) {
        fault = ExternalTimeWindowDdrProducerFault::
            EventHighWaterMismatch;
        return false;
    }
    for (std::size_t index = 0; index < group.events.size(); ++index) {
        const auto& item = group.events[index];
        const auto expectedSequence = expected.priorEventHighWater +
            static_cast<std::uint32_t>(index) + 1u;
        if (item.sequence == 0 || item.sequence != expectedSequence) {
            fault = ExternalTimeWindowDdrProducerFault::
                EventSequenceMismatch;
            return false;
        }
        if (item.timestamp != expected.barrierTimestamp || item.mask == 0) {
            fault = ExternalTimeWindowDdrProducerFault::InvalidEvent;
            return false;
        }
    }
    return true;
}

ExternalTimeWindowDdrPublishResult ExternalTimeWindowDdrProducer::publish(
    const std::function<ExternalTimeWindowDdrGroup()>& close,
    ExternalTimeWindowDdrReceipt& receipt) {
    if (!active_ || fault_ != ExternalTimeWindowDdrProducerFault::None)
        return ExternalTimeWindowDdrPublishResult::Fault;
    if (groupSequenceExhausted_ || eventSequenceExhausted_ ||
        producerGroupSequence_ ==
            std::numeric_limits<std::uint32_t>::max())
        return ExternalTimeWindowDdrPublishResult::Exhausted;
    if (!refreshConsumer()) {
        return active_
            ? ExternalTimeWindowDdrPublishResult::SessionNotReady
            : ExternalTimeWindowDdrPublishResult::Fault;
    }

    const auto outstanding =
        static_cast<std::uint64_t>(producerGroupSequence_) -
        static_cast<std::uint64_t>(consumerGroupSequence_);
    if (outstanding >= layout_.groupCount)
        return ExternalTimeWindowDdrPublishResult::Backpressured;
    // Capacity and session state are proven before this irreversible scheduler
    // closure. Callback failure poisons the epoch; it can never be replayed.
    ExternalTimeWindowDdrGroup group;
    try {
        group = close();
    } catch (...) {
        poisonCallbackFailure();
        throw;
    }

    // A reset or epoch replacement during a potentially long closure wins
    // over all returned-data validation. No old-epoch payload has been stored.
    try {
        if (!refreshConsumer())
            return ExternalTimeWindowDdrPublishResult::Fault;
    } catch (...) {
        // close() may already have advanced the scheduler. A transport
        // exception after that point must poison the epoch so the caller can
        // never retry the same irreversible closure.
        poisonTransportFailureAfterClosure();
        throw;
    }

    ExternalTimeWindowDdrPublishResult validationResult =
        ExternalTimeWindowDdrPublishResult::Fault;
    if (!validateGroup(group, validationResult)) {
        if (validationResult ==
            ExternalTimeWindowDdrPublishResult::NoAdvance)
            return validationResult;
        if (group.runSafeThroughInclusive <
            group.processedThroughInclusive)
            return latch(
                ExternalTimeWindowDdrProducerFault::RunSafeBeforeProcessed);
        if (haveWindow_ && group.processedThroughInclusive <
                               processedThroughInclusive_)
            return latch(ExternalTimeWindowDdrProducerFault::
                             ProcessedThroughRegressed);
        if (haveWindow_ && group.runSafeThroughInclusive <
                               runSafeThroughInclusive_)
            return latch(ExternalTimeWindowDdrProducerFault::
                             RunSafeThroughRegressed);
        if (group.events.size() > kMaxEvents)
            return latch(
                ExternalTimeWindowDdrProducerFault::TooManyEvents);
        const auto count = static_cast<std::uint32_t>(group.events.size());
        const auto max = std::numeric_limits<std::uint32_t>::max();
        if (count != 0 &&
            (lastEventSequence_ == max ||
             count > max - lastEventSequence_))
            return latch(ExternalTimeWindowDdrProducerFault::
                             EventSequenceExhausted);
        if (count == 0 &&
            group.lastEventSequence != lastEventSequence_)
            return latch(ExternalTimeWindowDdrProducerFault::
                             EventHighWaterMismatch);
        if (count != 0 &&
            group.lastEventSequence != lastEventSequence_ + count)
            return latch(ExternalTimeWindowDdrProducerFault::
                             EventHighWaterMismatch);
        if (count != 0 && haveWindow_ &&
            group.processedThroughInclusive <= runSafeThroughInclusive_)
            return latch(ExternalTimeWindowDdrProducerFault::LateEvent);
        for (std::size_t index = 0; index < group.events.size(); ++index) {
            const auto& event = group.events[index];
            const auto expected = lastEventSequence_ +
                static_cast<std::uint32_t>(index) + 1u;
            if (event.sequence == 0 || event.sequence != expected)
                return latch(ExternalTimeWindowDdrProducerFault::
                                 EventSequenceMismatch);
            if (event.timestamp != group.processedThroughInclusive ||
                event.mask == 0)
                return latch(
                    ExternalTimeWindowDdrProducerFault::InvalidEvent);
        }
        return latch(ExternalTimeWindowDdrProducerFault::InvalidEvent);
    }

    const auto groupSequence = producerGroupSequence_ + 1u;
    try {
        writeGroup(groupSequence, group);
    } catch (...) {
        // A partially serialized slot is unpublished because its low commit
        // remains zero, but the scheduler closure itself cannot be replayed.
        poisonTransportFailureAfterClosure();
        throw;
    }

    producerGroupSequence_ = groupSequence;
    lastEventSequence_ = group.lastEventSequence;
    processedThroughInclusive_ = group.processedThroughInclusive;
    runSafeThroughInclusive_ = group.runSafeThroughInclusive;
    haveWindow_ = true;
    if (groupSequence == std::numeric_limits<std::uint32_t>::max())
        groupSequenceExhausted_ = true;
    if (lastEventSequence_ == std::numeric_limits<std::uint32_t>::max())
        eventSequenceExhausted_ = true;
    receipt = {epoch_, groupSequence};
    return ExternalTimeWindowDdrPublishResult::Published;
}

ExternalTimeWindowDdrPublishResult
ExternalTimeWindowDdrProducer::publishBarrierReplacement(
    const ExternalTimeWindowDdrBarrierIdentity& expected,
    const std::function<ExternalTimeWindowDdrBarrierReplacement()>& close,
    ExternalTimeWindowDdrReceipt& receipt) {
    if (!active_ || fault_ != ExternalTimeWindowDdrProducerFault::None)
        return ExternalTimeWindowDdrPublishResult::Fault;
    if (groupSequenceExhausted_ || eventSequenceExhausted_ ||
        producerGroupSequence_ ==
            std::numeric_limits<std::uint32_t>::max())
        return ExternalTimeWindowDdrPublishResult::Exhausted;
    if (!refreshConsumer()) {
        return active_
            ? ExternalTimeWindowDdrPublishResult::SessionNotReady
            : ExternalTimeWindowDdrPublishResult::Fault;
    }

    const auto outstanding =
        static_cast<std::uint64_t>(producerGroupSequence_) -
        static_cast<std::uint64_t>(consumerGroupSequence_);
    if (outstanding >= layout_.groupCount)
        return ExternalTimeWindowDdrPublishResult::Backpressured;
    // A replacement describes the exact grant already active in the FPGA,
    // never an HPS-published group that the consumer has not ACKed yet.
    if (consumerGroupSequence_ != producerGroupSequence_)
        return ExternalTimeWindowDdrPublishResult::Backpressured;

    // This is the reservation boundary.  The ordinary slot, the complete
    // fixed-size replacement sidecar, the exact event count, and sequence
    // space are all proven before the callback is allowed to mutate model
    // state.  A malformed admission descriptor therefore invokes no closure.
    ExternalTimeWindowDdrProducerFault identityFault =
        ExternalTimeWindowDdrProducerFault::None;
    if (!validateBarrierIdentityBeforeClosure(expected, identityFault))
        return latch(identityFault);

    ExternalTimeWindowDdrBarrierReplacement replacement;
    try {
        replacement = close();
    } catch (...) {
        poisonCallbackFailure();
        throw;
    }

    // As with ordinary publication, the irreversible callback makes any
    // subsequent transport/session failure epoch-fatal and non-retryable.
    try {
        if (!refreshConsumer())
            return ExternalTimeWindowDdrPublishResult::Fault;
    } catch (...) {
        poisonTransportFailureAfterClosure();
        throw;
    }

    ExternalTimeWindowDdrProducerFault replacementFault =
        ExternalTimeWindowDdrProducerFault::None;
    if (!validateBarrierReplacement(
            expected, replacement, replacementFault))
        return latch(replacementFault);

    const auto groupSequence = producerGroupSequence_ + 1u;
    try {
        // Publish the identity sidecar before serializing the ordinary group.
        // writeGroup's unchanged low release commit remains the final point
        // at which the complete replacement becomes visible.
        writeBarrierReplacementExtension(groupSequence, replacement);
        writeGroup(groupSequence, replacement.group);
    } catch (...) {
        poisonTransportFailureAfterClosure();
        throw;
    }

    producerGroupSequence_ = groupSequence;
    lastEventSequence_ = replacement.group.lastEventSequence;
    processedThroughInclusive_ =
        replacement.group.processedThroughInclusive;
    runSafeThroughInclusive_ =
        replacement.group.runSafeThroughInclusive;
    lastBarrierSequence_ = expected.barrierSequence;
    lastBarrierSourceSequence_ = expected.sourceSequence;
    lastBarrierVerifiedProducerFence_ = expected.verifiedProducerFence;
    haveWindow_ = true;
    if (groupSequence == std::numeric_limits<std::uint32_t>::max())
        groupSequenceExhausted_ = true;
    if (lastEventSequence_ == std::numeric_limits<std::uint32_t>::max())
        eventSequenceExhausted_ = true;
    receipt = {epoch_, groupSequence};
    return ExternalTimeWindowDdrPublishResult::Published;
}

bool ExternalTimeWindowDdrProducer::consumedThrough(
    const ExternalTimeWindowDdrReceipt& receipt) const {
    if (!active_ || !ready_ ||
        fault_ != ExternalTimeWindowDdrProducerFault::None ||
        receipt.epoch != epoch_ || receipt.groupSequence == 0 ||
        receipt.groupSequence > producerGroupSequence_)
        return false;

    memory_.invalidateFpgaWrites(layout_.descriptorWordOffset, 1);
    const auto descriptorEpoch1 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    const auto magic = memory_.loadAcquire32(
        layout_.descriptorWordOffset, true);
    const auto descriptorEpoch2 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    if (descriptorEpoch1 != descriptorEpoch2 ||
        descriptorEpoch1 != epoch_ || magic != kDescriptorMagic)
        return false;

    memory_.invalidateFpgaWrites(layout_.consumerWordOffset, 1);
    const auto consumerEpoch1 = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    const auto sequence = memory_.loadAcquire32(
        layout_.consumerWordOffset, false);
    const auto consumerEpoch2 = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    if (consumerEpoch1 != consumerEpoch2 || consumerEpoch1 != epoch_ ||
        sequence < consumerGroupSequence_ ||
        sequence > producerGroupSequence_)
        return false;

    memory_.invalidateFpgaWrites(layout_.descriptorWordOffset, 1);
    const auto finalEpoch1 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    const auto finalMagic = memory_.loadAcquire32(
        layout_.descriptorWordOffset, true);
    const auto finalEpoch2 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    return finalEpoch1 == finalEpoch2 && finalEpoch1 == epoch_ &&
        finalMagic == kDescriptorMagic &&
        sequence >= receipt.groupSequence;
}

void ExternalTimeWindowDdrProducer::seedSequencesForSelfTest(
    std::uint32_t producerGroupSequence,
    std::uint32_t consumerGroupSequence,
    std::uint32_t lastEventSequence,
    std::uint64_t processedThroughInclusive,
    std::uint64_t runSafeThroughInclusive,
    bool haveWindow) {
    if (!active_ || !ready_ ||
        fault_ != ExternalTimeWindowDdrProducerFault::None ||
        producerGroupSequence ==
            std::numeric_limits<std::uint32_t>::max() ||
        consumerGroupSequence > producerGroupSequence ||
        (haveWindow &&
         runSafeThroughInclusive < processedThroughInclusive) ||
        (!haveWindow &&
         (processedThroughInclusive != 0 ||
          runSafeThroughInclusive != 0 || lastEventSequence != 0)))
        throw std::logic_error(
            "invalid external-time-window DDR self-test seed");

    producerGroupSequence_ = producerGroupSequence;
    consumerGroupSequence_ = consumerGroupSequence;
    lastEventSequence_ = lastEventSequence;
    processedThroughInclusive_ = processedThroughInclusive;
    runSafeThroughInclusive_ = runSafeThroughInclusive;
    haveWindow_ = haveWindow;
    groupSequenceExhausted_ = false;
    eventSequenceExhausted_ =
        lastEventSequence_ == std::numeric_limits<std::uint32_t>::max();
    memory_.storeRelaxed64(
        layout_.consumerWordOffset,
        (static_cast<std::uint64_t>(epoch_) << 32) |
            consumerGroupSequence_);
    memory_.cleanCpuWrites(layout_.consumerWordOffset, 1);
}

} // namespace nds4mister
