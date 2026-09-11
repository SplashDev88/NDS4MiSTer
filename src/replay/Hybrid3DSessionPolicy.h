#pragma once

#include "replay/Hybrid3DAbi.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace nds4mister::h3d::session_policy {

// H3P1 exists only in packet mode (the legacy event ring overlaps this area).
// FPGA owns request, HPS owns acknowledgement. Policy is immutable until the
// next quiesced session; neither a menu edit nor an HPS restart is a warm toggle.
constexpr std::size_t RequestOffset = 0x300;
constexpr std::size_t AckOffset = 0x340;
constexpr std::uint32_t Magic = 0x31503348u;
constexpr std::uint32_t VersionSize = 0x00200001u;
constexpr std::uint32_t EngineBPixels = 1u;
constexpr std::size_t CommitWord = 6;
using Block = std::array<std::uint32_t, 8>;
static_assert(sizeof(Block) == 32);

constexpr Block make(std::uint32_t session, std::uint32_t epoch, bool enabled)
{
    return {Magic, VersionSize, session, enabled ? EngineBPixels : 0u,
            epoch, 0, epoch, 0};
}

constexpr bool valid(const Block& b, std::uint32_t session, std::uint32_t epoch)
{
    return session != 0 && epoch != 0 && b[0] == Magic &&
        b[1] == VersionSize && b[2] == session &&
        (b[3] & ~EngineBPixels) == 0 && b[4] == epoch &&
        b[5] == 0 && b[CommitWord] == epoch && b[7] == 0;
}

template<class ReadWord>
bool read(Block& block, std::uint32_t session, std::uint32_t epoch,
          ReadWord read_word)
{
    const auto commit = read_word(CommitWord);
    if (commit == 0 || commit != epoch) return false;
    device_barrier();
    for (std::size_t i = 0; i < block.size(); ++i) block[i] = read_word(i);
    device_barrier();
    return read_word(CommitWord) == commit && valid(block, session, epoch);
}

template<class SessionCurrent, class WriteWord>
bool acknowledge(const Block& block, SessionCurrent current, WriteWord write)
{
    if (!valid(block, block[2], block[4]) || !current()) return false;
    write(CommitWord, 0);
    device_barrier();
    for (std::size_t i = 0; i < block.size(); ++i)
        if (i != CommitWord) write(i, block[i]);
    device_barrier();
    if (!current()) return false;
    write(CommitWord, block[CommitWord]);
    device_barrier();
    return true;
}

} // namespace nds4mister::h3d::session_policy
