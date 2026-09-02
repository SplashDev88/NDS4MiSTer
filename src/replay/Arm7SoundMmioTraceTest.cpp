#include "replay/Arm7SoundMmioTrace.h"

#include <array>
#include <cstring>
#include <iostream>

namespace {

bool runTest() {
    nds4mister::Arm7SoundMmioTraceState trace(3);
    nds4mister::Arm7SoundMmioWriteTraceRecord record;

    if (trace.observeSuccessfulRequest(
            1, true, false, 0x04000480u, 2, 0x63400274u,
            5, 1, record) !=
        nds4mister::Arm7SoundMmioTraceResult::None)
        return false;
    if (trace.observeSuccessfulRequest(
            2, false, true, 0x04000500u, 0, 0,
            7, 2, record) !=
        nds4mister::Arm7SoundMmioTraceResult::None)
        return false;
    if (trace.observeSuccessfulRequest(
            3, false, false, 0x040003ffu, 0, 0x55u,
            11, 3, record) !=
        nds4mister::Arm7SoundMmioTraceResult::None)
        return false;
    if (trace.arm7Cycles() != 18 || trace.remaining() != 3)
        return false;

    if (trace.observeSuccessfulRequest(
            4, false, false, 0x04000501u, 0, 0x12345680u,
            13, 100, record) !=
        nds4mister::Arm7SoundMmioTraceResult::Captured)
        return false;
    if (record.ordinal != 1 || record.width != 1 || !record.aligned ||
        record.byteEnable != 0x2 || record.writeData != 0x12345680u ||
        record.alignedData != 0x00008000u ||
        record.arm7Cycles != 31 || record.sharedTimestamp != 100)
        return false;

    std::array<char, 512> line{};
    const auto lineLength = nds4mister::formatArm7SoundMmioWriteTrace(
        line.data(), line.size(), record);
    const char* expectedLine =
        "NDS4MISTER_ARM7_SOUND_WRITE_V1"
        " ordinal=1 generation=0x00000004 address=0x04000501"
        " access=0 width=1 aligned=1 byte_enable=0x2"
        " write_data=0x12345680 aligned_data=0x00008000"
        " elapsed_cycles=0x0000000d arm7_cycles=0x000000000000001f"
        " shared_timestamp=0x0000000000000064\n";
    if (lineLength != std::strlen(expectedLine) ||
        std::strcmp(line.data(), expectedLine) != 0)
        return false;

    if (trace.observeSuccessfulRequest(
            5, false, false, 0x0400050au, 1, 0x1234f7b8u,
            17, 200, record) !=
        nds4mister::Arm7SoundMmioTraceResult::Captured)
        return false;
    if (record.ordinal != 2 || record.width != 2 || !record.aligned ||
        record.byteEnable != 0xc ||
        record.alignedData != 0xf7b80000u)
        return false;

    if (trace.observeSuccessfulRequest(
            6, false, false, 0x04000509u, 1, 0x00008080u,
            19, 300, record) !=
        nds4mister::Arm7SoundMmioTraceResult::CapturedAndExhausted)
        return false;
    if (trace.enabled() || trace.remaining() != 0 || trace.captured() != 3 ||
        record.ordinal != 3 || record.width != 2 || record.aligned ||
        record.byteEnable != 0 || record.alignedData != 0 ||
        record.arm7Cycles != 67)
        return false;

    line.fill(0);
    const auto endLength = nds4mister::formatArm7SoundMmioTraceEnd(
        line.data(), line.size(), record);
    const char* expectedEnd =
        "NDS4MISTER_ARM7_SOUND_WRITE_TRACE_END_V1"
        " events=3 last_generation=0x00000006"
        " arm7_cycles=0x0000000000000043"
        " shared_timestamp=0x000000000000012c\n";
    if (endLength != std::strlen(expectedEnd) ||
        std::strcmp(line.data(), expectedEnd) != 0)
        return false;

    if (trace.observeSuccessfulRequest(
            7, false, false, 0x04000400u, 2, 0x8820007fu,
            23, 400, record) !=
        nds4mister::Arm7SoundMmioTraceResult::None)
        return false;
    return trace.arm7Cycles() == 67;
}

} // namespace

int main() {
    if (!runTest()) {
        std::cerr << "FAIL: bounded ARM7 sound-MMIO write trace\n";
        return 1;
    }
    std::cout
        << "PASS: bounded ARM7 sound-MMIO trace preserves actual data, "
           "width, byte enables, alignment, and cycle timestamps\n";
    return 0;
}
