#pragma once

#include <cstddef>
#include <cstdint>

namespace nds4mister {

// Normalized packet written by rtl/nds_gx_ddr_command_ring.sv.
struct GxDdrCommand {
    std::uint8_t command = 0;
    std::uint32_t parameter = 0;
    std::uint32_t frame = 0;
    std::uint64_t timestamp = 0;
    std::uint32_t epoch = 0;
    std::uint64_t fence = 0;
};

struct GxDdrRingLayout {
    std::size_t entryCount = 1024;
    std::size_t headerWords64 = 8;
    std::size_t consumerWordOffset = 0;
};

// The consumer deliberately does not perform raw volatile or std::atomic
// accesses to /dev/mem itself.  The concrete MiSTer mapping must implement
// these operations for the memory type selected by the kernel/page tables:
//
// * invalidateDeviceWrites() makes FPGA writes visible before a later load.
// * loadAcquire() is an aligned 64-bit acquire load.
// * loadRelaxed() is an aligned 64-bit payload load ordered after an acquire.
// * storeRelease() is an aligned 64-bit release store.
// * cleanCpuWrites() makes the stored consumer fence visible to the FPGA and
//   includes the platform completion barrier required by the mapping.
//
// A normal cached mapping is NOT sufficient unless invalidate/clean perform
// the required cache maintenance.  An uncached/device mapping may implement
// invalidate/clean as the platform's required barriers.  The mapped base and
// every word must be naturally aligned to 64 bits.
class GxDdrWordMemory {
public:
    virtual ~GxDdrWordMemory() = default;

    virtual std::size_t wordCount() const = 0;
    virtual void invalidateDeviceWrites(std::size_t firstWord,
                                        std::size_t wordCount) = 0;
    virtual std::uint64_t loadAcquire(std::size_t word) = 0;
    virtual std::uint64_t loadRelaxed(std::size_t word) = 0;
    virtual void storeRelease(std::size_t word, std::uint64_t value) = 0;
    virtual void cleanCpuWrites(std::size_t firstWord,
                                std::size_t wordCount) = 0;
};

enum class GxDdrDispatchResult {
    Accepted,
    Fatal,
};

class GxDdrCommandSink {
public:
    virtual ~GxDdrCommandSink() = default;

    // This readiness query must have no externally visible side effects.
    // Returning false leaves the packet committed and unacknowledged so a
    // later poll can retry readiness without applying the command twice.
    virtual bool ready(const GxDdrCommand& command) = 0;

    // Dispatch is final: implementations must either apply the command once
    // and return Accepted, or apply nothing and return Fatal.  There is no
    // post-dispatch retry state.
    virtual GxDdrDispatchResult dispatch(const GxDdrCommand& command) = 0;
};

enum class GxDdrPollResult {
    Empty,
    Dispatched,
    Retry,
    Fault,
};

enum class GxDdrConsumerFault {
    None,
    NotStarted,
    InvalidLayout,
    DirtySessionControl,
    DirtySessionCommit,
    SessionReset,
    ConsumerControlAdvanced,
    FutureCommit,
    CommitChanged,
    EpochMismatch,
    ReservedPayloadBits,
    FenceExhausted,
    DispatcherRejected,
};

// Fail-closed consumer for the four-beat commit-last RTL ABI.
//
// Session lifecycle is externally serialized:
//   1. Stop this consumer and hold the FPGA producer in reset.
//   2. Zero the consumer word and every slot commit word, including all
//      required cache clean/barrier operations.
//   3. beginSession(epoch), then release the producer reset.
//
// beginSession verifies the zeroed state.  During a session, any backward
// consumer control movement is treated as a reset and latches a fault.  This
// detects resets observed at polling boundaries.  The present RTL ABI has no
// atomic shared session-generation word, so software and FPGA reset must not
// race the final acknowledgement; an epoch field inside a packet cannot close
// that race.
class GxDdrRingConsumer {
public:
    explicit GxDdrRingConsumer(GxDdrWordMemory& memory,
                               GxDdrRingLayout layout = {});

    bool beginSession(std::uint32_t expectedEpoch);
    void stopSession();

    GxDdrPollResult poll(GxDdrCommandSink& sink);

    // Protocol helper used by poll; exposed so the no-wrap terminal fence
    // invariant can be regression-tested without processing 2^64 packets.
    static bool nextFence(std::uint64_t current,
                          std::uint64_t& next) noexcept;

    bool active() const { return active_; }
    GxDdrConsumerFault fault() const { return fault_; }
    std::uint64_t consumerFence() const { return consumerFence_; }
    std::uint32_t expectedEpoch() const { return expectedEpoch_; }
    std::size_t requiredWords() const { return requiredWords_; }

private:
    bool validateLayout();
    bool validateControl();
    GxDdrPollResult latch(GxDdrConsumerFault fault);
    std::size_t commitWord(std::size_t slot) const;

    GxDdrWordMemory& memory_;
    GxDdrRingLayout layout_;
    std::size_t requiredWords_ = 0;
    std::uint64_t consumerFence_ = 0;
    std::uint32_t expectedEpoch_ = 0;
    GxDdrConsumerFault fault_ = GxDdrConsumerFault::NotStarted;
    bool layoutValid_ = false;
    bool active_ = false;
};

} // namespace nds4mister
