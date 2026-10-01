// SPDX-License-Identifier: GPL-3.0-or-later
#include "ScopedTimerSlack.h"
#include <atomic>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <thread>

using nds4mister::replay::ScopedTimerSlack;
using nds4mister::replay::TimerSlackBackend;
static void require(bool ok)
{
    if (!ok) throw std::runtime_error("timer slack invariant failed");
}
struct Fake {
    long value = 50000;
    bool readable = true, writable = true;
    unsigned reads = 0, writes = 0;
    long get() { ++reads; return readable ? value : -1; }
    bool set(unsigned long v) { ++writes; if (!writable) return false; value = v; return true; }
};

int main(int argc, char** argv) try
{
    {
        Fake f;
        { ScopedTimerSlack<Fake> guard(f); guard.restore(); }
        require(f.reads == 0 && f.writes == 0);
    }
    {
        Fake f;
        {
            ScopedTimerSlack<Fake> guard(f);
            guard.activate(); guard.activate();
            require(guard.active() && f.value == 1 && f.reads == 1 && f.writes == 1);
            guard.restore(); guard.restore();
            require(!guard.active() && f.value == 50000 && f.writes == 2);
            f.value = 90000; guard.activate();
        }
        require(f.value == 90000 && f.reads == 2 && f.writes == 4);
    }
    {
        Fake f;
        try { ScopedTimerSlack<Fake> guard(f); guard.activate(); throw 7; }
        catch (int value) { require(value == 7); }
        require(f.value == 50000 && f.writes == 2);
    }
    for (int mode = 0; mode != 3; ++mode) {
        Fake f;
        if (mode == 0) f.readable = false;
        if (mode == 1) f.writable = false;
        if (mode == 2) f.value = 1;
        { ScopedTimerSlack<Fake> guard(f); guard.activate(); guard.activate(); require(!guard.active()); }
        require(f.reads == 1 && f.writes == (mode == 1 ? 1u : 0u));
    }
    std::cout << "SCOPED_TIMER_SLACK_PASS disabled=1 one_attempt=1 restore=1 exception=1 new_session=1 unavailable=1 already_tight=1\n";
    if (argc == 2 && std::string_view(argv[1]) == "--native") {
#ifdef __linux__
        TimerSlackBackend backend;
        const long original = backend.get(); require(original > 1);
        std::atomic<unsigned> phase{0};
        std::atomic<long> worker_before{-1}, worker_after{-1};
        std::thread worker([&] {
            worker_before.store(backend.get()); phase.store(1);
            while (phase.load() != 2) std::this_thread::yield();
            worker_after.store(backend.get());
        });
        while (phase.load() != 1) std::this_thread::yield();
        {
            ScopedTimerSlack guard(backend); guard.activate();
            const bool changed = guard.active() && backend.get() == 1;
            phase.store(2); worker.join();
            require(changed);
            require(worker_before.load() == original && worker_after.load() == original);
        }
        require(backend.get() == original);
        long next_worker = -1;
        std::thread next([&] { next_worker = backend.get(); }); next.join();
        require(next_worker == original);
        try { ScopedTimerSlack guard(backend); guard.activate(); throw 9; }
        catch (int value) { require(value == 9); }
        require(backend.get() == original);
        std::cout << "SCOPED_TIMER_SLACK_NATIVE_PASS intake_only=1 existing_worker_unchanged=1 next_worker_normal=1 exception_restore=1 original_ns=" << original << '\n';
#else
        throw std::runtime_error("native timer test requires Linux");
#endif
    } else require(argc == 1);
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
