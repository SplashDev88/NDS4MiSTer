#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace nds4mister {

enum class ExternalTimeWindowLwWorkKind {
    None,
    Refill,
    Freeze,
    Descriptor,
    WaitRelease,
};

enum class ExternalTimeWindowLwReadResult {
    Idle,
    Retry,
    Work,
    Fault,
};

struct ExternalTimeWindowLwSnapshot {
    ExternalTimeWindowLwWorkKind kind =
        ExternalTimeWindowLwWorkKind::None;
    std::uint32_t status = 0;
    std::uint32_t generation = 0;
    std::uint32_t epoch = 0;
    std::uint32_t groupSequence = 0;
    std::uint64_t processedThrough = 0;
    std::uint64_t runSafeThrough = 0;
    std::uint32_t eventHighWater = 0;
    std::uint32_t barrierSequence = 0;
    std::uint32_t sourceSequence = 0;
    std::uint64_t verifiedProducerFence = 0;
    std::uint8_t reservedEventCount = 0;
    bool arm9 = false;
    bool readNotWrite = false;
    std::uint8_t access = 0;
    std::uint32_t address = 0;
    std::uint32_t writeData = 0;
    std::uint32_t executionPC = 0;
    std::uint64_t arm9Timestamp = 0;
    std::uint64_t arm7Timestamp = 0;
    std::uint64_t requiredRunSafeThrough = 0;
};

struct ExternalTimeWindowLwCompletion {
    std::uint32_t readData = 0;
    bool haltArm9 = false;
    bool haltArm7 = false;
};

// HPS-side access to the commit-last ETW1 lightweight-register extension.
// It never caches a snapshot: each read is generation-bracketed, and every
// control/completion write is bound to the exact immutable generation.
class ExternalTimeWindowLwControl {
public:
    static constexpr std::size_t kRequiredWords = 63;
    static constexpr std::uint32_t kAbiMagic = 0x45545731u; // ETW1
    static constexpr std::uint32_t kCompletionMagic = 0x434f4d50u; // COMP

    ExternalTimeWindowLwControl(
        volatile std::uint32_t* words,
        std::size_t wordCount) noexcept;

    ExternalTimeWindowLwReadResult readSnapshot(
        ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error) const noexcept;

    bool acknowledgeFreeze(
        const ExternalTimeWindowLwSnapshot& snapshot,
        std::string& error) const noexcept;

    bool publishCompletion(
        const ExternalTimeWindowLwSnapshot& snapshot,
        const ExternalTimeWindowLwCompletion& completion,
        std::string& error) const noexcept;

private:
    bool available(std::string& error) const noexcept;
    volatile std::uint32_t* words_ = nullptr;
    std::size_t wordCount_ = 0;
};

} // namespace nds4mister
