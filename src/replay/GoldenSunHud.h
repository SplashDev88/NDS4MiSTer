// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace nds4mister::replay {

struct GoldenSunHud {
    using Word = std::uint32_t;
    static constexpr Word Base = 0x06840000;
    static constexpr std::size_t Words = 256 * 192 / sizeof(Word);
    static constexpr Word Marker = Base + Words * sizeof(Word);
    static constexpr Word Full = 0x31445548;
    static constexpr unsigned Pages = 6;
    static constexpr std::size_t PageWords = Words / Pages;

    std::array<std::array<Word, Words>, 2> images {};
    unsigned active = 0;
    bool ready = false;
    Word last_frame = 0;

    static bool is_marker(Word value) { return value >= Full && value <= Full + Pages; }

    void write(Word address, Word value, Word frame)
    {
        if (address == Marker) {
            if (!is_marker(value)) return;
            // Every DMA begins at Base. A page marker supplies its destination
            // within the back image. Only an ordered complete image may publish.
            const bool whole = value == Full;
            const unsigned page = whole ? 0 : value - Full - 1;
            if (page && (remaining || next_page != page)) {
                remaining = 0;
                next_page = 0;
                return;
            }
            offset = page * PageWords;
            received = 0;
            remaining = whole ? Words : PageWords;
            next_page = whole ? Pages : page + 1;
            return;
        }
        if (!remaining) return;
        if (address != Base + received * sizeof(Word)) {
            remaining = 0;
            next_page = 0;
            return;
        }
        images[1 - active][offset + received++] = value;
        if (--remaining == 0 && next_page == Pages) {
            active = 1 - active;
            ready = true;
            last_frame = frame;
            next_page = 0;
        }
    }

private:
    std::size_t offset = 0;
    std::size_t received = 0;
    std::size_t remaining = 0;
    unsigned next_page = 0;
};

} // namespace nds4mister::replay
