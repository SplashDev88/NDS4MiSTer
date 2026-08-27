#include "replay/ExternalTimeWindowLwControl.h"

namespace nds4mister {
namespace {

constexpr std::size_t kStatus = 27;
constexpr std::size_t kGeneration = 28;
constexpr std::size_t kControlGeneration = 29;
constexpr std::size_t kControlCommit = 30;
constexpr std::size_t kAbi = 31;
constexpr std::size_t kSnapshotFirst = 32;
constexpr std::size_t kCompletionFirst = 53;
constexpr std::size_t kCompletionCommit = 62;

constexpr std::uint32_t kStatusSession = 1u << 0;
constexpr std::uint32_t kStatusFault = 1u << 8;
constexpr unsigned kStatusStateShift = 9;
constexpr std::uint32_t kStatusStateMask = 7u;

constexpr std::uint64_t join(
    std::uint32_t low,
    std::uint32_t high) noexcept
{
    return static_cast<std::uint64_t>(low) |
        (static_cast<std::uint64_t>(high) << 32);
}

void setError(std::string& error, const char* message) noexcept {
    try {
        error = message;
    } catch (...) {
    }
}

void deviceFence() noexcept {
    __sync_synchronize();
}

} // namespace

ExternalTimeWindowLwControl::ExternalTimeWindowLwControl(
    volatile std::uint32_t* words,
    std::size_t wordCount) noexcept
    : words_(words), wordCount_(wordCount)
{
}

bool ExternalTimeWindowLwControl::available(std::string& error) const noexcept {
    if (!words_ || wordCount_ < kRequiredWords) {
        setError(error, "ETW1 lightweight register mapping is too small");
        return false;
    }
    if (words_[kAbi] != kAbiMagic) {
        setError(error, "ETW1 lightweight ABI magic mismatch");
        return false;
    }
    return true;
}

ExternalTimeWindowLwReadResult
ExternalTimeWindowLwControl::readSnapshot(
    ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error) const noexcept
{
    snapshot = {};
    error.clear();
    if (!available(error)) return ExternalTimeWindowLwReadResult::Fault;

    const std::uint32_t statusBefore = words_[kStatus];
    if ((statusBefore & kStatusFault) != 0) {
        setError(error, "FPGA ETW1 control path reported a protocol fault");
        return ExternalTimeWindowLwReadResult::Fault;
    }
    if ((statusBefore & kStatusSession) == 0)
        return ExternalTimeWindowLwReadResult::Idle;

    const auto state =
        (statusBefore >> kStatusStateShift) & kStatusStateMask;
    if (state == 0)
        return ExternalTimeWindowLwReadResult::Idle;
    if (state >= 5) {
        setError(error, "FPGA ETW1 control state is invalid or faulted");
        return ExternalTimeWindowLwReadResult::Fault;
    }
    const bool stateBitsCoherent =
        ((statusBefore & (1u << 1)) != 0) == (state == 1) &&
        ((statusBefore & (1u << 2)) != 0) == (state == 2) &&
        ((statusBefore & (1u << 4)) != 0) == (state == 3);
    if (!stateBitsCoherent) {
        setError(error, "FPGA ETW1 status/state bits are incoherent");
        return ExternalTimeWindowLwReadResult::Fault;
    }

    const std::uint32_t generationBefore = words_[kGeneration];
    if (generationBefore == 0) {
        setError(error, "FPGA ETW1 work state has generation zero");
        return ExternalTimeWindowLwReadResult::Fault;
    }

    std::uint32_t payload[21]{};
    deviceFence();
    for (std::size_t index = 0; index < 21; ++index)
        payload[index] = words_[kSnapshotFirst + index];
    deviceFence();
    const std::uint32_t generationAfter = words_[kGeneration];
    const std::uint32_t statusAfter = words_[kStatus];
    if (generationBefore != generationAfter || statusBefore != statusAfter)
        return ExternalTimeWindowLwReadResult::Retry;

    snapshot.status = statusBefore;
    snapshot.generation = generationBefore;
    snapshot.epoch = payload[0];
    snapshot.groupSequence = payload[1];
    snapshot.processedThrough = join(payload[2], payload[3]);
    snapshot.runSafeThrough = join(payload[4], payload[5]);
    snapshot.eventHighWater = payload[6];
    snapshot.barrierSequence = payload[7];
    snapshot.sourceSequence = payload[8];
    snapshot.verifiedProducerFence = join(payload[9], payload[10]);
    const std::uint32_t meta = payload[11];
    snapshot.arm9 = (meta & 1u) != 0;
    snapshot.readNotWrite = (meta & 2u) != 0;
    snapshot.access = static_cast<std::uint8_t>((meta >> 2) & 3u);
    snapshot.reservedEventCount =
        static_cast<std::uint8_t>((meta >> 4) & 0x1fu);
    snapshot.address = payload[12];
    snapshot.writeData = payload[13];
    snapshot.executionPC = payload[14];
    snapshot.arm9Timestamp = join(payload[15], payload[16]);
    snapshot.arm7Timestamp = join(payload[17], payload[18]);
    snapshot.requiredRunSafeThrough = join(payload[19], payload[20]);

    if ((meta & 0xfffffe00u) != 0 || snapshot.epoch == 0 ||
        snapshot.groupSequence == 0 || snapshot.access > 2 ||
        snapshot.processedThrough > snapshot.runSafeThrough ||
        snapshot.arm9Timestamp > snapshot.runSafeThrough ||
        snapshot.arm7Timestamp > snapshot.runSafeThrough) {
        setError(error, "FPGA ETW1 snapshot failed structural validation");
        return ExternalTimeWindowLwReadResult::Fault;
    }

    switch (state) {
    case 1:
        snapshot.kind = ExternalTimeWindowLwWorkKind::Refill;
        break;
    case 2:
        snapshot.kind = ExternalTimeWindowLwWorkKind::Freeze;
        break;
    case 3:
        snapshot.kind = ExternalTimeWindowLwWorkKind::Descriptor;
        break;
    case 4:
        snapshot.kind = ExternalTimeWindowLwWorkKind::WaitRelease;
        break;
    default:
        setError(error, "FPGA ETW1 state decode failed");
        return ExternalTimeWindowLwReadResult::Fault;
    }

    if (snapshot.kind == ExternalTimeWindowLwWorkKind::Descriptor) {
        if (snapshot.barrierSequence == 0 || snapshot.sourceSequence == 0 ||
            snapshot.reservedEventCount == 0 ||
            snapshot.reservedEventCount > 16 ||
            snapshot.executionPC == 0xffffffffu ||
            (snapshot.readNotWrite && snapshot.writeData != 0) ||
            snapshot.requiredRunSafeThrough < snapshot.arm9Timestamp ||
            snapshot.requiredRunSafeThrough < snapshot.arm7Timestamp) {
            setError(error, "FPGA ETW1 blocking descriptor is invalid");
            return ExternalTimeWindowLwReadResult::Fault;
        }
    }
    return ExternalTimeWindowLwReadResult::Work;
}

bool ExternalTimeWindowLwControl::acknowledgeFreeze(
    const ExternalTimeWindowLwSnapshot& snapshot,
    std::string& error) const noexcept
{
    error.clear();
    if (!available(error)) return false;
    if (snapshot.kind != ExternalTimeWindowLwWorkKind::Freeze ||
        snapshot.generation == 0) {
        setError(error, "ETW1 freeze acknowledgement has no frozen snapshot");
        return false;
    }
    words_[kControlGeneration] = snapshot.generation;
    deviceFence();
    words_[kControlCommit] = 1u;
    deviceFence();
    return true;
}

bool ExternalTimeWindowLwControl::publishCompletion(
    const ExternalTimeWindowLwSnapshot& snapshot,
    const ExternalTimeWindowLwCompletion& completion,
    std::string& error) const noexcept
{
    error.clear();
    if (!available(error)) return false;
    if (snapshot.kind != ExternalTimeWindowLwWorkKind::Descriptor ||
        snapshot.generation == 0 || snapshot.epoch == 0 ||
        snapshot.groupSequence == 0 || snapshot.barrierSequence == 0 ||
        snapshot.sourceSequence == 0) {
        setError(error, "ETW1 completion has no valid descriptor identity");
        return false;
    }
    const std::uint32_t meta = (snapshot.arm9 ? 1u : 0u) |
        (completion.haltArm9 ? 1u << 2 : 0u) |
        (completion.haltArm7 ? 1u << 3 : 0u);
    words_[kCompletionFirst + 0] = completion.readData;
    words_[kCompletionFirst + 1] = snapshot.epoch;
    words_[kCompletionFirst + 2] = snapshot.groupSequence;
    words_[kCompletionFirst + 3] = snapshot.barrierSequence;
    words_[kCompletionFirst + 4] = snapshot.sourceSequence;
    words_[kCompletionFirst + 5] =
        static_cast<std::uint32_t>(snapshot.verifiedProducerFence);
    words_[kCompletionFirst + 6] =
        static_cast<std::uint32_t>(snapshot.verifiedProducerFence >> 32);
    words_[kCompletionFirst + 7] = meta;
    words_[kCompletionFirst + 8] = snapshot.generation;
    deviceFence();
    words_[kCompletionCommit] = kCompletionMagic;
    deviceFence();
    return true;
}

} // namespace nds4mister
