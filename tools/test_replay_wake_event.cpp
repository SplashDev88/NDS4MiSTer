#include "replay/ReplaySpscState.h"
#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
#ifdef __linux__
#include <cerrno>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

using nds4mister::replay::ReplaySpscState;
using nds4mister::replay::ReplayWakeEvent;

static void require(bool condition, const char* message)
{
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

static void test_schedules()
{
    ReplaySpscState queue;
    queue.publish(1);
    // Exact failing order in the old publish(): capture claimed, consumer
    // drains and sleeps, then store publication and test stale depth == 1.
    const auto oldClaimed = queue.consumer_snapshot().claimed;
    queue.claim(1);
    const auto asleepAt = queue.consumer_snapshot().published;
    queue.published_word().store(2, std::memory_order_release);
    require(2 - oldClaimed == 2 && queue.count() == 1 && asleepAt == 1,
        "old missed-wake interleaving did not reproduce");
    std::cout << "OLD_MISSED_WAKE_REPRODUCED stale_count=2 actual_count=1 sleeper_expected=1 published=2\n";

    ReplayWakeEvent event;
    const auto waiting = event.prepare_wait();
    require(event.notify(), "registered waiter was missed");
    require(event.word().load(std::memory_order_acquire) != waiting,
        "publication-before-futex did not change expected generation");
    event.cancel_wait();
    require(!event.notify(), "backlogged publication requested kernel wake");
    const auto later = event.prepare_wait();
    require(later != waiting, "registration did not acquire earlier notification");
    event.cancel_wait();
    event.word().store(0xfffffffeu, std::memory_order_relaxed);
    const auto wrap = event.prepare_wait();
    require(event.notify() && event.word().load() == 1 && wrap == 0xffffffffu,
        "generation wrap lost waiter bit or failed to change value");
    event.cancel_wait();
    std::atomic<bool> stopped {false};
    const auto stopWait = event.prepare_wait();
    stopped.store(true, std::memory_order_release);
    require(event.notify() && event.word().load() != stopWait && stopped.load(),
        "stop-before-futex did not invalidate the expected generation");
    event.cancel_wait();
}

#ifdef __linux__
static int wait(ReplayWakeEvent& event, std::uint32_t expected)
{
    const timespec limit {2, 0};
    return static_cast<int>(syscall(SYS_futex,
        reinterpret_cast<std::uint32_t*>(&event.word()),
        FUTEX_WAIT_PRIVATE, expected, &limit, nullptr, 0));
}
static void notify(ReplayWakeEvent& event)
{
    if (event.notify())
        (void)syscall(SYS_futex,
            reinterpret_cast<std::uint32_t*>(&event.word()),
            FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
}

static void test_kernel_wait_and_packets()
{
    ReplayWakeEvent event;
    const auto stale = event.prepare_wait();
    notify(event);
    require(wait(event, stale) == -1 && errno == EAGAIN,
        "kernel accepted an obsolete event generation");
    event.cancel_wait();

    constexpr std::uint32_t Packets = 200000;
    constexpr std::uint32_t Capacity = 512;
    std::array<std::uint32_t, Capacity + 1> slots {};
    ReplaySpscState queue;
    std::atomic<bool> started {false};
    std::atomic<unsigned> waits {0};
    const auto beginning = std::chrono::steady_clock::now();
    std::thread consumer([&] {
        started.store(true, std::memory_order_release);
        for (std::uint32_t sequence = 1; sequence <= Packets; ++sequence) {
            while (queue.consumer_snapshot().published < sequence) {
                const auto expected = event.prepare_wait();
                if (queue.consumer_snapshot().published < sequence) {
                    ++waits;
                    const int result = wait(event, expected);
                    require(result == 0 || errno == EAGAIN || errno == EINTR,
                        "consumer timed out with a missed wake");
                }
                event.cancel_wait();
            }
            queue.claim(sequence);
            require(slots[(sequence - 1) % slots.size()] == sequence,
                "packet ownership/order was violated");
        }
    });
    while (!started.load(std::memory_order_acquire)) std::this_thread::yield();
    for (std::uint32_t sequence = 1; sequence <= Packets; ++sequence) {
        while (queue.count() == Capacity) std::this_thread::yield();
        slots[(sequence - 1) % slots.size()] = sequence;
        queue.publish(sequence);
        notify(event);
        // Encourage empty transitions as well as sustained backlogs.
        if ((sequence & 31u) == 0) std::this_thread::yield();
    }
    consumer.join();
    require(queue.count() == 0, "packet queue did not drain");
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - beginning).count();
    std::cout << "REPLAY_WAKE_KERNEL_PASS packets=" << Packets
              << " waits=" << waits.load() << " elapsed_ns=" << ns << '\n';
}
#endif

template<bool WithEvent>
[[gnu::noinline]] static void benchmark_backlogged_publication(unsigned sample)
{
    constexpr std::uint32_t Iterations = 2000000;
    ReplaySpscState queue;
    ReplayWakeEvent event;
    for (unsigned i = 0; i < 32; ++i) queue.publish(i);
    const auto start = std::chrono::steady_clock::now();
    for (std::uint32_t i = 1; i <= Iterations; ++i) {
        queue.publish(i);
        if constexpr (WithEvent) (void)event.notify();
        queue.claim(i);
    }
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - start).count();
    require(queue.count() == 32, "notification benchmark changed queue accounting");
    std::cout << "REPLAY_WAKE_OVERHEAD sample=" << sample
              << " event=" << WithEvent << " packets=" << Iterations
              << " elapsed_ns=" << ns << '\n';
}

int main(int argc, char** argv)
{
    if (argc == 2 && std::strcmp(argv[1], "--bench-backlogged") == 0) {
        // Isolate notification's added atomic cost. No emulation, ROM or
        // shared FPGA memory. This is NOT total service/gameplay throughput.
        for (unsigned block = 0; block < 2; ++block) {
            benchmark_backlogged_publication<false>(block * 4);
            benchmark_backlogged_publication<true>(block * 4 + 1);
            benchmark_backlogged_publication<true>(block * 4 + 2);
            benchmark_backlogged_publication<false>(block * 4 + 3);
        }
        return 0;
    }
    test_schedules();
#ifdef __linux__
    test_kernel_wait_and_packets();
#endif
    std::cout << "REPLAY_WAKE_EVENT_PASS\n";
}
