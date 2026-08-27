#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

namespace nds4mister {

// Physical, reverse-direction transport model for credits consumed by the HPS
// Nintendo DS model.  This ABI is simulator-only and is not instantiated by
// HpsOracleResponder or the MiSTer top.
enum class ConsumedCreditAckKind : std::uint8_t {
    Posted = 0,
    Mailbox = 1,
    Halt = 2,
    IrqSet = 3,
};

struct ConsumedCreditAck {
    bool arm9 = false;
    std::uint32_t cycles = 0;
    ConsumedCreditAckKind kind = ConsumedCreditAckKind::Posted;
    std::uint32_t sourceId = 0;
};

// Coalesced IRQ causes captured on either side of one emulated bus apply.
// A zero mask emits no child record.  Nonzero masks are emitted ARM9 first,
// then ARM7, independently for the pre-apply and post-apply phases.
struct ConsumedCreditAckIrqMasks {
    std::uint32_t arm9 = 0;
    std::uint32_t arm7 = 0;
};

// Optional local FPGA IRQ-register bus boundary carried by a counted batch.
// access uses the core convention 0=byte, 1=halfword, 2=word.  payload is the
// right-justified write data for writes. For reads it is ignored: apply()
// returns the authoritative post-apply HPS result. Disabled metadata must
// remain all-zero/canonical.
struct ConsumedCreditAckIrqBoundary {
    bool enabled = false;
    bool readNotWrite = false;
    std::uint8_t access = 0;
    std::uint32_t address = 0;
    std::uint32_t payload = 0;
};

// A successful transaction publication returns the exact consumer watermark
// that makes the whole transaction durable.  Sequences never wrap within an
// epoch, so a simple >= comparison is sufficient after validating the epoch.
struct ConsumedCreditAckDdrReceipt {
    std::uint32_t epoch = 0;
    std::uint32_t baseSequence = 0;
    std::uint32_t finalSequence = 0;
};

struct ConsumedCreditAckDdrLayout {
    std::size_t entryCount = 1024;
    std::size_t headerWords64 = 8;
    std::size_t consumerWordOffset = 0;
    std::size_t descriptorWordOffset = 1;
};

// A concrete /dev/mem mapping must supply the cache maintenance and barriers
// appropriate to its mapping type.  Payload stores precede a release-store of
// the commit word; cleanCpuWrites() must make that ordering visible to FPGA.
class ConsumedCreditAckDdrMemory {
public:
    virtual ~ConsumedCreditAckDdrMemory() = default;

    virtual std::size_t wordCount() const = 0;
    virtual void invalidateFpgaWrites(std::size_t firstWord,
                                      std::size_t wordCount) = 0;
    virtual std::uint32_t loadAcquire32(std::size_t word,
                                        bool upperHalf) = 0;
    virtual void storeRelaxed64(std::size_t word,
                                std::uint64_t value) = 0;
    virtual void storeRelaxed32(std::size_t word,
                                bool upperHalf,
                                std::uint32_t value) = 0;
    virtual void storeRelease32(std::size_t word,
                                bool upperHalf,
                                std::uint32_t value) = 0;
    virtual void cleanCpuWrites(std::size_t firstWord,
                                std::size_t wordCount) = 0;
};

enum class ConsumedCreditAckPublishResult {
    Published,
    Backpressured,
    SessionNotReady,
    OrderingBlocked,
    Exhausted,
    Fault,
};

enum class ConsumedCreditAckProducerFault {
    None,
    InvalidLayout,
    InvalidEpoch,
    EpochReuse,
    ActiveSession,
    SessionReset,
    EpochMismatch,
    ConsumerMovedBackward,
    ConsumerMovedAhead,
    InvalidKind,
    PostedSourceGap,
    InvalidSourceId,
    InvalidBoundary,
    CallbackFailed,
};

// HPS producer for a three-beat, commit-last reverse shared-DDR ring.
//
// Layout, in 64-bit words:
//
//   header[consumerWordOffset]   = {epoch[31:0], consumer_sequence[31:0]}
//   header[descriptorWordOffset] = {0x4341434b ("CACK"), epoch[31:0]}
//
//   entry + 0 = {cycles[31:0], source_id[31:0]}
//   entry + 1 = {epoch[31:0], 16'd0, address_offset[4:0], access[1:0],
//                rnw, local_boundary, post_count[1:0], pre_count[1:0],
//                kind[1:0], cpu_arm9}
//   entry + 2 = {irq_payload[31:0], sequence[31:0]}
//                                                // low commit written last
//
// Child IRQ_SET entries use only cpu_arm9, kind=3, and bit 3 as post_phase.
// Every other transaction-metadata bit and the commit high half are zero.
//
// Session setup is externally serialized.  With both endpoints quiescent,
// beginSession() clears the ring, writes descriptor magic, then publishes its
// nonzero 32-bit epoch commit last.  FPGA
// scans the commit words and publishes {epoch,0} to the consumer word before
// sessionReady() can succeed.
//
// publish() refreshes capacity and validates mailbox/posting order before it
// invokes either callback.  It publishes an ACK only after advance() and
// apply() both return.  Thus a full ring or missing posted fence cannot change
// emulator time or bus state.
//
// publishTransaction() reserves five entries before invoking any callback:
// one base credit plus ARM9/ARM7 IRQ_SET children on either side of apply().
// advance() runs first, captureIrqs() supplies the pre-apply masks, apply()
// establishes the bus boundary and returns its authoritative read result,
// then captureIrqs() supplies post-apply masks. The return is serialized only
// for an enabled read boundary; write payload remains boundary.payload and a
// disabled boundary remains canonical zero metadata.
// Child payloads and commits are made visible before the base commit, so an
// FPGA consumer can never observe a partially published counted transaction.
class ConsumedCreditAckDdrProducer {
public:
    static constexpr std::uint32_t kDescriptorMagic = 0x4341434b;
    static constexpr std::uint32_t kPreCountShift = 3;
    static constexpr std::uint32_t kPostCountShift = 5;
    static constexpr std::uint32_t kLocalBoundaryBit = 7;
    static constexpr std::uint32_t kReadNotWriteBit = 8;
    static constexpr std::uint32_t kAccessShift = 9;
    static constexpr std::uint32_t kAddressOffsetShift = 11;
    static constexpr std::uint32_t kChildPostPhaseBit = 3;
    static constexpr std::uint32_t kIrqRegisterBase = 0x04000200;
    static constexpr std::size_t kMaxTransactionEntries = 5;

    explicit ConsumedCreditAckDdrProducer(
        ConsumedCreditAckDdrMemory& memory,
        ConsumedCreditAckDdrLayout layout = {});

    bool beginSession(std::uint32_t epoch, bool transportQuiescent);
    void stopSession();
    bool sessionReady();

    ConsumedCreditAckPublishResult publish(
        const ConsumedCreditAck& ack,
        std::uint32_t requiredPostedSource,
        const std::function<void()>& advance,
        const std::function<void()>& apply);

    ConsumedCreditAckPublishResult publishTransaction(
        const ConsumedCreditAck& ack,
        std::uint32_t requiredPostedSource,
        const ConsumedCreditAckIrqBoundary& boundary,
        const std::function<void()>& advance,
        const std::function<std::uint32_t()>& apply,
        const std::function<ConsumedCreditAckIrqMasks()>& captureIrqs,
        ConsumedCreditAckDdrReceipt& receipt);

    // Samples the descriptor and FPGA consumer watermark without changing
    // producer state or invoking model callbacks.  False covers both a pending
    // valid receipt and any stale/malformed/session-mismatched receipt; the
    // next stateful operation remains responsible for latching transport
    // faults.
    bool consumedThrough(
        const ConsumedCreditAckDdrReceipt& receipt) const;

    // Deterministic no-wrap regression hook.  Live sessions always begin at
    // sequence zero and never call this helper.
    void seedSequenceForSelfTest(std::uint32_t producerSequence,
                                 std::uint32_t consumerSequence,
                                 std::uint32_t lastPostedSource);

    bool active() const { return active_; }
    bool ready() const { return ready_; }
    bool exhausted() const { return exhausted_; }
    std::uint32_t epoch() const { return epoch_; }
    std::uint32_t producerSequence() const { return producerSequence_; }
    std::uint32_t consumerSequence() const { return consumerSequence_; }
    std::uint32_t lastPostedSource() const { return lastPostedSource_; }
    ConsumedCreditAckProducerFault fault() const { return fault_; }
    std::size_t requiredWords() const { return requiredWords_; }

private:
    static constexpr std::size_t kWordsPerEntry = 3;

    bool validateLayout();
    bool refreshConsumer();
    ConsumedCreditAckPublishResult latch(
        ConsumedCreditAckProducerFault fault);
    std::size_t entryBase(std::uint32_t sequence) const;
    std::size_t commitWord(std::size_t slot) const;
    bool validateDescriptor();
    bool validateAckAndFence(
        const ConsumedCreditAck& ack,
        std::uint32_t requiredPostedSource,
        ConsumedCreditAckPublishResult& result);
    void poisonCallbackFailure();
    void writeEntryPayload(
        std::uint32_t sequence,
        const ConsumedCreditAck& ack,
        std::uint32_t transactionBits,
        std::uint32_t commitPayload);
    void commitEntry(std::uint32_t sequence);
    bool validateBoundary(
        const ConsumedCreditAck& ack,
        const ConsumedCreditAckIrqBoundary& boundary);

    ConsumedCreditAckDdrMemory& memory_;
    ConsumedCreditAckDdrLayout layout_;
    std::size_t requiredWords_ = 0;
    std::uint32_t epoch_ = 0;
    std::uint32_t lastEpoch_ = 0;
    std::uint32_t producerSequence_ = 0;
    std::uint32_t consumerSequence_ = 0;
    std::uint32_t lastPostedSource_ = 0;
    ConsumedCreditAckProducerFault fault_ =
        ConsumedCreditAckProducerFault::None;
    bool layoutValid_ = false;
    bool active_ = false;
    bool ready_ = false;
    bool exhausted_ = false;
};

} // namespace nds4mister
