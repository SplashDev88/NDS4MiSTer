#pragma once

#include "replay/ExternalTimeWindowDdrBridge.h"
#include "replay/ExternalTimeWindowLwControl.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace nds4mister {

enum class ExternalTimeWindowRuntimePollResult {
    Idle,
    Waiting,
    Progress,
    Fault,
};

// The production responder supplies these callbacks directly from
// MelonDsBackend and its verified posted-write consumer. Keeping the cadence
// state machine independent of /dev/mem makes its irreversible ordering and
// retry boundaries deterministic under a native host test.
struct ExternalTimeWindowRuntimeCallbacks {
    std::function<bool(bool, std::uint64_t, std::string&)>
        reportCPUReached;
    std::function<std::size_t()> pendingIRQTransitions;
    std::function<bool(
        std::uint64_t,
        std::uint64_t,
        const ExternalTimeWindowReplacement&,
        ExternalTimeWindowDdrClosureOutput&,
        std::string&)>
        closeWindow;
    std::function<bool(
        const ExternalBlockingMMIORequest&,
        std::uint64_t,
        const ExternalTimeWindowReplacement&,
        ExternalBlockingMMIOCompletion&,
        std::string&)>
        executeBlockingMMIO;
    std::function<bool(bool)> externalCPUHalted;
    // The 64-bit fence is {session_epoch, raw_posted_sequence}. The callback
    // must drain and durably ACK exactly that raw sequence before returning.
    std::function<bool(std::uint64_t, std::uint64_t&, std::string&)>
        drainVerifiedPostedFence;
    std::function<bool(bool, std::string&)> setModelEnabled;
};

// Single-threaded HPS cadence for the ETW1 LW control plane and ETWQ/BRRP DDR
// transport. Every model-changing callback is reached only after producer
// capacity/session preflight. A fault is sticky; this object never retries an
// irreversible closure.
class ExternalTimeWindowRuntime {
public:
    static constexpr std::uint64_t kDefaultFiniteLookahead = 1u << 20;

    ExternalTimeWindowRuntime(
        ExternalTimeWindowLwControl& control,
        ExternalTimeWindowDdrProducer& producer,
        ExternalTimeWindowRuntimeCallbacks callbacks,
        std::uint64_t finiteLookahead = kDefaultFiniteLookahead);

    // Must run while LW admission is still disarmed. DDR is initialized first;
    // only then is the model observer enabled. The caller may ARM the LW
    // session after this succeeds.
    bool beginSession(
        std::uint32_t epoch,
        bool transportQuiescent,
        std::string& error);

    ExternalTimeWindowRuntimePollResult poll(std::string& error) noexcept;

    bool faulted() const noexcept { return faulted_; }
    bool initialGrantConsumed() const noexcept {
        return initialGrantConsumed_;
    }
    std::size_t maxObservedGroupEventCount() const noexcept {
        return maxObservedGroupEventCount_;
    }
    std::uint32_t epoch() const noexcept { return epoch_; }

    static bool decodeEpochScopedFence(
        std::uint64_t fence,
        std::uint32_t expectedEpoch,
        std::uint32_t& rawPostedSequence) noexcept;
private:
    enum class BlockingStage {
        None,
        WaitReplacementReceipt,
        NeedContinuation,
        WaitContinuationReceipt,
        NeedCompletion,
        CompletionPublished,
    };

    ExternalTimeWindowRuntimePollResult fail(
        std::string& error,
        const std::string& message) noexcept;
    ExternalTimeWindowRuntimePollResult serviceRefill(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error);
    ExternalTimeWindowRuntimePollResult serviceFreeze(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error);
    ExternalTimeWindowRuntimePollResult serviceDescriptor(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error);
    ExternalTimeWindowRuntimePollResult publishContinuation(
        std::string& error);
    ExternalTimeWindowRuntimePollResult finishReceipt(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error);
    ExternalTimeWindowRuntimePollResult pollImpl(std::string& error);
    bool validateSnapshotEpochAndFence(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error) const;
    bool closeOrdinary(
        std::uint64_t target,
        std::uint64_t finiteBound,
        const ExternalTimeWindowReplacement& replacement,
        ExternalTimeWindowDdrClosureOutput& output,
        std::string& error);
    void retireCompletedBlockingTransaction() noexcept;
    std::uint64_t ordinaryFiniteBound(std::uint64_t target) const noexcept;
    void observeGroupEventCount(std::size_t count) noexcept;

    ExternalTimeWindowLwControl& control_;
    ExternalTimeWindowDdrProducer& producer_;
    ExternalTimeWindowRuntimeCallbacks callbacks_;
    std::uint64_t finiteLookahead_ = kDefaultFiniteLookahead;
    std::uint32_t epoch_ = 0;
    bool sessionStarted_ = false;
    bool faulted_ = false;
    bool initialGrantConsumed_ = false;
    std::size_t maxObservedGroupEventCount_ = 0;

    bool handledWork_ = false;
    std::uint32_t handledGeneration_ = 0;
    ExternalTimeWindowLwWorkKind handledKind_ =
        ExternalTimeWindowLwWorkKind::None;

    bool ordinaryReceiptPending_ = false;
    std::uint32_t ordinaryGeneration_ = 0;
    ExternalTimeWindowDdrReceipt ordinaryReceipt_{};

    bool freezeAcknowledged_ = false;
    std::uint32_t freezeGeneration_ = 0;
    std::uint64_t freezeFence_ = 0;
    std::uint32_t lastBlockingBarrierSequence_ = 0;
    std::uint32_t lastBlockingSourceSequence_ = 0;

    BlockingStage blockingStage_ = BlockingStage::None;
    ExternalTimeWindowLwSnapshot blockingSnapshot_{};
    ExternalTimeWindowDdrReceipt blockingReceipt_{};
    std::uint32_t blockingReadData_ = 0;
    std::uint32_t blockingGroupSequence_ = 0;
    std::uint32_t blockingEventHighWater_ = 0;
    std::uint64_t blockingProcessedThrough_ = 0;
    std::uint64_t blockingRunSafeThrough_ = 0;
};

} // namespace nds4mister
