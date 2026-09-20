// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>

namespace nds4mister::replay {

// Diagnostic selection only: a mostly dark game image can retain a HUD.
// Neither this threshold nor a captured event establishes a rendering bug.
inline unsigned count_rgb_nonblack(const std::uint32_t* pixels,
                                   std::size_t count)
{
    unsigned result = 0;
    for (std::size_t i = 0; i < count; ++i)
        result += (pixels[i] & 0x00ffffffu) != 0;
    return result;
}

class NearBlackEventGate {
public:
    enum class Event { None, Dark, Recovery };
    static constexpr unsigned Limit = 8;

    void arm(std::uint32_t session, bool enabled)
    {
        enabled = enabled && session != 0;
        if (session_ != session || armed_ != enabled) {
            events_ = 0;
            dark_ = false;
        }
        session_ = session;
        armed_ = enabled;
    }

    Event observe(unsigned top_nonblack, unsigned bottom_nonblack)
    {
        if (!armed_) return Event::None;
        const bool suspect = top_nonblack >= 128 && bottom_nonblack <= 32;
        if (suspect && !dark_ && events_ < Limit) {
            ++events_;
            dark_ = true;
            return Event::Dark;
        }
        if (!suspect && dark_) {
            dark_ = false;
            return Event::Recovery;
        }
        return Event::None;
    }

    unsigned event_number() const { return events_; }

private:
    std::uint32_t session_ = 0;
    unsigned events_ = 0;
    bool armed_ = false;
    bool dark_ = false;
};

} // namespace nds4mister::replay
