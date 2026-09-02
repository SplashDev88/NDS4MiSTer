#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace nds4mister {

constexpr std::uint32_t kArm7SoundMmioFirst = 0x04000400u;
constexpr std::uint32_t kArm7SoundMmioLast = 0x0400051fu;
constexpr std::uint64_t kArm7SoundMmioTraceMaxWrites = 1000000u;

constexpr unsigned arm7SoundMmioWidth(unsigned access) {
    return access <= 2u ? 1u << access : 0u;
}

constexpr bool arm7SoundMmioAligned(
    std::uint32_t address, unsigned access) {
    return access == 0u ||
        (access == 1u && (address & 1u) == 0u) ||
        (access == 2u && (address & 3u) == 0u);
}

constexpr std::uint8_t arm7SoundMmioByteEnable(
    std::uint32_t address, unsigned access) {
    if (!arm7SoundMmioAligned(address, access)) return 0u;
    if (access == 0u) return static_cast<std::uint8_t>(
        1u << (address & 3u));
    if (access == 1u) return static_cast<std::uint8_t>(
        3u << (address & 2u));
    return access == 2u ? 0x0fu : 0u;
}

constexpr std::uint32_t arm7SoundMmioAlignedData(
    std::uint32_t address, unsigned access, std::uint32_t writeData) {
    if (!arm7SoundMmioAligned(address, access)) return 0u;
    if (access == 0u)
        return (writeData & 0xffu) << (8u * (address & 3u));
    if (access == 1u)
        return (writeData & 0xffffu) << (8u * (address & 2u));
    return access == 2u ? writeData : 0u;
}

static_assert(arm7SoundMmioWidth(0) == 1);
static_assert(arm7SoundMmioWidth(1) == 2);
static_assert(arm7SoundMmioWidth(2) == 4);
static_assert(arm7SoundMmioWidth(3) == 0);
static_assert(arm7SoundMmioByteEnable(0x04000501u, 0) == 0x02u);
static_assert(arm7SoundMmioByteEnable(0x0400050au, 1) == 0x0cu);
static_assert(arm7SoundMmioByteEnable(0x04000480u, 2) == 0x0fu);
static_assert(arm7SoundMmioByteEnable(0x04000509u, 1) == 0u);
static_assert(
    arm7SoundMmioAlignedData(0x04000501u, 0, 0x12345680u) ==
    0x00008000u);
static_assert(
    arm7SoundMmioAlignedData(0x0400050au, 1, 0x1234f7b8u) ==
    0xf7b80000u);

struct Arm7SoundMmioWriteTraceRecord {
    std::uint64_t ordinal = 0;
    std::uint32_t generation = 0;
    std::uint32_t address = 0;
    unsigned access = 0;
    unsigned width = 0;
    bool aligned = false;
    std::uint8_t byteEnable = 0;
    std::uint32_t writeData = 0;
    std::uint32_t alignedData = 0;
    std::uint32_t elapsedCycles = 0;
    std::uint64_t arm7Cycles = 0;
    std::uint64_t sharedTimestamp = 0;
};

enum class Arm7SoundMmioTraceResult {
    None,
    Captured,
    CapturedAndExhausted,
};

class Arm7SoundMmioTraceState {
public:
    explicit constexpr Arm7SoundMmioTraceState(
        std::uint64_t requestedWrites = 0)
        : remaining_(requestedWrites) {}

    constexpr bool enabled() const { return remaining_ != 0; }
    constexpr std::uint64_t remaining() const { return remaining_; }
    constexpr std::uint64_t captured() const { return captured_; }
    constexpr std::uint64_t arm7Cycles() const { return arm7Cycles_; }

    Arm7SoundMmioTraceResult observeSuccessfulRequest(
        std::uint32_t generation,
        bool arm9,
        bool readNotWrite,
        std::uint32_t address,
        unsigned access,
        std::uint32_t writeData,
        std::uint32_t elapsedCycles,
        std::uint64_t sharedTimestamp,
        Arm7SoundMmioWriteTraceRecord& record) {
        if (!enabled()) return Arm7SoundMmioTraceResult::None;
        if (!arm9) arm7Cycles_ += elapsedCycles;
        if (arm9 || readNotWrite ||
            address < kArm7SoundMmioFirst ||
            address > kArm7SoundMmioLast)
            return Arm7SoundMmioTraceResult::None;

        record.ordinal = ++captured_;
        record.generation = generation;
        record.address = address;
        record.access = access;
        record.width = arm7SoundMmioWidth(access);
        record.aligned = arm7SoundMmioAligned(address, access);
        record.byteEnable = arm7SoundMmioByteEnable(address, access);
        record.writeData = writeData;
        record.alignedData =
            arm7SoundMmioAlignedData(address, access, writeData);
        record.elapsedCycles = elapsedCycles;
        record.arm7Cycles = arm7Cycles_;
        record.sharedTimestamp = sharedTimestamp;
        --remaining_;
        return enabled() ? Arm7SoundMmioTraceResult::Captured
                         : Arm7SoundMmioTraceResult::CapturedAndExhausted;
    }

private:
    std::uint64_t remaining_ = 0;
    std::uint64_t captured_ = 0;
    std::uint64_t arm7Cycles_ = 0;
};

inline std::size_t formatArm7SoundMmioWriteTrace(
    char* output,
    std::size_t capacity,
    const Arm7SoundMmioWriteTraceRecord& record) {
    const int length = std::snprintf(
        output, capacity,
        "NDS4MISTER_ARM7_SOUND_WRITE_V1"
        " ordinal=%llu generation=0x%08x address=0x%08x"
        " access=%u width=%u aligned=%u byte_enable=0x%x"
        " write_data=0x%08x aligned_data=0x%08x"
        " elapsed_cycles=0x%08x arm7_cycles=0x%016llx"
        " shared_timestamp=0x%016llx\n",
        static_cast<unsigned long long>(record.ordinal),
        record.generation,
        record.address,
        record.access,
        record.width,
        record.aligned ? 1u : 0u,
        static_cast<unsigned>(record.byteEnable),
        record.writeData,
        record.alignedData,
        record.elapsedCycles,
        static_cast<unsigned long long>(record.arm7Cycles),
        static_cast<unsigned long long>(record.sharedTimestamp));
    return length > 0 && static_cast<std::size_t>(length) < capacity
        ? static_cast<std::size_t>(length) : 0u;
}

inline std::size_t formatArm7SoundMmioTraceEnd(
    char* output,
    std::size_t capacity,
    const Arm7SoundMmioWriteTraceRecord& record) {
    const int length = std::snprintf(
        output, capacity,
        "NDS4MISTER_ARM7_SOUND_WRITE_TRACE_END_V1"
        " events=%llu last_generation=0x%08x"
        " arm7_cycles=0x%016llx shared_timestamp=0x%016llx\n",
        static_cast<unsigned long long>(record.ordinal),
        record.generation,
        static_cast<unsigned long long>(record.arm7Cycles),
        static_cast<unsigned long long>(record.sharedTimestamp));
    return length > 0 && static_cast<std::size_t>(length) < capacity
        ? static_cast<std::size_t>(length) : 0u;
}

} // namespace nds4mister
