#include "replay/ExternalTimeWindowRuntime.h"

#include <exception>
#include <limits>
#include <string>
#include <utility>

namespace nds4mister {
namespace {

void setError(std::string& error, const std::string& message) noexcept {
    try {
        error = message;
    } catch (...) {
    }
}

void setError(std::string& error, const char* message) noexcept {
    try {
        error = message;
    } catch (...) {
    }
}

bool sameWork(
    std::uint32_t generation,
    ExternalTimeWindowLwWorkKind kind,
    std::uint32_t expectedGeneration,
    ExternalTimeWindowLwWorkKind expectedKind) noexcept
{
    return generation == expectedGeneration && kind == expectedKind;
}

std::uint32_t nextNonzeroGeneration(std::uint32_t generation) noexcept {
    return generation == std::numeric_limits<std::uint32_t>::max()
        ? 1u : generation + 1u;
}

bool isCompletionReleaseSuccessor(
    std::uint32_t previous,
    std::uint32_t observed) noexcept
{
    const auto direct = nextNonzeroGeneration(previous);
    // After WAIT_RELEASE the seam can briefly publish REFILL, then replace it
    // with FREEZE when a blocking request arrives. Userspace may observe only
    // that second generation; both states are downstream of prior completion
    // consumption and requester release. No other autonomous skip is legal.
    return observed == direct ||
        observed == nextNonzeroGeneration(direct);
}

} // namespace

ExternalTimeWindowRuntime::ExternalTimeWindowRuntime(
    ExternalTimeWindowLwControl& control,
    ExternalTimeWindowDdrProducer& producer,
    ExternalTimeWindowRuntimeCallbacks callbacks,
    std::uint64_t finiteLookahead)
    : control_(control), producer_(producer), callbacks_(std::move(callbacks)),
      finiteLookahead_(finiteLookahead)
{
}

bool ExternalTimeWindowRuntime::decodeEpochScopedFence(
    std::uint64_t fence,
    std::uint32_t expectedEpoch,
    std::uint32_t& rawPostedSequence) noexcept
{
    rawPostedSequence = static_cast<std::uint32_t>(fence);
    return expectedEpoch != 0 &&
        static_cast<std::uint32_t>(fence >> 32) == expectedEpoch;
}

bool ExternalTimeWindowRuntime::beginSession(
    std::uint32_t epoch,
    bool transportQuiescent,
    std::string& error)
{
    error.clear();
    if (sessionStarted_ || faulted_ || epoch == 0) {
        setError(error, "external time-window runtime session is invalid");
        return false;
    }
    if (!callbacks_.setModelEnabled || !callbacks_.reportCPUReached ||
        !callbacks_.pendingIRQTransitions || !callbacks_.closeWindow ||
        !callbacks_.executeBlockingMMIO || !callbacks_.externalCPUHalted ||
        !callbacks_.drainVerifiedPostedFence) {
        setError(error, "external time-window runtime callback is missing");
        return false;
    }
    // Surviving DDR must be reset/versioned before the model can emit any
    // transition that would need a transport identity.
    if (!producer_.beginSession(epoch, transportQuiescent)) {
        setError(error, "external time-window DDR session initialization failed");
        return false;
    }
    if (!callbacks_.setModelEnabled(true, error)) {
        producer_.stopSession();
        if (error.empty())
            setError(error, "external time-window model enable failed");
        return false;
    }
    epoch_ = epoch;
    sessionStarted_ = true;
    return true;
}

ExternalTimeWindowRuntimePollResult ExternalTimeWindowRuntime::fail(
    std::string& error,
    const std::string& message) noexcept
{
    faulted_ = true;
    setError(error, message);
    return ExternalTimeWindowRuntimePollResult::Fault;
}

bool ExternalTimeWindowRuntime::validateSnapshotEpochAndFence(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error) const
{
    std::uint32_t raw = 0;
    if (!sessionStarted_ || snapshot.epoch != epoch_ ||
        !decodeEpochScopedFence(
            snapshot.verifiedProducerFence, epoch_, raw)) {
        setError(error, "ETW1 snapshot epoch/fence is not session-scoped");
        return false;
    }
    return true;
}

std::uint64_t ExternalTimeWindowRuntime::ordinaryFiniteBound(
    std::uint64_t target) const noexcept
{
    const auto finiteMaximum =
        std::numeric_limits<std::uint64_t>::max() - 1u;
    if (target >= finiteMaximum ||
        finiteLookahead_ > finiteMaximum - target)
        return finiteMaximum;
    return target + finiteLookahead_;
}

void ExternalTimeWindowRuntime::observeGroupEventCount(
    std::size_t count) noexcept
{
    if (count > maxObservedGroupEventCount_)
        maxObservedGroupEventCount_ = count;
}

void ExternalTimeWindowRuntime::retireCompletedBlockingTransaction() noexcept
{
    blockingStage_ = BlockingStage::None;
    freezeAcknowledged_ = false;
    freezeGeneration_ = 0;
    freezeFence_ = 0;
}

bool ExternalTimeWindowRuntime::closeOrdinary(
    std::uint64_t target,
    std::uint64_t finiteBound,
    const ExternalTimeWindowReplacement& replacement,
    ExternalTimeWindowDdrClosureOutput& output,
    std::string& error)
{
    output = {};
    if (!callbacks_.closeWindow(
            target, finiteBound, replacement, output, error))
        return false;
    observeGroupEventCount(output.transitions.size());
    const auto& window = output.window;
    if (window.processedThrough != target ||
        window.runSafeThrough > finiteBound ||
        window.epoch != replacement.epoch ||
        window.grantSequence != replacement.grantSequence ||
        window.replacesGrantSequence !=
            replacement.replacesGrantSequence ||
        window.verifiedProducerFence !=
            replacement.verifiedProducerFence ||
        window.replacesBlockingMMIO ||
        window.barrierSourceSequence != 0 ||
        window.barrierSequence != 0 || window.barrierTimestamp != 0) {
        setError(error, "ordinary external time-window identity mismatch");
        return false;
    }
    return true;
}

ExternalTimeWindowRuntimePollResult
ExternalTimeWindowRuntime::finishReceipt(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error)
{
    (void)snapshot;
    (void)error;
    if (ordinaryReceiptPending_ &&
        producer_.consumedThrough(ordinaryReceipt_)) {
        if (ordinaryReceipt_.groupSequence == 1)
            initialGrantConsumed_ = true;
        handledWork_ = true;
        handledGeneration_ = ordinaryGeneration_;
        handledKind_ = ExternalTimeWindowLwWorkKind::Refill;
        ordinaryReceiptPending_ = false;
        return ExternalTimeWindowRuntimePollResult::Progress;
    }
    return ordinaryReceiptPending_
        ? ExternalTimeWindowRuntimePollResult::Waiting
        : ExternalTimeWindowRuntimePollResult::Idle;
}

ExternalTimeWindowRuntimePollResult
ExternalTimeWindowRuntime::serviceRefill(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error)
{
    if (blockingStage_ != BlockingStage::None)
        return fail(error, "ordinary ETW refill overlapped blocking MMIO");
    if (handledWork_ && sameWork(
            snapshot.generation, snapshot.kind,
            handledGeneration_, handledKind_))
        return ExternalTimeWindowRuntimePollResult::Waiting;
    if (!validateSnapshotEpochAndFence(snapshot, error))
        return fail(error, error);

    const auto producerSequence = producer_.producerGroupSequence();
    if (producerSequence == std::numeric_limits<std::uint32_t>::max() ||
        snapshot.groupSequence != producerSequence + 1u)
        return fail(error, "ETW1 refill group is not the exact next grant");

    const bool initial = producerSequence == 0;
    std::uint64_t target = 0;
    std::uint32_t replaces = 0;
    if (initial) {
        if (snapshot.processedThrough != 0 || snapshot.runSafeThrough != 0 ||
            snapshot.eventHighWater != 0 || snapshot.arm9Timestamp != 0 ||
            snapshot.arm7Timestamp != 0)
            return fail(error, "initial ETW1 refill was not at reset frontier");
        target = snapshot.processedThrough;
    } else {
        if (snapshot.processedThrough !=
                producer_.processedThroughInclusive() ||
            snapshot.runSafeThrough != producer_.runSafeThroughInclusive() ||
            snapshot.eventHighWater != producer_.lastEventSequence())
            return fail(error, "ETW1 refill does not match active DDR grant");
        // Neither the model nor the FPGA horizon gate permits closing R+1
        // before both effective CPU clocks reach R. Never synthesize progress
        // from an earlier immutable snapshot.
        if (snapshot.arm9Timestamp != snapshot.runSafeThrough ||
            snapshot.arm7Timestamp != snapshot.runSafeThrough)
            return fail(
                error,
                "ETW1 refill snapshot preceded exact dual-CPU prior-R progress");
        if (snapshot.runSafeThrough >=
            std::numeric_limits<std::uint64_t>::max() - 1u)
            return fail(error, "ETW1 run-safe frontier exhausted");
        if (!callbacks_.reportCPUReached(
                true, snapshot.runSafeThrough, error) ||
            !callbacks_.reportCPUReached(
                false, snapshot.runSafeThrough, error))
            return fail(error, "external CPU prior-R report failed: " + error);
        target = snapshot.runSafeThrough + 1u;
        replaces = producerSequence;
    }

    const ExternalTimeWindowReplacement replacement{
        epoch_, snapshot.groupSequence, replaces,
        snapshot.verifiedProducerFence};
    ExternalTimeWindowDdrReceipt receipt;
    const auto result = publishExternalTimeWindowDdr(
        producer_, callbacks_.pendingIRQTransitions(),
        [&](ExternalTimeWindowDdrClosureOutput& output,
            std::string& closureError) {
            return closeOrdinary(
                target, ordinaryFiniteBound(target), replacement,
                output, closureError);
        },
        receipt, error);
    if (result == ExternalTimeWindowDdrPublishResult::Backpressured ||
        result == ExternalTimeWindowDdrPublishResult::SessionNotReady)
        return ExternalTimeWindowRuntimePollResult::Waiting;
    if (result != ExternalTimeWindowDdrPublishResult::Published ||
        receipt.epoch != epoch_ ||
        receipt.groupSequence != snapshot.groupSequence) {
        if (producer_.fault() ==
                ExternalTimeWindowDdrProducerFault::TooManyEvents ||
            maxObservedGroupEventCount_ >
                ExternalTimeWindowDdrProducer::kMaxEvents) {
            return fail(
                error,
                "external time-window event group exceeded capacity: "
                "observed=" +
                    std::to_string(maxObservedGroupEventCount_) +
                    " capacity=" +
                    std::to_string(
                        ExternalTimeWindowDdrProducer::kMaxEvents));
        }
        return fail(error, "ordinary external time-window publication failed: " + error);
    }

    ordinaryReceiptPending_ = true;
    ordinaryGeneration_ = snapshot.generation;
    ordinaryReceipt_ = receipt;
    return ExternalTimeWindowRuntimePollResult::Progress;
}

ExternalTimeWindowRuntimePollResult
ExternalTimeWindowRuntime::serviceFreeze(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error)
{
    if (blockingStage_ != BlockingStage::None)
        return fail(error, "nested ETW1 blocking freeze");
    if (handledWork_ && sameWork(
            snapshot.generation, snapshot.kind,
            handledGeneration_, handledKind_))
        return ExternalTimeWindowRuntimePollResult::Waiting;
    if (!validateSnapshotEpochAndFence(snapshot, error))
        return fail(error, error);
    std::uint64_t stableFence = 0;
    if (!callbacks_.drainVerifiedPostedFence(
            snapshot.verifiedProducerFence, stableFence, error))
        return fail(error, "verified posted-fence drain failed: " + error);
    std::uint32_t stableRaw = 0;
    if (!decodeEpochScopedFence(stableFence, epoch_, stableRaw) ||
        stableFence < snapshot.verifiedProducerFence)
        return fail(error, "verified posted fence was not stable/monotonic");
    if (!control_.acknowledgeFreeze(snapshot, error))
        return fail(error, "ETW1 freeze acknowledgement failed: " + error);
    freezeAcknowledged_ = true;
    freezeGeneration_ = snapshot.generation;
    freezeFence_ = stableFence;
    handledWork_ = true;
    handledGeneration_ = snapshot.generation;
    handledKind_ = snapshot.kind;
    return ExternalTimeWindowRuntimePollResult::Progress;
}

ExternalTimeWindowRuntimePollResult
ExternalTimeWindowRuntime::publishContinuation(std::string& error)
{
    if (blockingRunSafeThrough_ >=
        blockingSnapshot_.requiredRunSafeThrough) {
        blockingStage_ = BlockingStage::NeedCompletion;
        return ExternalTimeWindowRuntimePollResult::Progress;
    }
    if (blockingRunSafeThrough_ ==
        std::numeric_limits<std::uint64_t>::max())
        return fail(error, "blocking ETW continuation frontier exhausted");
    if (!callbacks_.reportCPUReached(
            true, blockingRunSafeThrough_, error) ||
        !callbacks_.reportCPUReached(
            false, blockingRunSafeThrough_, error))
        return fail(error, "blocking ETW continuation progress failed: " + error);

    const auto target = blockingRunSafeThrough_ + 1u;
    if (target > blockingSnapshot_.requiredRunSafeThrough)
        return fail(error, "blocking ETW continuation crossed required frontier");
    if (blockingGroupSequence_ ==
        std::numeric_limits<std::uint32_t>::max())
        return fail(error, "blocking ETW continuation sequence exhausted");
    const ExternalTimeWindowReplacement replacement{
        epoch_, blockingGroupSequence_ + 1u, blockingGroupSequence_,
        blockingSnapshot_.verifiedProducerFence};
    ExternalTimeWindowDdrClosureOutput observed;
    bool observedValid = false;
    ExternalTimeWindowDdrReceipt receipt;
    const auto result = publishExternalTimeWindowDdr(
        producer_, callbacks_.pendingIRQTransitions(),
        [&](ExternalTimeWindowDdrClosureOutput& output,
            std::string& closureError) {
            if (!closeOrdinary(
                    target,
                    blockingSnapshot_.requiredRunSafeThrough,
                    replacement, output, closureError))
                return false;
            observed = output;
            observedValid = true;
            return true;
        },
        receipt, error);
    if (result == ExternalTimeWindowDdrPublishResult::Backpressured ||
        result == ExternalTimeWindowDdrPublishResult::SessionNotReady)
        return ExternalTimeWindowRuntimePollResult::Waiting;
    if (result != ExternalTimeWindowDdrPublishResult::Published ||
        !observedValid || receipt.epoch != epoch_ ||
        receipt.groupSequence != replacement.grantSequence)
        return fail(error, "blocking ETW continuation publication failed: " + error);

    blockingReceipt_ = receipt;
    blockingGroupSequence_ = receipt.groupSequence;
    blockingProcessedThrough_ = observed.window.processedThrough;
    blockingRunSafeThrough_ = observed.window.runSafeThrough;
    blockingEventHighWater_ = observed.window.lastEventSequence;
    blockingStage_ = BlockingStage::WaitContinuationReceipt;
    return ExternalTimeWindowRuntimePollResult::Progress;
}

ExternalTimeWindowRuntimePollResult
ExternalTimeWindowRuntime::serviceDescriptor(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error)
{
    if (!validateSnapshotEpochAndFence(snapshot, error))
        return fail(error, error);
    if (!freezeAcknowledged_ ||
        snapshot.generation != nextNonzeroGeneration(freezeGeneration_) ||
        freezeFence_ != snapshot.verifiedProducerFence)
        return fail(error, "ETW1 descriptor arrived without exact freeze ACK");

    if (blockingStage_ == BlockingStage::None) {
        if (snapshot.groupSequence ==
            std::numeric_limits<std::uint32_t>::max())
            return fail(error, "blocking ETW group sequence exhausted");
        if (snapshot.groupSequence != producer_.producerGroupSequence() ||
            snapshot.processedThrough !=
                producer_.processedThroughInclusive() ||
            snapshot.runSafeThrough != producer_.runSafeThroughInclusive() ||
            snapshot.eventHighWater != producer_.lastEventSequence())
            return fail(error, "ETW1 descriptor does not name active DDR grant");
        if (snapshot.barrierSequence == 0 || snapshot.sourceSequence == 0 ||
            (lastBlockingBarrierSequence_ == 0
                 ? snapshot.barrierSequence != 1
                 : lastBlockingBarrierSequence_ ==
                           std::numeric_limits<std::uint32_t>::max() ||
                       snapshot.barrierSequence !=
                           lastBlockingBarrierSequence_ + 1u) ||
            (lastBlockingSourceSequence_ != 0 &&
             snapshot.sourceSequence <= lastBlockingSourceSequence_))
            return fail(
                error,
                "ETW1 blocking barrier/source identities are not monotonic");

        const auto stoppedTimestamp =
            snapshot.arm9Timestamp > snapshot.arm7Timestamp
                ? snapshot.arm9Timestamp : snapshot.arm7Timestamp;
        const auto barrierTimestamp =
            snapshot.processedThrough > stoppedTimestamp
                ? snapshot.processedThrough : stoppedTimestamp;
        ExternalTimeWindowDdrBarrierIdentity identity{
            snapshot.epoch,
            snapshot.groupSequence,
            snapshot.barrierSequence,
            snapshot.sourceSequence,
            snapshot.verifiedProducerFence,
            barrierTimestamp,
            snapshot.arm9,
            snapshot.requiredRunSafeThrough,
            snapshot.eventHighWater,
            snapshot.reservedEventCount,
        };
        ExternalBlockingMMIORequest request{
            snapshot.epoch,
            snapshot.groupSequence,
            snapshot.processedThrough,
            snapshot.runSafeThrough,
            snapshot.eventHighWater,
            snapshot.sourceSequence,
            snapshot.barrierSequence,
            snapshot.verifiedProducerFence,
            snapshot.arm9Timestamp,
            snapshot.arm7Timestamp,
            snapshot.arm9,
            !snapshot.readNotWrite,
            snapshot.access,
            snapshot.address,
            snapshot.writeData,
            snapshot.executionPC,
        };
        const ExternalTimeWindowReplacement replacement{
            snapshot.epoch,
            snapshot.groupSequence + 1u,
            snapshot.groupSequence,
            snapshot.verifiedProducerFence,
        };
        ExternalBlockingMMIOCompletion observed;
        bool observedValid = false;
        ExternalTimeWindowDdrReceipt receipt;
        ExternalBlockingMMIODdrReadResponse readResponse;
        const auto result = publishExternalBlockingMMIODdr(
            producer_, callbacks_.pendingIRQTransitions(), identity,
            [&](ExternalBlockingMMIOCompletion& completion,
                std::string& closureError) {
                if (!callbacks_.executeBlockingMMIO(
                        request, snapshot.requiredRunSafeThrough,
                        replacement, completion, closureError))
                    return false;
                observeGroupEventCount(completion.transitions.size());
                if (completion.window.processedThrough !=
                        barrierTimestamp ||
                    completion.window.runSafeThrough >
                        snapshot.requiredRunSafeThrough) {
                    closureError =
                        "blocking external-MMIO replacement escaped its "
                        "admitted frontier";
                    return false;
                }
                observed = completion;
                observedValid = true;
                return true;
            },
            receipt, readResponse, error);
        if (result == ExternalTimeWindowDdrPublishResult::Backpressured ||
            result == ExternalTimeWindowDdrPublishResult::SessionNotReady)
            return ExternalTimeWindowRuntimePollResult::Waiting;
        if (result != ExternalTimeWindowDdrPublishResult::Published ||
            !observedValid || !readResponse.valid ||
            receipt.epoch != snapshot.epoch ||
            receipt.groupSequence != replacement.grantSequence ||
            readResponse.epoch != snapshot.epoch ||
            readResponse.sourceSequence != snapshot.sourceSequence ||
            readResponse.barrierSequence != snapshot.barrierSequence)
        {
            if (maxObservedGroupEventCount_ >
                ExternalTimeWindowDdrProducer::kMaxEvents) {
                return fail(
                    error,
                    "blocking external-MMIO event group exceeded capacity: "
                    "observed=" +
                        std::to_string(maxObservedGroupEventCount_) +
                        " capacity=" +
                        std::to_string(
                            ExternalTimeWindowDdrProducer::kMaxEvents));
            }
            return fail(error, "blocking external-MMIO publication failed: " + error);
        }

        blockingSnapshot_ = snapshot;
        blockingReceipt_ = receipt;
        blockingReadData_ = readResponse.value;
        blockingGroupSequence_ = receipt.groupSequence;
        blockingProcessedThrough_ = observed.window.processedThrough;
        blockingRunSafeThrough_ = observed.window.runSafeThrough;
        blockingEventHighWater_ = observed.window.lastEventSequence;
        lastBlockingBarrierSequence_ = snapshot.barrierSequence;
        lastBlockingSourceSequence_ = snapshot.sourceSequence;
        blockingStage_ = BlockingStage::WaitReplacementReceipt;
        return ExternalTimeWindowRuntimePollResult::Progress;
    }

    if (snapshot.generation != blockingSnapshot_.generation ||
        snapshot.barrierSequence != blockingSnapshot_.barrierSequence ||
        snapshot.sourceSequence != blockingSnapshot_.sourceSequence)
        return fail(error, "ETW1 blocking descriptor changed while retained");

    if (blockingStage_ == BlockingStage::WaitReplacementReceipt ||
        blockingStage_ == BlockingStage::WaitContinuationReceipt) {
        if (!producer_.consumedThrough(blockingReceipt_))
            return ExternalTimeWindowRuntimePollResult::Waiting;
        blockingStage_ = blockingRunSafeThrough_ <
                blockingSnapshot_.requiredRunSafeThrough
            ? BlockingStage::NeedContinuation
            : BlockingStage::NeedCompletion;
        return ExternalTimeWindowRuntimePollResult::Progress;
    }
    if (blockingStage_ == BlockingStage::NeedContinuation)
        return publishContinuation(error);
    if (blockingStage_ == BlockingStage::NeedCompletion) {
        ExternalTimeWindowLwCompletion completion;
        completion.readData = blockingReadData_;
        completion.haltArm9 = callbacks_.externalCPUHalted(true);
        completion.haltArm7 = callbacks_.externalCPUHalted(false);
        if (!control_.publishCompletion(
                blockingSnapshot_, completion, error))
            return fail(error, "ETW1 completion publication failed: " + error);
        blockingStage_ = BlockingStage::CompletionPublished;
        handledWork_ = true;
        handledGeneration_ = snapshot.generation;
        handledKind_ = snapshot.kind;
        return ExternalTimeWindowRuntimePollResult::Progress;
    }
    return ExternalTimeWindowRuntimePollResult::Waiting;
}

ExternalTimeWindowRuntimePollResult ExternalTimeWindowRuntime::pollImpl(
    std::string& error)
{
    error.clear();
    if (faulted_)
        return fail(error, "external time-window runtime is faulted");
    if (!sessionStarted_ || !producer_.active())
        return fail(error, "external time-window runtime has no active session");

    ExternalTimeWindowLwSnapshot snapshot;
    const auto read = control_.readSnapshot(snapshot, error);
    if (read == ExternalTimeWindowLwReadResult::Fault)
        return fail(error, error);
    if (read == ExternalTimeWindowLwReadResult::Retry)
        return ExternalTimeWindowRuntimePollResult::Waiting;

    if (ordinaryReceiptPending_) {
        const auto receipt = finishReceipt(snapshot, error);
        if (receipt != ExternalTimeWindowRuntimePollResult::Idle)
            return receipt;
    }

    if (read == ExternalTimeWindowLwReadResult::Idle) {
        if (blockingStage_ == BlockingStage::CompletionPublished) {
            retireCompletedBlockingTransaction();
        } else if (blockingStage_ != BlockingStage::None) {
            return fail(error, "ETW1 blocking work disappeared before completion");
        }
        return ExternalTimeWindowRuntimePollResult::Idle;
    }
    if (read != ExternalTimeWindowLwReadResult::Work)
        return fail(error, "ETW1 snapshot returned an unknown result");

    if (blockingStage_ == BlockingStage::CompletionPublished &&
        snapshot.generation != blockingSnapshot_.generation) {
        // IDLE is only a one-clock seam state and userspace may never sample
        // it. A direct successor, or FREEZE superseding one transient REFILL,
        // is equally strong evidence: the FPGA cannot publish either until it
        // has consumed the prior completion and released that requester.
        if (!isCompletionReleaseSuccessor(
                blockingSnapshot_.generation, snapshot.generation))
            return fail(
                error,
                "ETW1 work generation skipped while retiring completion");
        retireCompletedBlockingTransaction();
    }

    if (handledWork_ && snapshot.generation == handledGeneration_ &&
        snapshot.kind != handledKind_ &&
        !(handledKind_ == ExternalTimeWindowLwWorkKind::Descriptor &&
          snapshot.kind == ExternalTimeWindowLwWorkKind::WaitRelease))
        return fail(error, "ETW1 work kind changed without a new generation");

    switch (snapshot.kind) {
    case ExternalTimeWindowLwWorkKind::Refill:
        return serviceRefill(snapshot, error);
    case ExternalTimeWindowLwWorkKind::Freeze:
        return serviceFreeze(snapshot, error);
    case ExternalTimeWindowLwWorkKind::Descriptor:
        return serviceDescriptor(snapshot, error);
    case ExternalTimeWindowLwWorkKind::WaitRelease:
        return blockingStage_ == BlockingStage::CompletionPublished
            ? ExternalTimeWindowRuntimePollResult::Waiting
            : fail(error, "ETW1 entered wait-release before completion");
    case ExternalTimeWindowLwWorkKind::None:
        break;
    }
    return fail(error, "ETW1 work kind is invalid");
}

ExternalTimeWindowRuntimePollResult ExternalTimeWindowRuntime::poll(
    std::string& error) noexcept
{
    try {
        return pollImpl(error);
    } catch (const std::exception& exception) {
        faulted_ = true;
        try {
            error = "external time-window runtime callback threw: ";
            error += exception.what();
        } catch (...) {
        }
        return ExternalTimeWindowRuntimePollResult::Fault;
    } catch (...) {
        faulted_ = true;
        setError(
            error,
            "external time-window runtime callback threw an unknown exception");
        return ExternalTimeWindowRuntimePollResult::Fault;
    }
}

} // namespace nds4mister
