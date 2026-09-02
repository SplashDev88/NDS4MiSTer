#pragma once

#include "replay/ConsumedCreditAckDdrProducer.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

namespace nds4mister {

// One exact, globally ordered IRQ transition closed at a scheduler boundary.
// Timestamps are carried here for producer-side validation, but are implicit
// in the DDR ABI: every event in a group occurs at that group's P frontier.
struct ExternalTimeWindowDdrEvent {
    std::uint32_t sequence = 0;
    std::uint64_t timestamp = 0;
    bool arm9 = false;
    bool set = false;
    std::uint32_t mask = 0;
};

// Atomic result returned by the scheduler-closure callback. P is the inclusive
// processed frontier and R is the inclusive frontier through which both FPGA
// CPUs may run. events is the complete exact-order suffix ending at
// lastEventSequence.
struct ExternalTimeWindowDdrGroup {
    std::uint64_t processedThroughInclusive = 0;
    std::uint64_t runSafeThroughInclusive = 0;
    std::uint32_t lastEventSequence = 0;
    std::vector<ExternalTimeWindowDdrEvent> events;
};

struct ExternalTimeWindowDdrReceipt {
    std::uint32_t epoch = 0;
    std::uint32_t groupSequence = 0;
};

// Immutable identity captured when the FPGA admits one exact blocking MMIO
// request.  eventCount is the reserved event capacity, not the actual result
// count: the
// producer proves both the physical group slot and the complete event suffix
// fit before it invokes the irreversible scheduler/model closure.
struct ExternalTimeWindowDdrBarrierIdentity {
    std::uint32_t epoch = 0;
    std::uint32_t activeGrantGroupSequence = 0;
    std::uint32_t barrierSequence = 0;
    std::uint32_t sourceSequence = 0;
    std::uint64_t verifiedProducerFence = 0;
    std::uint64_t barrierTimestamp = 0;
    bool requesterArm9 = false;
    std::uint64_t requiredRunSafeThrough = 0;
    std::uint32_t priorEventHighWater = 0;
    std::uint8_t eventCount = 0;
};

// Exact result of applying the one blocking MMIO access and closing all of
// its equal-B effects.  identity must echo the admitted descriptor byte for
// field-for-field, including the requester CPU and its exact required
// continuation frontier. group.P must equal B; group.R may legally be lower
// than both the old R and identity.requiredRunSafeThrough, but may never be
// lower than B.
// The consumer continues toward the immutable required frontier before it
// releases the retained requester. group.events may use any prefix of the
// reserved identity.eventCount capacity.
struct ExternalTimeWindowDdrBarrierReplacement {
    ExternalTimeWindowDdrBarrierIdentity identity;
    ExternalTimeWindowDdrGroup group;
};

struct ExternalTimeWindowDdrLayout {
    std::size_t groupCount = 64;
    std::size_t headerWords64 = 8;
    std::size_t consumerWordOffset = 0;
    std::size_t descriptorWordOffset = 1;
    // Zero keeps the original 21-word ETWQ ABI exactly.  A nonzero offset
    // enables one nine-word replacement extension per ordinary group slot;
    // it must begin after the complete ordinary ring.
    std::size_t barrierReplacementWordOffset = 0;
};

enum class ExternalTimeWindowDdrPublishResult {
    Published,
    NoAdvance,
    Backpressured,
    SessionNotReady,
    Exhausted,
    Fault,
};

enum class ExternalTimeWindowDdrProducerFault {
    None,
    InvalidLayout,
    InvalidEpoch,
    EpochReuse,
    ActiveSession,
    SessionReset,
    EpochMismatch,
    ConsumerMovedBackward,
    ConsumerMovedAhead,
    CallbackFailed,
    RunSafeBeforeProcessed,
    ProcessedThroughRegressed,
    RunSafeThroughRegressed,
    TooManyEvents,
    InvalidEvent,
    EventSequenceMismatch,
    EventHighWaterMismatch,
    LateEvent,
    EventSequenceExhausted,
    TransportFailureAfterClosure,
    BarrierReplacementUnavailable,
    BarrierNoActiveGrant,
    BarrierEpochMismatch,
    BarrierActiveGroupMismatch,
    BarrierSequenceMismatch,
    BarrierSourceMismatch,
    BarrierFenceMismatch,
    BarrierTimestampMismatch,
    BarrierRequesterMismatch,
    BarrierRequiredRunSafeMismatch,
    BarrierPriorEventMismatch,
    BarrierEventCapacityMismatch,
};

// Simulator-only HPS producer for an atomic fixed-slot external-time-window
// queue. It is deliberately absent from HpsOracleResponder and all RTL.
//
// Layout, in 64-bit words:
//
//   header[consumerWordOffset]   = {epoch, consumer_group_sequence}
//   header[descriptorWordOffset] = {0x45545751 ("ETWQ"), epoch}
//
// Each power-of-two physical group slot occupies 21 words:
//
//   +0       = P (processed-through inclusive)
//   +1       = R (run-safe-through inclusive)
//   +2       = {last_event_sequence, 24'd0, event_count[7:0]}
//   +3       = {32'd0, event_control_bitmap}
//   +4..+19  = {event_mask, event_sequence}, unused entries are zero
//   +20      = {epoch, group_sequence_commit} // low commit written last
//
// Bitmap bit 2*i selects ARM9 (zero selects ARM7); bit 2*i+1 selects SET
// (zero selects CLEAR). Event order is array order, and every timestamp is
// implicitly P. A producer reserves one free group before invoking close().
// Payload and unused event words are cleaned before a single release-store of
// the low 32-bit group commit. FPGA consumer ACK in header word 0 is the sole
// durable capacity/consumption truth. Once that low commit is published, the
// descriptor, commit high half, and every payload word are immutable until
// the matching consumer-header ACK is observed; no finite FPGA reread can
// compensate for a producer that violates this transport contract. More than
// sixteen transitions cannot be
// represented by this ABI: discovering that after close() poisons the epoch,
// publishes no partial group, and requires resetAfterModelReset(). Integration
// must therefore choose/prove a closure cadence that stays within this bound;
// sixteen is not assumed sufficient for an arbitrary scheduler interval.
//
// An optional, separately located nine-word extension turns one otherwise
// byte-identical ordinary group into an exact blocking-barrier replacement:
//
//   +0 = {0x42525250 ("BRRP"), 16'd0, reserved_count[7:0], count[7:0]}
//   +1 = {barrier_sequence, active_grant_group_sequence}
//   +2 = {32'd0, source_sequence}
//   +3 = verified_producer_fence[63:0]
//   +4 = B
//   +5 = {replacement_last_event_sequence, prior_event_high_water}
//   +6 = {epoch, 31'd0, requester_arm9}
//   +7 = required_run_safe_through[63:0]
//   +8 = {epoch, group_sequence_commit}
//
// The extension commit is made visible first.  The unchanged ordinary group
// low commit remains the sole final publication point, so a consumer can
// never observe a replacement whose identity payload is incomplete.  A
// matching extension sequence marks replacement mode; a stale extension from
// an older physical-slot use cannot relabel a later ordinary group.  The
// ordinary consumer ACK remains the sole durable reuse/capacity watermark.
class ExternalTimeWindowDdrProducer {
public:
    static constexpr std::uint32_t kDescriptorMagic = 0x45545751u;
    static constexpr std::uint32_t kBarrierReplacementMagic = 0x42525250u;
    static constexpr std::size_t kWordsPerGroup = 21;
    static constexpr std::size_t kWordsPerBarrierReplacement = 9;
    static constexpr std::size_t kMaxEvents = 16;

    explicit ExternalTimeWindowDdrProducer(
        ConsumedCreditAckDdrMemory& memory,
        ExternalTimeWindowDdrLayout layout = {});

    bool beginSession(std::uint32_t epoch, bool transportQuiescent);
    void stopSession();
    // A transport/protocol/callback fault is sticky because the scheduler
    // closure may already have changed emulator state. Only an explicit proof
    // that both the model was reset and the transport is quiescent can clear
    // it. The last epoch remains reserved and cannot be reused.
    bool resetAfterModelReset(bool modelReset, bool transportQuiescent);
    bool sessionReady();

    ExternalTimeWindowDdrPublishResult publish(
        const std::function<ExternalTimeWindowDdrGroup()>& close,
        ExternalTimeWindowDdrReceipt& receipt);

    // Publishes one dedicated replacement record.  expected is the immutable
    // FPGA admission descriptor; close must return an exact echo plus P=B,
    // requiredRunSafeThrough>=B, Rnew>=B (Rnew may still be below required),
    // and a gap-free equal-B event suffix no larger than the reserved
    // identity.eventCount capacity. Capacity,
    // session identity, no-wrap, and the active grant are all checked before
    // close is invoked.  Any callback/transport/returned-data fault poisons
    // the epoch, so an irreversible access can never be retried.
    ExternalTimeWindowDdrPublishResult publishBarrierReplacement(
        const ExternalTimeWindowDdrBarrierIdentity& expected,
        const std::function<ExternalTimeWindowDdrBarrierReplacement()>& close,
        ExternalTimeWindowDdrReceipt& receipt);

    // Non-mutating receipt poll. It triple-samples both descriptor and
    // consumer control and never latches a transport fault.
    bool consumedThrough(const ExternalTimeWindowDdrReceipt& receipt) const;

    // Deterministic no-wrap/physical-wrap regression hook. Live sessions
    // begin all sequences at zero and never call this helper.
    void seedSequencesForSelfTest(
        std::uint32_t producerGroupSequence,
        std::uint32_t consumerGroupSequence,
        std::uint32_t lastEventSequence,
        std::uint64_t processedThroughInclusive,
        std::uint64_t runSafeThroughInclusive,
        bool haveWindow);

    bool active() const { return active_; }
    bool ready() const { return ready_; }
    bool exhausted() const {
        return groupSequenceExhausted_ || eventSequenceExhausted_;
    }
    std::uint32_t epoch() const { return epoch_; }
    std::uint32_t producerGroupSequence() const {
        return producerGroupSequence_;
    }
    std::uint32_t consumerGroupSequence() const {
        return consumerGroupSequence_;
    }
    std::uint32_t lastEventSequence() const {
        return lastEventSequence_;
    }
    std::uint64_t processedThroughInclusive() const {
        return processedThroughInclusive_;
    }
    std::uint64_t runSafeThroughInclusive() const {
        return runSafeThroughInclusive_;
    }
    ExternalTimeWindowDdrProducerFault fault() const { return fault_; }
    std::size_t requiredWords() const { return requiredWords_; }

private:
    bool validateLayout();
    bool validateDescriptor();
    bool refreshConsumer();
    ExternalTimeWindowDdrPublishResult latch(
        ExternalTimeWindowDdrProducerFault fault);
    void poisonCallbackFailure();
    void poisonTransportFailureAfterClosure();
    std::size_t groupBase(std::uint32_t groupSequence) const;
    bool validateGroup(
        const ExternalTimeWindowDdrGroup& group,
        ExternalTimeWindowDdrPublishResult& result) const;
    bool validateBarrierIdentityBeforeClosure(
        const ExternalTimeWindowDdrBarrierIdentity& identity,
        ExternalTimeWindowDdrProducerFault& fault) const;
    bool validateBarrierReplacement(
        const ExternalTimeWindowDdrBarrierIdentity& expected,
        const ExternalTimeWindowDdrBarrierReplacement& replacement,
        ExternalTimeWindowDdrProducerFault& fault) const;
    void writeGroup(
        std::uint32_t groupSequence,
        const ExternalTimeWindowDdrGroup& group);
    std::size_t barrierReplacementBase(
        std::uint32_t groupSequence) const;
    void writeBarrierReplacementExtension(
        std::uint32_t groupSequence,
        const ExternalTimeWindowDdrBarrierReplacement& replacement);

    ConsumedCreditAckDdrMemory& memory_;
    ExternalTimeWindowDdrLayout layout_;
    std::size_t requiredWords_ = 0;
    std::uint32_t epoch_ = 0;
    std::uint32_t lastEpoch_ = 0;
    std::uint32_t producerGroupSequence_ = 0;
    std::uint32_t consumerGroupSequence_ = 0;
    std::uint32_t lastEventSequence_ = 0;
    std::uint64_t processedThroughInclusive_ = 0;
    std::uint64_t runSafeThroughInclusive_ = 0;
    std::uint32_t lastBarrierSequence_ = 0;
    std::uint32_t lastBarrierSourceSequence_ = 0;
    std::uint64_t lastBarrierVerifiedProducerFence_ = 0;
    ExternalTimeWindowDdrProducerFault fault_ =
        ExternalTimeWindowDdrProducerFault::None;
    bool layoutValid_ = false;
    bool active_ = false;
    bool ready_ = false;
    bool haveWindow_ = false;
    bool groupSequenceExhausted_ = false;
    bool eventSequenceExhausted_ = false;
};

} // namespace nds4mister
