#pragma once

#include "replay/Hybrid3DAbi.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace nds4mister::h3d::gx_readback {

// H3R1, reserved control-page area at physical 0x3fc00200. All words are
// naturally aligned little-endian uint32_t, as in the surrounding H3D ABI.
constexpr std::size_t MappingOffset = 0x200;
constexpr std::size_t ReplyBytes = 128;
constexpr std::uint32_t Magic = 0x31523348u;
constexpr std::size_t StatusWord = 4;
constexpr std::size_t ClipWord = 5;
constexpr std::size_t VectorWord = 21;
constexpr std::size_t CommitWord = 30;
using Snapshot = std::array<std::uint32_t, ReplyBytes / 4>;
static_assert(sizeof(Snapshot) == ReplyBytes);
static_assert(ClipWord * 4 == 0x14 && VectorWord * 4 == 0x54);
static_assert(CommitWord * 4 == 0x78);

template<class ReadWord>
Snapshot capture(std::uint32_t session, std::uint32_t request_id,
                 ReadWord read_word)
{
    Snapshot result {};
    result[0] = Magic;
    result[1] = session;
    result[2] = request_id;
    result[StatusWord] = read_word(0x04000600u);
    for (std::size_t i = 0; i < 16; ++i)
        result[ClipWord + i] = read_word(0x04000640u + 4u * i);
    for (std::size_t i = 0; i < 9; ++i)
        result[VectorWord + i] = read_word(0x04000680u + 4u * i);
    result[CommitWord] = request_id;
    return result;
}

// WriteWord stores one volatile device word. Keeping the small publication
// protocol independent of the backing mapping makes clear/payload/commit
// order and session-loss behavior directly testable without a live FPGA.
template<class SessionCurrent, class WriteWord>
bool publish(const Snapshot& snapshot, SessionCurrent session_current,
             WriteWord write_word)
{
    if (snapshot[0] != Magic || snapshot[1] == 0 || snapshot[2] == 0 ||
        snapshot[3] != 0 || snapshot[31] != 0 ||
        snapshot[CommitWord] != snapshot[2] || !session_current())
        return false;
    write_word(CommitWord, 0);
    device_barrier();
    for (std::size_t i = 0; i < snapshot.size(); ++i)
        if (i != CommitWord) write_word(i, snapshot[i]);
    // Complete the payload before rechecking ownership and publishing commit.
    device_barrier();
    if (!session_current()) return false;
    write_word(CommitWord, snapshot[2]);
    device_barrier();
    return true;
}

} // namespace nds4mister::h3d::gx_readback
