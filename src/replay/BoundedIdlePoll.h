// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <chrono>

namespace nds4mister::replay {
// Retry a briefly empty input queue without a sleep/wakeup between each poll.
// Both elapsed time and retry count bound extra idle work. This never delays
// real input or bypasses the caller's session/stop checks.
class BoundedIdlePoll {
public:
    using Clock = std::chrono::steady_clock;
    bool retry(Clock::time_point now)
    {
        if (retries_ == 0) started_ = now;
        if (retries_ >= 4 || now - started_ >= std::chrono::microseconds(50))
            return false;
        ++retries_;
        return true;
    }
    bool active() const { return retries_ != 0; }
    void reset() { retries_ = 0; }
private:
    Clock::time_point started_ {};
    unsigned retries_ = 0;
};
} // namespace nds4mister::replay
