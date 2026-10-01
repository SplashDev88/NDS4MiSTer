// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdlib>
#ifdef __linux__
#include <sys/prctl.h>
#endif

namespace nds4mister::replay {

class TimerSlackBackend {
public:
    long get() const noexcept
    {
#ifdef __linux__
        return prctl(PR_GET_TIMERSLACK, 0UL, 0UL, 0UL, 0UL);
#else
        return -1;
#endif
    }
    bool set(unsigned long value) const noexcept
    {
#ifdef __linux__
        return prctl(PR_SET_TIMERSLACK, value, 0UL, 0UL, 0UL) == 0;
#else
        (void)value;
        return false;
#endif
    }
};

// Intake-thread-only, private opt-in. Activate after service worker creation;
// restore before teardown/recreation so later workers inherit normal slack.
// This changes timer coalescing, never sleep duration or scheduler priority.
template<class Backend = TimerSlackBackend>
class ScopedTimerSlack {
public:
    explicit ScopedTimerSlack(Backend& backend) : backend_(backend) {}
    ScopedTimerSlack(const ScopedTimerSlack&) = delete;
    ScopedTimerSlack& operator=(const ScopedTimerSlack&) = delete;
    ~ScopedTimerSlack() { restore(); }

    void activate() noexcept
    {
        if (attempted_) return;
        attempted_ = true;
        const auto previous = backend_.get();
        // An unavailable API or an already tighter setting requires no change.
        if (previous <= 1) return;
        saved_ = static_cast<unsigned long>(previous);
        active_ = backend_.set(1UL);
    }
    void restore() noexcept
    {
        if (active_ && !backend_.set(saved_)) std::abort();
        active_ = false;
        attempted_ = false;
    }
    bool active() const noexcept { return active_; }

private:
    Backend& backend_;
    unsigned long saved_ = 0;
    bool attempted_ = false;
    bool active_ = false;
};

} // namespace nds4mister::replay
