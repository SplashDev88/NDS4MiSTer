// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <stdexcept>
#ifdef __linux__
#include <pthread.h>
#include <sched.h>
#endif

namespace nds4mister::replay {

// Private standalone experiment: only the already-acquired query packet's
// validation/matrix-prefix/reply phase gets priority. Never wrap queue waits,
// idle polling, renderer joins, disk I/O or complete replay in this scope.
class QueryPriorityBackend {
public:
    bool elevate()
    {
#ifdef __linux__
        if (pthread_getschedparam(pthread_self(), &previous_policy_, &previous_) != 0 ||
            previous_policy_ != SCHED_OTHER)
            throw std::runtime_error("query priority requires ordinary intake scheduling");
        static const int first = sched_get_priority_min(SCHED_FIFO);
        static const int last = sched_get_priority_max(SCHED_FIFO);
        if (first < 0 || first >= last)
            throw std::runtime_error("query priority range unavailable");
        sched_param requested {};
        requested.sched_priority = first + 1; // Above bounded publication only.
        if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &requested) != 0)
            throw std::runtime_error("could not apply scoped query priority");
        return true;
#else
        return false;
#endif
    }
    void restore() noexcept
    {
#ifdef __linux__
        // Returning to ordinary priority is permitted without extra privilege.
        // Never continue into idle polling with an unexpected realtime policy.
        if (pthread_setschedparam(pthread_self(), previous_policy_, &previous_) != 0)
            std::abort();
#endif
    }
    static std::uint64_t now_us() noexcept
    {
        return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }
private:
#ifdef __linux__
    int previous_policy_ = SCHED_OTHER;
    sched_param previous_ {};
#endif
};

template<class Backend = QueryPriorityBackend>
class ScopedQueryPriority {
public:
    ScopedQueryPriority(Backend& backend, bool enabled) : backend_(backend)
    {
        if (enabled && backend_.elevate()) {
            active_ = true;
            deadline_ = backend_.now_us() + BudgetUs;
        }
    }
    ScopedQueryPriority(const ScopedQueryPriority&) = delete;
    ScopedQueryPriority& operator=(const ScopedQueryPriority&) = delete;
    ~ScopedQueryPriority() { release(); }

    void checkpoint() noexcept
    {
        if (active_ && backend_.now_us() >= deadline_) release();
    }
    void release() noexcept
    {
        if (active_) {
            active_ = false;
            backend_.restore();
        }
    }
    bool active() const noexcept { return active_; }
    static constexpr std::uint64_t BudgetUs = 2000;
private:
    Backend& backend_;
    bool active_ = false;
    std::uint64_t deadline_ = 0;
};
}
