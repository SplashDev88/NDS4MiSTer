#include "replay/ConsumedCreditAckDdrProducer.h"

#include <limits>
#include <stdexcept>

namespace nds4mister {
namespace {

bool isPowerOfTwo(std::size_t value) {
    return value >= 2 && (value & (value - 1)) == 0;
}

} // namespace

ConsumedCreditAckDdrProducer::ConsumedCreditAckDdrProducer(
    ConsumedCreditAckDdrMemory& memory,
    ConsumedCreditAckDdrLayout layout)
    : memory_(memory), layout_(layout) {
    layoutValid_ = validateLayout();
    if (!layoutValid_)
        fault_ = ConsumedCreditAckProducerFault::InvalidLayout;
}

bool ConsumedCreditAckDdrProducer::validateLayout() {
    if (!isPowerOfTwo(layout_.entryCount) ||
        layout_.headerWords64 < 2 ||
        layout_.consumerWordOffset >= layout_.headerWords64 ||
        layout_.descriptorWordOffset >= layout_.headerWords64 ||
        layout_.consumerWordOffset == layout_.descriptorWordOffset)
        return false;
    if (layout_.entryCount >
        (std::numeric_limits<std::size_t>::max() -
         layout_.headerWords64) / kWordsPerEntry)
        return false;
    requiredWords_ =
        layout_.headerWords64 + layout_.entryCount * kWordsPerEntry;
    return requiredWords_ <= memory_.wordCount();
}

std::size_t ConsumedCreditAckDdrProducer::entryBase(
    std::uint32_t sequence) const {
    const auto slot = static_cast<std::size_t>(
        (sequence - 1u) & (layout_.entryCount - 1u));
    return layout_.headerWords64 + slot * kWordsPerEntry;
}

std::size_t ConsumedCreditAckDdrProducer::commitWord(
    std::size_t slot) const {
    return layout_.headerWords64 + slot * kWordsPerEntry + 2;
}

ConsumedCreditAckPublishResult ConsumedCreditAckDdrProducer::latch(
    ConsumedCreditAckProducerFault fault) {
    fault_ = fault;
    active_ = false;
    ready_ = false;
    return ConsumedCreditAckPublishResult::Fault;
}

bool ConsumedCreditAckDdrProducer::beginSession(
    std::uint32_t epoch,
    bool transportQuiescent) {
    if (!transportQuiescent) return false;
    if (!layoutValid_) {
        fault_ = ConsumedCreditAckProducerFault::InvalidLayout;
        return false;
    }
    if (active_) {
        fault_ = ConsumedCreditAckProducerFault::ActiveSession;
        return false;
    }
    if (epoch == 0) {
        fault_ = ConsumedCreditAckProducerFault::InvalidEpoch;
        return false;
    }
    if (epoch == lastEpoch_) {
        fault_ = ConsumedCreditAckProducerFault::EpochReuse;
        return false;
    }

    // Both endpoints are quiescent.  Clear every header/payload/commit word so
    // a stale commit cannot be mistaken for sequence one in the new session.
    for (std::size_t word = 0; word < requiredWords_; ++word)
        memory_.storeRelaxed64(word, 0);
    memory_.cleanCpuWrites(0, requiredWords_);

    // A Cortex-A9 must not be assumed to issue an atomic 64-bit device store.
    // Publish the constant magic first and the nonzero 32-bit epoch commit
    // last.  FPGA rechecks the complete descriptor after scanning commits.
    memory_.storeRelaxed32(
        layout_.descriptorWordOffset, true, kDescriptorMagic);
    memory_.cleanCpuWrites(layout_.descriptorWordOffset, 1);
    memory_.storeRelease32(
        layout_.descriptorWordOffset, false, epoch);
    memory_.cleanCpuWrites(layout_.descriptorWordOffset, 1);

    epoch_ = epoch;
    lastEpoch_ = epoch;
    producerSequence_ = 0;
    consumerSequence_ = 0;
    lastPostedSource_ = 0;
    fault_ = ConsumedCreditAckProducerFault::None;
    active_ = true;
    ready_ = false;
    exhausted_ = false;
    return true;
}

void ConsumedCreditAckDdrProducer::stopSession() {
    active_ = false;
    ready_ = false;
}

bool ConsumedCreditAckDdrProducer::refreshConsumer() {
    if (!active_) return false;
    if (!validateDescriptor()) return false;
    memory_.invalidateFpgaWrites(layout_.consumerWordOffset, 1);
    const auto firstEpoch = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    const auto sharedSequence = memory_.loadAcquire32(
        layout_.consumerWordOffset, false);
    const auto secondEpoch = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    if (firstEpoch == 0 && secondEpoch == 0 &&
        sharedSequence == 0) {
        if (!ready_) return false;
        latch(ConsumedCreditAckProducerFault::SessionReset);
        return false;
    }

    if (firstEpoch != secondEpoch || firstEpoch != epoch_) {
        latch(ConsumedCreditAckProducerFault::EpochMismatch);
        return false;
    }
    if (sharedSequence < consumerSequence_) {
        latch(ConsumedCreditAckProducerFault::ConsumerMovedBackward);
        return false;
    }
    if (sharedSequence > producerSequence_) {
        latch(ConsumedCreditAckProducerFault::ConsumerMovedAhead);
        return false;
    }
    // A reset/session replacement must not race between the first descriptor
    // validation and the consumer-control sample.
    if (!validateDescriptor()) return false;

    consumerSequence_ = sharedSequence;
    ready_ = true;
    return true;
}

bool ConsumedCreditAckDdrProducer::validateDescriptor() {
    memory_.invalidateFpgaWrites(layout_.descriptorWordOffset, 1);
    const auto firstEpoch = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    const auto magic = memory_.loadAcquire32(
        layout_.descriptorWordOffset, true);
    const auto secondEpoch = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    if (firstEpoch != secondEpoch || firstEpoch != epoch_ ||
        magic != kDescriptorMagic) {
        latch(ConsumedCreditAckProducerFault::EpochMismatch);
        return false;
    }
    return true;
}

bool ConsumedCreditAckDdrProducer::sessionReady() {
    return refreshConsumer();
}

bool ConsumedCreditAckDdrProducer::validateAckAndFence(
    const ConsumedCreditAck& ack,
    std::uint32_t requiredPostedSource,
    ConsumedCreditAckPublishResult& result) {
    const auto kindValue = static_cast<std::uint8_t>(ack.kind);
    if (kindValue > static_cast<std::uint8_t>(
                        ConsumedCreditAckKind::Halt)) {
        result = latch(ConsumedCreditAckProducerFault::InvalidKind);
        return false;
    }

    if (ack.kind == ConsumedCreditAckKind::Posted) {
        if (lastPostedSource_ ==
                std::numeric_limits<std::uint32_t>::max() ||
            ack.sourceId != lastPostedSource_ + 1u) {
            result = latch(
                ConsumedCreditAckProducerFault::PostedSourceGap);
            return false;
        }
    } else if (requiredPostedSource > lastPostedSource_) {
        result = ConsumedCreditAckPublishResult::OrderingBlocked;
        return false;
    }
    return true;
}

void ConsumedCreditAckDdrProducer::poisonCallbackFailure() {
    fault_ = ConsumedCreditAckProducerFault::CallbackFailed;
    active_ = false;
    ready_ = false;
}

void ConsumedCreditAckDdrProducer::writeEntryPayload(
    std::uint32_t sequence,
    const ConsumedCreditAck& ack,
    std::uint32_t transactionBits,
    std::uint32_t commitPayload) {
    const auto base = entryBase(sequence);
    const auto kindValue = static_cast<std::uint8_t>(ack.kind);
    const auto control =
        (static_cast<std::uint64_t>(epoch_) << 32) |
        transactionBits |
        static_cast<std::uint64_t>(kindValue) << 1 |
        static_cast<std::uint64_t>(ack.arm9);

    memory_.storeRelaxed64(
        base,
        (static_cast<std::uint64_t>(ack.cycles) << 32) |
            ack.sourceId);
    memory_.storeRelaxed64(base + 1, control);
    memory_.cleanCpuWrites(base, 2);
    // The upper half is ordinary payload.  It is explicitly overwritten even
    // with zero so a physically reused ring slot cannot retain stale boundary
    // data.  The low sequence remains the sole release commit.
    memory_.storeRelaxed32(base + 2, true, commitPayload);
    memory_.cleanCpuWrites(base + 2, 1);
}

void ConsumedCreditAckDdrProducer::commitEntry(
    std::uint32_t sequence) {
    const auto base = entryBase(sequence);
    // Only the low 32 bits are the commit.  This is a single Cortex-A9 store;
    // no 64-bit atomicity assumption leaks into the ABI.
    memory_.storeRelease32(base + 2, false, sequence);
    memory_.cleanCpuWrites(base + 2, 1);
}

bool ConsumedCreditAckDdrProducer::validateBoundary(
    const ConsumedCreditAck& ack,
    const ConsumedCreditAckIrqBoundary& boundary) {
    if (!boundary.enabled) {
        return !boundary.readNotWrite && boundary.access == 0 &&
            boundary.address == 0 && boundary.payload == 0;
    }
    if ((ack.kind != ConsumedCreditAckKind::Mailbox &&
         ack.kind != ConsumedCreditAckKind::Posted) ||
        boundary.access > 2)
        return false;

    const auto wordAddress = boundary.address & ~std::uint32_t{3};
    if (wordAddress != 0x04000208u &&
        wordAddress != 0x04000210u &&
        wordAddress != 0x04000214u)
        return false;
    if ((boundary.access == 1 && (boundary.address & 1u) != 0) ||
        (boundary.access == 2 && (boundary.address & 3u) != 0))
        return false;
    const auto offset = boundary.address - kIrqRegisterBase;
    return offset <= 0x1fu;
}

ConsumedCreditAckPublishResult ConsumedCreditAckDdrProducer::publish(
    const ConsumedCreditAck& ack,
    std::uint32_t requiredPostedSource,
    const std::function<void()>& advance,
    const std::function<void()>& apply) {
    if (!active_ || fault_ != ConsumedCreditAckProducerFault::None)
        return ConsumedCreditAckPublishResult::Fault;
    if (exhausted_ ||
        producerSequence_ == std::numeric_limits<std::uint32_t>::max())
        return ConsumedCreditAckPublishResult::Exhausted;
    if (!refreshConsumer()) {
        return active_
            ? ConsumedCreditAckPublishResult::SessionNotReady
            : ConsumedCreditAckPublishResult::Fault;
    }

    ConsumedCreditAckPublishResult validationResult =
        ConsumedCreditAckPublishResult::Fault;
    if (!validateAckAndFence(
            ack, requiredPostedSource, validationResult))
        return validationResult;

    const auto outstanding =
        static_cast<std::uint64_t>(producerSequence_) -
        static_cast<std::uint64_t>(consumerSequence_);
    if (outstanding >= layout_.entryCount)
        return ConsumedCreditAckPublishResult::Backpressured;

    // Capacity and fence ordering are proven before either callback.  Any
    // callback failure is fatal to this epoch because partial emulator state
    // cannot safely be retried.
    try {
        advance();
        apply();
    } catch (...) {
        poisonCallbackFailure();
        throw;
    }
    // Revalidate the epoch/control after potentially long model callbacks and
    // before publishing their acknowledgement.  External coordination must
    // still forbid a reset racing the final commit itself.
    if (!refreshConsumer())
        return ConsumedCreditAckPublishResult::Fault;

    const auto sequence = producerSequence_ + 1u;
    writeEntryPayload(sequence, ack, 0, 0);
    commitEntry(sequence);

    producerSequence_ = sequence;
    if (ack.kind == ConsumedCreditAckKind::Posted)
        lastPostedSource_ = ack.sourceId;
    if (sequence == std::numeric_limits<std::uint32_t>::max())
        exhausted_ = true;
    return ConsumedCreditAckPublishResult::Published;
}

ConsumedCreditAckPublishResult
ConsumedCreditAckDdrProducer::publishTransaction(
    const ConsumedCreditAck& ack,
    std::uint32_t requiredPostedSource,
    const ConsumedCreditAckIrqBoundary& boundary,
    const std::function<void()>& advance,
    const std::function<std::uint32_t()>& apply,
    const std::function<ConsumedCreditAckIrqMasks()>& captureIrqs,
    ConsumedCreditAckDdrReceipt& receipt) {
    if (!active_ || fault_ != ConsumedCreditAckProducerFault::None)
        return ConsumedCreditAckPublishResult::Fault;

    // A transaction must reserve its worst case before any model callback.
    // This deliberately rejects even a zero-event transaction when fewer
    // than five sequence numbers remain: callbacks cannot be safely replayed
    // after discovering their actual IRQ record count.
    constexpr auto maxSequence =
        std::numeric_limits<std::uint32_t>::max();
    if (exhausted_ ||
        producerSequence_ >
            maxSequence - kMaxTransactionEntries)
        return ConsumedCreditAckPublishResult::Exhausted;
    if (!refreshConsumer()) {
        return active_
            ? ConsumedCreditAckPublishResult::SessionNotReady
            : ConsumedCreditAckPublishResult::Fault;
    }

    ConsumedCreditAckPublishResult validationResult =
        ConsumedCreditAckPublishResult::Fault;
    if (!validateAckAndFence(
            ack, requiredPostedSource, validationResult))
        return validationResult;
    if (ack.sourceId == 0)
        return latch(ConsumedCreditAckProducerFault::InvalidSourceId);
    if (!validateBoundary(ack, boundary))
        return latch(ConsumedCreditAckProducerFault::InvalidBoundary);

    const auto outstanding =
        static_cast<std::uint64_t>(producerSequence_) -
        static_cast<std::uint64_t>(consumerSequence_);
    if (outstanding + kMaxTransactionEntries > layout_.entryCount)
        return ConsumedCreditAckPublishResult::Backpressured;

    ConsumedCreditAckIrqMasks pre;
    ConsumedCreditAckIrqMasks post;
    std::uint32_t postApplyReadResult = 0;
    try {
        advance();
        pre = captureIrqs();
        postApplyReadResult = apply();
        post = captureIrqs();
    } catch (...) {
        poisonCallbackFailure();
        throw;
    }

    // A reset/session replacement during potentially long model callbacks
    // invalidates the whole batch.  No entry has been written at this point.
    if (!refreshConsumer())
        return ConsumedCreditAckPublishResult::Fault;

    const auto preCount =
        static_cast<std::uint32_t>(pre.arm9 != 0) +
        static_cast<std::uint32_t>(pre.arm7 != 0);
    const auto postCount =
        static_cast<std::uint32_t>(post.arm9 != 0) +
        static_cast<std::uint32_t>(post.arm7 != 0);
    const auto baseSequence = producerSequence_ + 1u;
    const auto boundaryOffset = boundary.enabled
        ? boundary.address - kIrqRegisterBase
        : 0u;

    const std::uint32_t transactionBits =
        (preCount << kPreCountShift) |
        (postCount << kPostCountShift) |
        (static_cast<std::uint32_t>(boundary.enabled) <<
             kLocalBoundaryBit) |
        (static_cast<std::uint32_t>(boundary.readNotWrite) <<
             kReadNotWriteBit) |
        (static_cast<std::uint32_t>(boundary.access) << kAccessShift) |
        (boundaryOffset << kAddressOffsetShift);
    const auto serializedBoundaryPayload =
        boundary.enabled && boundary.readNotWrite
        ? postApplyReadResult
        : boundary.payload;
    writeEntryPayload(
        baseSequence, ack, transactionBits, serializedBoundaryPayload);

    struct Child {
        std::uint32_t sequence;
        ConsumedCreditAck ack;
        std::uint32_t transactionBits;
    };
    Child children[4]{};
    std::size_t childCount = 0;
    const auto appendPhase = [&](
        const ConsumedCreditAckIrqMasks& masks,
        bool postPhase) {
        const auto childBits =
            static_cast<std::uint32_t>(postPhase) <<
            kChildPostPhaseBit;
        if (masks.arm9 != 0) {
            const auto sequence =
                baseSequence + static_cast<std::uint32_t>(childCount) + 1u;
            children[childCount] = {
                sequence,
                {true, 0, ConsumedCreditAckKind::IrqSet, masks.arm9},
                childBits};
            ++childCount;
        }
        if (masks.arm7 != 0) {
            const auto sequence =
                baseSequence + static_cast<std::uint32_t>(childCount) + 1u;
            children[childCount] = {
                sequence,
                {false, 0, ConsumedCreditAckKind::IrqSet, masks.arm7},
                childBits};
            ++childCount;
        }
    };
    appendPhase(pre, false);
    appendPhase(post, true);

    // All payload is clean before any commit.  Every child is committed before
    // the base descriptor, which is the publication point for the counted
    // transaction even when the physical ring wraps.
    for (std::size_t i = 0; i < childCount; ++i)
        writeEntryPayload(
            children[i].sequence, children[i].ack,
            children[i].transactionBits, 0);
    for (std::size_t i = 0; i < childCount; ++i)
        commitEntry(children[i].sequence);
    commitEntry(baseSequence);

    const auto finalSequence =
        baseSequence + static_cast<std::uint32_t>(childCount);
    producerSequence_ = finalSequence;
    if (ack.kind == ConsumedCreditAckKind::Posted)
        lastPostedSource_ = ack.sourceId;
    if (finalSequence == maxSequence)
        exhausted_ = true;
    receipt = {epoch_, baseSequence, finalSequence};
    return ConsumedCreditAckPublishResult::Published;
}

bool ConsumedCreditAckDdrProducer::consumedThrough(
    const ConsumedCreditAckDdrReceipt& receipt) const {
    if (!active_ || !ready_ ||
        fault_ != ConsumedCreditAckProducerFault::None ||
        receipt.epoch != epoch_ || receipt.baseSequence == 0 ||
        receipt.finalSequence < receipt.baseSequence ||
        receipt.finalSequence - receipt.baseSequence >=
            kMaxTransactionEntries ||
        receipt.finalSequence > producerSequence_)
        return false;

    // This intentionally does not call refreshConsumer(): waiting for a
    // receipt may poll, but it must not mutate producer/model state or latch a
    // fault.  Triple samples reject torn descriptor/control updates.
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
    const auto sharedSequence = memory_.loadAcquire32(
        layout_.consumerWordOffset, false);
    const auto consumerEpoch2 = memory_.loadAcquire32(
        layout_.consumerWordOffset, true);
    if (consumerEpoch1 != consumerEpoch2 ||
        consumerEpoch1 != epoch_ ||
        sharedSequence < consumerSequence_ ||
        sharedSequence > producerSequence_)
        return false;

    // Recheck the descriptor so session replacement cannot race the consumer
    // watermark sample.
    memory_.invalidateFpgaWrites(layout_.descriptorWordOffset, 1);
    const auto finalDescriptorEpoch1 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    const auto finalMagic = memory_.loadAcquire32(
        layout_.descriptorWordOffset, true);
    const auto finalDescriptorEpoch2 = memory_.loadAcquire32(
        layout_.descriptorWordOffset, false);
    return finalDescriptorEpoch1 == finalDescriptorEpoch2 &&
        finalDescriptorEpoch1 == epoch_ &&
        finalMagic == kDescriptorMagic &&
        sharedSequence >= receipt.finalSequence;
}

void ConsumedCreditAckDdrProducer::seedSequenceForSelfTest(
    std::uint32_t producerSequence,
    std::uint32_t consumerSequence,
    std::uint32_t lastPostedSource) {
    if (!active_ || !ready_ ||
        producerSequence == std::numeric_limits<std::uint32_t>::max() ||
        consumerSequence > producerSequence)
        throw std::logic_error("invalid consumed-credit self-test seed");
    producerSequence_ = producerSequence;
    consumerSequence_ = consumerSequence;
    lastPostedSource_ = lastPostedSource;
    exhausted_ = false;
    memory_.storeRelaxed64(
        layout_.consumerWordOffset,
        (static_cast<std::uint64_t>(epoch_) << 32) |
            consumerSequence_);
    memory_.cleanCpuWrites(layout_.consumerWordOffset, 1);
}

} // namespace nds4mister
